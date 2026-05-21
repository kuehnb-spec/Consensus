import Foundation
import Darwin

/// Runs the new Deep Review architecture:
/// VibeVoice remains the canonical transcript, WhisperKit supplies a second
/// opinion, and a Python sidecar applies only exact, tool-verified patches.
///
/// This replaces the older full-transcript LLM reconciliation path. The model
/// is no longer allowed to author a new transcript; it can only verify or
/// reject small candidate edits against local audio.
final class PatchReviewRunner {
    private let whisper = TranscriptionService()

    struct Options: Sendable {
        var whisperModel: WhisperModel = .largeV3
        var language: String = "en"
        var audioDurationSeconds: Double = 0
        var context: String?
        var protectedTerms: [String] = []
    }

    struct Progress: Sendable {
        let fraction: Double
        let label: String
    }

    private enum Weights {
        static let whisperLoad: Double = 0.15
        static let whisperRun: Double = 0.30
        static let patchReview: Double = 0.55
    }

    func run(
        audioURL: URL,
        standardPass: TranscriptPass,
        speakers: [Speaker],
        options: Options,
        progress: @escaping @Sendable (Progress) -> Void
    ) async throws -> TranscriptPass {
        let runStart = Date()
        var stageTimings = standardPass.quality.stageTimings

        let whisperLoadStart = Date()
        progress(Progress(fraction: 0, label: "Loading second-opinion ASR (\(options.whisperModel.displayName))..."))
        try await whisper.loadModel(
            variant: options.whisperModel.whisperKitVariant,
            progressCallback: { fraction in
                let firstRunHint = fraction < 1.0
                    ? "Downloading \(options.whisperModel.displayName) (\(options.whisperModel.approximateSize))..."
                    : "Loading \(options.whisperModel.displayName)..."
                progress(Progress(
                    fraction: fraction * Weights.whisperLoad,
                    label: firstRunHint
                ))
            }
        )
        stageTimings["whisperLoad"] = Date().timeIntervalSince(whisperLoadStart)

        let whisperRunStart = Date()
        let engineBSegments = try await whisper.transcribe(
            audioPath: audioURL.path,
            language: options.language,
            audioDuration: options.audioDurationSeconds,
            progressCallback: { fraction, _ in
                let elapsedAudio = fraction * options.audioDurationSeconds
                let durationLabel = options.audioDurationSeconds > 0
                    ? " of \(Self.formattedDuration(options.audioDurationSeconds))"
                    : ""
                let label = options.audioDurationSeconds > 0
                    ? "Second opinion \(Self.formattedDuration(elapsedAudio))\(durationLabel)"
                    : "Second opinion transcribing..."
                progress(Progress(
                    fraction: Weights.whisperLoad + fraction * Weights.whisperRun,
                    label: label
                ))
                return true
            }
        )
        stageTimings["whisperRun"] = Date().timeIntervalSince(whisperRunStart)

        let sidecarStart = Date()
        progress(Progress(
            fraction: Weights.whisperLoad + Weights.whisperRun,
            label: "Patch editor reviewing candidate changes..."
        ))

        let sidecar = PatchReviewSidecar()
        let protectedTerms = Self.protectedTerms(
            explicit: options.protectedTerms,
            speakers: speakers
        )
        let review = try await sidecar.review(
            audioURL: audioURL,
            canonicalSegments: standardPass.segments,
            opinionSegments: engineBSegments,
            context: options.context,
            protectedTerms: protectedTerms,
            progress: { update in
                progress(Progress(
                    fraction: Weights.whisperLoad + Weights.whisperRun + update.fraction * Weights.patchReview,
                    label: update.label
                ))
            }
        )
        stageTimings["patchReviewSidecar"] = Date().timeIntervalSince(sidecarStart)
        if let sidecarSeconds = review.audit.wallClockSeconds {
            stageTimings["patchReviewWork"] = sidecarSeconds
        }
        stageTimings["deepTotal"] = Date().timeIntervalSince(runStart)

        let patchedSegments = Self.mergePatchedSegments(
            original: standardPass.segments,
            patched: review.segments
        )
        let patchedIndices = Set(review.audit.appliedPatches.map(\.segmentIndex))
        let notesByIndex = Self.patchNotes(from: review.audit.appliedPatches)
        let alternatives = Self.revertAlternatives(from: review.audit.appliedPatches)
        let styles = StylePair(
            verbatimText: standardPass.segments.map(\.text),
            cleanText: patchedSegments.map(\.text)
        )

        progress(Progress(fraction: 1.0, label: "Done"))

        return TranscriptPass(
            kind: .deep,
            segments: patchedSegments,
            uncertainSegmentIndices: patchedIndices,
            alternativesByIndex: alternatives,
            patchReviewNotesByIndex: notesByIndex,
            engineAttribution: EngineAttribution(
                primaryEngine: standardPass.engineAttribution.primaryEngine,
                supportingEngines: [
                    "\(options.whisperModel.displayName) second opinion",
                    "VibeVoice local re-listen",
                    "Voxtral masked-cloze verifier",
                ],
                diarizer: standardPass.engineAttribution.diarizer,
                language: options.language
            ),
            styles: styles,
            quality: QualitySummary(
                diarizationConfidence: standardPass.quality.diarizationConfidence,
                uncertainSegmentCount: patchedIndices.count,
                stageTimings: stageTimings
            )
        )
    }

    private static func protectedTerms(explicit: [String], speakers: [Speaker]) -> [String] {
        var seen = Set<String>()
        var out: [String] = []
        func add(_ value: String) {
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, !trimmed.hasPrefix("Speaker ") else { return }
            let key = trimmed.lowercased()
            guard !seen.contains(key) else { return }
            seen.insert(key)
            out.append(trimmed)
        }
        explicit.forEach(add)
        speakers.filter(\.isConfirmed).map(\.displayName).forEach(add)
        return out
    }

    private static func mergePatchedSegments(
        original: [TranscriptionSegment],
        patched: [PatchReviewSidecar.SidecarSegment]
    ) -> [TranscriptionSegment] {
        guard !patched.isEmpty else { return original }
        return original.enumerated().map { index, originalSegment in
            guard index < patched.count else { return originalSegment }
            let patchSegment = patched[index]
            var segment = originalSegment
            let newText = patchSegment.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !newText.isEmpty, newText != segment.text else { return segment }
            segment.text = newText
            segment.words = synthesizeWordTimings(
                text: newText,
                segmentStart: segment.start,
                segmentEnd: segment.end
            )
            return segment
        }
    }

    private static func patchNotes(
        from events: [PatchReviewSidecar.PatchEvent]
    ) -> [Int: [PatchReviewNote]] {
        Dictionary(grouping: events, by: \.segmentIndex).mapValues { grouped in
            grouped.map { event in
                PatchReviewNote(
                    stage: event.stage,
                    source: event.source,
                    find: event.find,
                    replace: event.replace,
                    confidence: event.confidence,
                    reason: event.reason
                )
            }
        }
    }

    private static func revertAlternatives(
        from events: [PatchReviewSidecar.PatchEvent]
    ) -> [Int: [TurnAlternative]] {
        var byIndex: [Int: [TurnAlternative]] = [:]
        var seen: [Int: Set<String>] = [:]
        for event in events {
            let before = event.beforeSegment.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !before.isEmpty else { continue }
            if seen[event.segmentIndex, default: []].contains(before) { continue }
            seen[event.segmentIndex, default: []].insert(before)
            byIndex[event.segmentIndex, default: []].append(
                TurnAlternative(source: "Original VibeVoice", text: before)
            )
        }
        return byIndex
    }

    private static func synthesizeWordTimings(
        text: String,
        segmentStart: TimeInterval,
        segmentEnd: TimeInterval
    ) -> [TranscriptionSegment.WordTiming]? {
        let tokens = text.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        guard !tokens.isEmpty else { return nil }
        let duration = max(segmentEnd - segmentStart, 0.001)
        let perToken = duration / Double(tokens.count)
        return tokens.enumerated().map { index, token in
            let start = segmentStart + Double(index) * perToken
            return TranscriptionSegment.WordTiming(
                word: token,
                start: Float(start),
                end: Float(start + perToken),
                probability: 0.90
            )
        }
    }

    private static func formattedDuration(_ seconds: Double) -> String {
        let total = Int(seconds.rounded())
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

// MARK: - Python sidecar bridge

actor PatchReviewSidecar {
    struct Progress: Sendable {
        let fraction: Double
        let label: String
    }

    struct Result: Sendable {
        let segments: [SidecarSegment]
        let audit: Audit
    }

    struct SidecarPaths {
        let pythonInterpreter: URL
        let scriptURL: URL
        let vibeVoiceModelURL: URL
        let verifierModelURL: URL
        let verifierProjectorURL: URL
        let llamaCLIURL: URL
        let ffmpegURL: URL

        var missingDescriptions: [String] {
            var missing: [String] = []
            if !FileManager.default.fileExists(atPath: pythonInterpreter.path) {
                missing.append("Python venv at \(pythonInterpreter.path)")
            }
            if !FileManager.default.fileExists(atPath: scriptURL.path) {
                missing.append("patch-review sidecar at \(scriptURL.path)")
            }
            if !FileManager.default.isReadableFile(atPath: vibeVoiceModelURL.path) {
                missing.append("VibeVoice model at \(vibeVoiceModelURL.path)")
            }
            if !FileManager.default.isReadableFile(atPath: verifierModelURL.path) {
                missing.append("Voxtral verifier model at \(verifierModelURL.path)")
            }
            if !FileManager.default.isReadableFile(atPath: verifierProjectorURL.path) {
                missing.append("Voxtral projector at \(verifierProjectorURL.path)")
            }
            if !FileManager.default.isExecutableFile(atPath: llamaCLIURL.path) {
                missing.append("llama-mtmd-cli at \(llamaCLIURL.path)")
            }
            if !FileManager.default.isExecutableFile(atPath: ffmpegURL.path) {
                missing.append("ffmpeg at \(ffmpegURL.path)")
            }
            return missing
        }
    }

    struct SidecarPayload: Codable, Sendable {
        var segments: [SidecarSegment]
    }

    struct SidecarSegment: Codable, Sendable {
        var start: Double
        var end: Double
        var speakerID: String?
        var text: String

        enum CodingKeys: String, CodingKey {
            case start, end, text
            case speakerID = "speaker_id"
        }

        init(segment: TranscriptionSegment) {
            self.start = segment.start
            self.end = segment.end
            self.speakerID = segment.speakerID
            self.text = segment.text
        }
    }

    struct Audit: Decodable, Sendable {
        var architecture: String?
        var candidateSegmentCount: Int?
        var appliedCount: Int?
        var appliedPatches: [PatchEvent]
        var wallClockSeconds: Double?
    }

    struct PatchEvent: Decodable, Sendable {
        var segmentIndex: Int
        var stage: String
        var source: String
        var find: String
        var replace: String
        var beforeSegment: String
        var afterSegment: String
        var confidence: Double?
        var reason: String?
    }

    private struct StderrEvent: Decodable {
        var message: String?
        var fraction: Double?
    }

    static func defaultPaths() -> SidecarPaths {
        let projectRoot = URL(fileURLWithPath: "/Users/brantkuehn/Projects/Consensus")
        let vibeVoiceRig = projectRoot.appendingPathComponent("Brainstorming/vibevoice-test")
        let verifierRoot = projectRoot.appendingPathComponent("Brainstorming/phase-a-vibevoice-nemotron/voxtral-small")
        return SidecarPaths(
            pythonInterpreter: vibeVoiceRig.appendingPathComponent("venv/bin/python"),
            scriptURL: projectRoot.appendingPathComponent("TranscriboApp/Scripts/PatchReviewSidecar/run_patch_review.py"),
            vibeVoiceModelURL: vibeVoiceRig.appendingPathComponent("model-4bit"),
            verifierModelURL: verifierRoot.appendingPathComponent("Voxtral-Small-24B-Q4_K_M.gguf"),
            verifierProjectorURL: verifierRoot.appendingPathComponent("mmproj-Voxtral-Small-24B-f16.gguf"),
            llamaCLIURL: URL(fileURLWithPath: "/opt/homebrew/bin/llama-mtmd-cli"),
            ffmpegURL: URL(fileURLWithPath: "/opt/homebrew/bin/ffmpeg")
        )
    }

    static func availabilityError() -> String? {
        let missing = defaultPaths().missingDescriptions
        return missing.isEmpty ? nil : "Patch Review setup incomplete. Missing: \(missing.joined(separator: "; "))."
    }

    func review(
        audioURL: URL,
        canonicalSegments: [TranscriptionSegment],
        opinionSegments: [TranscriptionSegment],
        context: String?,
        protectedTerms: [String],
        progress: @escaping @Sendable (Progress) -> Void
    ) async throws -> Result {
        let paths = Self.defaultPaths()
        let missing = paths.missingDescriptions
        guard missing.isEmpty else {
            throw ConsensusError.transcriptionFailed("Patch Review setup incomplete. Missing: \(missing.joined(separator: "; ")).")
        }

        let workDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("consensus-patch-review-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workDir) }

        let canonicalURL = workDir.appendingPathComponent("canonical.json")
        let opinionURL = workDir.appendingPathComponent("opinion.json")
        let outputURL = workDir.appendingPathComponent("patched.json")
        let auditURL = workDir.appendingPathComponent("audit.json")

        try Self.writePayload(SidecarPayload(segments: canonicalSegments.map(SidecarSegment.init)), to: canonicalURL)
        try Self.writePayload(SidecarPayload(segments: opinionSegments.map(SidecarSegment.init)), to: opinionURL)

        let process = Process()
        process.executableURL = paths.pythonInterpreter
        var arguments = [
            paths.scriptURL.path,
            "--vibevoice-json", canonicalURL.path,
            "--opinion-json", opinionURL.path,
            "--audio", audioURL.path(percentEncoded: false),
            "--vibevoice-model", paths.vibeVoiceModelURL.path,
            "--gguf", paths.verifierModelURL.path,
            "--mmproj", paths.verifierProjectorURL.path,
            "--out", outputURL.path,
            "--audit-log", auditURL.path,
            "--ffmpeg", paths.ffmpegURL.path,
            "--llama-mtmd-cli", paths.llamaCLIURL.path,
            "--protected-terms", protectedTerms.joined(separator: ", "),
        ]
        if let context, !context.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            arguments.append("--context")
            arguments.append(context)
        }
        process.arguments = arguments

        var environment = ProcessInfo.processInfo.environment
        let extraPathDirs = ["/opt/homebrew/bin", "/usr/local/bin", "/opt/local/bin"]
        let existingPath = environment["PATH"] ?? "/usr/bin:/bin"
        let mergedPath = (extraPathDirs + existingPath.split(separator: ":").map(String.init))
            .reduce(into: [String]()) { acc, item in
                if !acc.contains(item) { acc.append(item) }
            }
        environment["PATH"] = mergedPath.joined(separator: ":")
        process.environment = environment

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        let stderrBuffer = StderrBuffer()
        let progressTask = Task.detached {
            let handle = stderrPipe.fileHandleForReading
            var pending = Data()
            while true {
                let chunk = handle.availableData
                if chunk.isEmpty { break }
                pending.append(chunk)
                await stderrBuffer.append(chunk)
                while let newlineRange = pending.range(of: Data([0x0a])) {
                    let lineData = pending.subdata(in: 0..<newlineRange.lowerBound)
                    pending.removeSubrange(0..<newlineRange.upperBound)
                    guard let line = String(data: lineData, encoding: .utf8),
                          !line.isEmpty,
                          let jsonData = line.data(using: .utf8),
                          let event = try? JSONDecoder().decode(StderrEvent.self, from: jsonData)
                    else { continue }
                    progress(Progress(
                        fraction: event.fraction ?? 0,
                        label: event.message ?? "Patch editor reviewing..."
                    ))
                }
            }
        }

        let stdoutTask = Task.detached {
            let handle = stdoutPipe.fileHandleForReading
            while !handle.availableData.isEmpty { }
        }

        try process.run()
        let childPID = process.processIdentifier

        await withTaskCancellationHandler {
            await Self.waitForExit(process: process)
        } onCancel: {
            _ = Darwin.kill(-childPID, SIGTERM)
        }

        await progressTask.value
        await stdoutTask.value

        guard process.terminationStatus == 0 else {
            let captured = await stderrBuffer.readAll()
            let snippet = Self.lastNonProgressLines(captured, maxLines: 14)
            throw ConsensusError.transcriptionFailed(
                "Patch Review sidecar exited with code \(process.terminationStatus).\nSidecar: \(paths.scriptURL.path)\n\nStderr:\n\(snippet)"
            )
        }

        let payload = try Self.readPayload(at: outputURL)
        let audit = try Self.readAudit(at: auditURL)
        return Result(segments: payload.segments, audit: audit)
    }

    private static func waitForExit(process: Process) async {
        while process.isRunning {
            try? await Task.sleep(nanoseconds: 250_000_000)
        }
    }

    private actor StderrBuffer {
        private var data = Data()
        func append(_ chunk: Data) { data.append(chunk) }
        func readAll() -> String { String(data: data, encoding: .utf8) ?? "" }
    }

    private static func lastNonProgressLines(_ text: String, maxLines: Int) -> String {
        let lines = text
            .split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("{") }
        let suffix = lines.suffix(maxLines).joined(separator: "\n")
        return suffix.isEmpty ? "(no stderr output)" : suffix
    }

    private static func writePayload(_ payload: SidecarPayload, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(payload).write(to: url, options: [.atomic])
    }

    private static func readPayload(at url: URL) throws -> SidecarPayload {
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(SidecarPayload.self, from: data)
    }

    private static func readAudit(at url: URL) throws -> Audit {
        let data = try Data(contentsOf: url)
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(Audit.self, from: data)
    }
}
