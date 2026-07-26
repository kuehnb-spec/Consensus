import Foundation
import IOKit
import IOKit.pwr_mgt
import Darwin

/// Bridges the macOS app to Microsoft's VibeVoice ASR via a Python+MLX sidecar.
///
/// VibeVoice produces transcription **and** speaker diarization in a single inference
/// pass. Pipeline callers should treat this engine as self-diarizing
/// (`TranscriptionEngineDescriptor.providesOwnDiarization == true`).
///
/// **Dev-mode integration**: the venv and model live in the project's Brainstorming
/// directory. Production builds will need to bundle Python + the MLX model into the
/// app (or convert the model to Core ML). Tracked in
/// `Brainstorming/vibevoice-test/RESULTS.md`.
///
/// **Lifecycle hardening (April 29 fix)**: the April 28 thermal-shutdown chain
/// taught us that a long-running 5+ GB Python child plus the ability for the
/// user to close the lid mid-run is a system-killer. Three guards are now in
/// place:
///   1. The sidecar puts itself in its own process group (`os.setpgrp()`),
///      and Swift records the PID so it can `kill(-pgid, SIGTERM)` the whole
///      tree on cancellation or app quit. No more orphans.
///   2. An IOPMAssertion (`PreventUserIdleSystemSleep`) is held for the
///      duration of every run, so closing the laptop lid doesn't trigger
///      Clamshell Sleep on a heavily-loaded system.
///   3. A memory preflight via `vm_statistics64` warns the caller before
///      starting if free + inactive RAM is below the working-set the model
///      will need.
actor VibeVoiceTranscriptionService {

    // MARK: - Active sidecar registry (process-group cleanup)

    /// Tracks every currently-running sidecar across all instances of this
    /// service so the AppDelegate's `applicationWillTerminate` hook can nuke
    /// them in one shot. Each entry's PID is the leader of its own process
    /// group (the sidecar calls `os.setpgrp()` on startup).
    private actor ActiveSidecars {
        private var pids = Set<pid_t>()

        func register(_ pid: pid_t) { pids.insert(pid) }
        func unregister(_ pid: pid_t) { pids.remove(pid) }
        func snapshot() -> [pid_t] { Array(pids) }
    }

    private static let active = ActiveSidecars()

    /// Kill every running sidecar, sending SIGTERM to the process group of
    /// each tracked PID. Called from `AppDelegate.applicationWillTerminate`.
    /// Best-effort: if the process is already gone, the kill simply errors
    /// out and is ignored. After a short grace period we send SIGKILL to
    /// anything that didn't respond.
    nonisolated static func terminateAllActiveSidecars() {
        let group = DispatchGroup()
        group.enter()
        Task.detached {
            defer { group.leave() }
            let pids = await active.snapshot()
            for pid in pids {
                _ = Darwin.kill(-pid, SIGTERM)
            }
            // Give the children up to 1.5 seconds to exit cleanly, then SIGKILL
            // anything that's still around. We block here because this is
            // called from `applicationWillTerminate` which is synchronous.
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            let stillAlive = await active.snapshot()
            for pid in stillAlive {
                _ = Darwin.kill(-pid, SIGKILL)
            }
        }
        // Synchronous-with-timeout wait so applicationWillTerminate doesn't
        // race the OS killing the parent.
        _ = group.wait(timeout: .now() + 2.5)
    }
    struct SidecarPaths {
        let pythonInterpreter: URL
        let scriptURL: URL
        let modelURL: URL

        var allExist: Bool {
            FileManager.default.fileExists(atPath: pythonInterpreter.path) &&
            FileManager.default.fileExists(atPath: scriptURL.path) &&
            FileManager.default.isReadableFile(atPath: modelURL.path)
        }
    }

    /// Resolves dev-mode paths to the test-rig venv, sidecar script, and downloaded model.
    static func defaultPaths() -> SidecarPaths {
        let projectRoot = URL(fileURLWithPath: "/Users/brantkuehn/Projects/Consensus")
        let testRig = projectRoot.appendingPathComponent("Brainstorming/vibevoice-test")
        return SidecarPaths(
            pythonInterpreter: testRig.appendingPathComponent("venv/bin/python"),
            scriptURL: projectRoot.appendingPathComponent("TranscriboApp/Scripts/VibeVoiceSidecar/run.py"),
            modelURL: testRig.appendingPathComponent("model-4bit")
        )
    }

    /// Quick smoke check the user can hit before kicking off a real run.
    static func availabilityError() -> String? {
        let paths = defaultPaths()
        var missing: [String] = []
        if !FileManager.default.fileExists(atPath: paths.pythonInterpreter.path) {
            missing.append("Python venv at \(paths.pythonInterpreter.path)")
        }
        if !FileManager.default.fileExists(atPath: paths.scriptURL.path) {
            missing.append("sidecar script at \(paths.scriptURL.path)")
        }
        if !FileManager.default.isReadableFile(atPath: paths.modelURL.path) {
            missing.append("model directory at \(paths.modelURL.path)")
        }
        return missing.isEmpty ? nil : "VibeVoice setup incomplete. Missing: \(missing.joined(separator: "; "))."
    }

    /// Progress callback signature:
    /// `(fraction, status, recentText, tokenCount, tokensPerSecond)`.
    /// - `fraction`: 0–1 progress; ≥0 means a fresh value, <0 means "no update".
    /// - `status`: short status line ("Transcribing... 1234 tokens, 50/s").
    /// - `recentText`: trailing slice of the accumulating transcript, stripped
    ///   of the model's structured-JSON wrapper. Surfaces in the progress card
    ///   so the user can see the model is producing real content. May be nil
    ///   for events that don't include it (load, parse, done).
    /// - `tokenCount`: total generated tokens reported by the sidecar.
    /// - `tokensPerSecond`: current streaming speed reported by the sidecar.
    typealias ProgressCallback = @Sendable (
        _ fraction: Double,
        _ status: String?,
        _ recentText: String?,
        _ tokenCount: Int?,
        _ tokensPerSecond: Double?
    ) -> Void

    func transcribe(
        audioURL: URL,
        context: String?,
        audioDuration: TimeInterval = 0,
        progressCallback: @escaping ProgressCallback
    ) async throws -> [TranscriptionSegment] {
        let paths = Self.defaultPaths()
        guard paths.allExist else {
            throw ConsensusError.transcriptionFailed(
                Self.availabilityError() ?? "VibeVoice sidecar not configured."
            )
        }

        // Memory preflight. The 4-bit MLX VibeVoice peaks around 6 GB RSS in
        // the sidecar; the parent app holds another 0.5–2 GB. Add headroom
        // so the OS doesn't fall into the compression-thrash regime that
        // cooked the laptop on April 28. Threshold is intentionally
        // conservative — we'd rather warn occasionally than crash once.
        if let issue = Self.memoryPreflightWarning() {
            throw ConsensusError.transcriptionFailed(issue)
        }

        // Hold a power-management assertion so closing the laptop lid mid-run
        // doesn't put a 5 GB resident model into Clamshell Sleep — that's the
        // path that turned a memory-pressure event into a thermal shutdown
        // last time. Released in the defer below regardless of how we exit.
        let assertionID = Self.acquireSleepAssertion()
        defer { Self.releaseSleepAssertion(assertionID) }

        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("vibevoice-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: outputURL) }

        let process = Process()
        process.executableURL = paths.pythonInterpreter
        var arguments: [String] = [
            paths.scriptURL.path,
            "--model", paths.modelURL.path,
            "--audio", audioURL.path(percentEncoded: false),
            "--out", outputURL.path,
            "--max-tokens", "\(Self.maxTokens(forAudioDuration: audioDuration))"
        ]
        if let context, !context.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            arguments.append("--context")
            arguments.append(context)
        }
        if audioDuration > 0 {
            arguments.append("--audio-duration")
            arguments.append(String(format: "%.3f", audioDuration))
        }
        process.arguments = arguments

        // GUI apps launched via Launchd inherit a sparse PATH that omits
        // Homebrew (`/opt/homebrew/bin` on Apple Silicon, `/usr/local/bin` on
        // Intel). mlx-audio shells out to ffmpeg for M4A/AAC decoding, so we
        // augment PATH explicitly. Other env vars are passed through so the
        // venv's Python can find HOME, USER, HF cache, etc.
        var environment = ProcessInfo.processInfo.environment
        let extraPathDirs = [
            "/opt/homebrew/bin",
            "/usr/local/bin",
            "/opt/local/bin"
        ]
        let existingPath = environment["PATH"] ?? "/usr/bin:/bin"
        let pathParts = existingPath.split(separator: ":").map(String.init)
        let merged = (extraPathDirs + pathParts).reduce(into: [String]()) { acc, dir in
            if !acc.contains(dir) { acc.append(dir) }
        }
        environment["PATH"] = merged.joined(separator: ":")
        process.environment = environment

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        // Buffer the full stderr stream so we can both surface JSON progress
        // events as they arrive AND keep every line for the error path. The
        // earlier implementation drained stderr into the progress callback only,
        // leaving the error path with an empty pipe whenever the sidecar failed.
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
                          let json = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any] else {
                        continue
                    }
                    let message = (json["message"] as? String) ?? ""
                    let fraction = (json["fraction"] as? NSNumber)?.doubleValue ?? -1
                    let recentText = json["recent_text"] as? String
                    let tokenCount = (json["tokens"] as? NSNumber)?.intValue
                    let tokensPerSecond = (json["tokens_per_second"] as? NSNumber)?.doubleValue
                    progressCallback(
                        fraction >= 0 ? fraction : 0,
                        message,
                        recentText,
                        tokenCount,
                        tokensPerSecond
                    )
                }
            }
        }

        // Drain stdout in parallel — if the sidecar's output buffer fills, the
        // child blocks on write. The script doesn't print to stdout normally,
        // but mlx-audio progress bars can land there in some configurations.
        let stdoutDrainTask = Task.detached {
            let handle = stdoutPipe.fileHandleForReading
            while !handle.availableData.isEmpty { /* discard */ }
        }

        try process.run()

        // Register the child PID so AppDelegate.applicationWillTerminate (or
        // a Cancel button down the line) can nuke it. The child has already
        // called os.setpgrp() so its PID == its process-group ID; we kill via
        // -pgid to also reach any subprocesses (ffmpeg) it spawned.
        let childPID = process.processIdentifier
        await Self.active.register(childPID)
        defer {
            Task.detached { await Self.active.unregister(childPID) }
        }

        // withTaskCancellationHandler lets the caller cancel via Task.cancel()
        // and have the subprocess actually die instead of leaking.
        await withTaskCancellationHandler {
            await Self.waitForExit(process: process)
        } onCancel: {
            // Fired off the actor — Darwin.kill is signal-safe.
            _ = Darwin.kill(-childPID, SIGTERM)
        }

        await progressTask.value
        await stdoutDrainTask.value

        guard process.terminationStatus == 0 else {
            let captured = await stderrBuffer.readAll()
            let trimmed = captured.trimmingCharacters(in: .whitespacesAndNewlines)
            let snippet = trimmed.isEmpty
                ? "(no stderr output)"
                : Self.lastNonProgressLines(trimmed, maxLines: 12)
            let scriptHint = "Sidecar at \(paths.scriptURL.path)"
            let pythonHint = "Python: \(paths.pythonInterpreter.path)"
            throw ConsensusError.transcriptionFailed(
                "VibeVoice sidecar exited with code \(process.terminationStatus).\n\(scriptHint)\n\(pythonHint)\n\nStderr (last lines):\n\(snippet)"
            )
        }

        let outputData = try Data(contentsOf: outputURL)
        let payload = try JSONDecoder().decode(SidecarPayload.self, from: outputData)
        if payload.hit_token_limit == true {
            throw ConsensusError.transcriptionFailed(Self.tokenLimitMessage(from: payload))
        }
        let segments = Self.buildSegments(from: payload)
        guard !segments.isEmpty else {
            throw ConsensusError.transcriptionFailed(Self.emptyResultMessage(from: payload))
        }
        return segments
    }

    /// Filter to non-JSON-progress lines for surfacing in errors. JSON progress
    /// lines tell the user nothing useful about a crash; a real Python traceback
    /// or warning is what they want to see.
    private static func lastNonProgressLines(_ text: String, maxLines: Int) -> String {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.hasPrefix("{") }
        return lines.suffix(maxLines).joined(separator: "\n")
    }

    private actor StderrBuffer {
        private var data = Data()
        func append(_ chunk: Data) { data.append(chunk) }
        func readAll() -> String { String(data: data, encoding: .utf8) ?? "" }
    }

    // MARK: - Async wait wrapper

    /// `Process.waitUntilExit()` is synchronous. Wrap it so the caller's actor
    /// isn't blocked while the sidecar runs (5 minutes for a typical pass).
    /// Polls every 250 ms which is fine for a multi-minute job.
    private static func waitForExit(process: Process) async {
        while process.isRunning {
            try? await Task.sleep(nanoseconds: 250_000_000)
        }
    }

    // MARK: - Memory preflight

    /// Returns a user-facing warning string when free + inactive (compressible)
    /// memory is below ~10 GB. Returns nil when there's enough headroom.
    /// `vm_statistics64` numbers are pages; multiply by `vm_kernel_page_size`
    /// to get bytes.
    private static func memoryPreflightWarning() -> String? {
        let pageSize = UInt64(vm_kernel_page_size)
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size)
        let host = mach_host_self()
        let result = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(host, HOST_VM_INFO64, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }

        let freeBytes = UInt64(stats.free_count) * pageSize
        let inactiveBytes = UInt64(stats.inactive_count) * pageSize
        let availableBytes = freeBytes + inactiveBytes
        let totalBytes = ProcessInfo.processInfo.physicalMemory
        let usedBytes = totalBytes > availableBytes ? totalBytes - availableBytes : 0

        // Working set: ~6 GB sidecar peak + ~2 GB app + 2 GB headroom = 10 GB.
        let requiredBytes: UInt64 = 10 * 1024 * 1024 * 1024
        if availableBytes >= requiredBytes { return nil }

        let availableGB = Double(availableBytes) / 1_073_741_824.0
        let totalGB = Double(totalBytes) / 1_073_741_824.0
        let usedGB = Double(usedBytes) / 1_073_741_824.0
        return String(
            format: "Not enough free memory to start VibeVoice safely. About %.1f GB available out of %.1f GB total (%.1f GB in use). VibeVoice needs ~10 GB headroom (5 GB model weights + working memory). Close some apps and try again.",
            availableGB, totalGB, usedGB
        )
    }

    // MARK: - Sleep assertion

    /// Acquire a "prevent user idle system sleep" assertion so closing the lid
    /// or letting the system idle doesn't put the laptop to sleep with a 5 GB
    /// MLX model resident. Returns 0 on failure (release is a no-op for 0).
    private static func acquireSleepAssertion() -> IOPMAssertionID {
        var assertionID: IOPMAssertionID = 0
        let reason = "Consensus is running a VibeVoice transcription" as CFString
        let result = IOPMAssertionCreateWithName(
            kIOPMAssertionTypePreventUserIdleSystemSleep as CFString,
            IOPMAssertionLevel(kIOPMAssertionLevelOn),
            reason,
            &assertionID
        )
        return result == kIOReturnSuccess ? assertionID : 0
    }

    private static func releaseSleepAssertion(_ id: IOPMAssertionID) {
        guard id != 0 else { return }
        IOPMAssertionRelease(id)
    }

    // MARK: - Payload

    private struct SidecarPayload: Decodable {
        let segments: [SidecarSegment]?
        let raw_text: String?
        let load_seconds: Double?
        let wall_clock_seconds: Double?
        let tokens_generated: Int?
        let max_tokens: Int?
        let hit_token_limit: Bool?
    }

    private struct SidecarSegment: Decodable {
        let start: Double?
        let end: Double?
        let speaker_id: SpeakerID?
        let text: String?

        // VibeVoice's JSON sometimes emits speaker as int, sometimes string.
        enum SpeakerID: Decodable {
            case int(Int)
            case string(String)

            init(from decoder: Decoder) throws {
                let container = try decoder.singleValueContainer()
                if let i = try? container.decode(Int.self) {
                    self = .int(i)
                } else {
                    self = .string(try container.decode(String.self))
                }
            }

            var canonical: String {
                switch self {
                case .int(let i): return "VV_\(i)"
                case .string(let s):
                    let trimmed = s.trimmingCharacters(in: .whitespaces)
                    return trimmed.isEmpty ? "VV_0" : (trimmed.hasPrefix("VV_") ? trimmed : "VV_\(trimmed)")
                }
            }
        }
    }

    private static func buildSegments(from payload: SidecarPayload) -> [TranscriptionSegment] {
        guard let raw = payload.segments, !raw.isEmpty else { return [] }

        var built: [TranscriptionSegment] = []
        for seg in raw {
            let text = (seg.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            let start = seg.start ?? 0
            let end = max(start, seg.end ?? start)
            let speaker = seg.speaker_id?.canonical ?? "VV_0"

            let words = synthesizeWordTimings(text: text, segmentStart: start, segmentEnd: end)
            built.append(
                TranscriptionSegment(
                    speakerID: speaker,
                    start: start,
                    end: end,
                    text: text,
                    words: words,
                    averageLogProb: -0.05,
                    noSpeechProb: 0.05,
                    diarizationQuality: 0.95
                )
            )
        }
        return built
    }

    private static func maxTokens(forAudioDuration duration: TimeInterval) -> Int {
        guard duration > 0 else { return 8_192 }

        // VibeVoice emits structured JSON, so output tokens scale with audio
        // duration plus wrapper overhead. The old fixed 8192 cap was enough
        // for short gold fixtures, but it can truncate long legal calls before
        // the JSON closes, leaving parse_transcription with zero segments.
        // Use a deliberately generous budget for dense conversational audio;
        // if the sidecar still hits the ceiling, we fail loud rather than save
        // a partial transcript.
        let estimated = Int((duration * 12.0).rounded(.up))
        return min(max(8_192, estimated + 4_096), 65_536)
    }

    private static func tokenLimitMessage(from payload: SidecarPayload) -> String {
        var pieces = [
            "VibeVoice reached its transcript token limit before it clearly finished."
        ]
        if let tokens = payload.tokens_generated {
            if let maxTokens = payload.max_tokens {
                pieces.append("Generated \(tokens) of \(maxTokens) allowed tokens.")
            } else {
                pieces.append("Generated \(tokens) tokens.")
            }
        }
        if let seconds = payload.wall_clock_seconds {
            pieces.append(String(format: "Generation ran for %.1f seconds.", seconds))
        }
        pieces.append("Consensus did not save this pass because it may be incomplete. Retry with the current build; it uses a larger duration-scaled budget and refuses partial results.")
        return pieces.joined(separator: " ")
    }

    private static func emptyResultMessage(from payload: SidecarPayload) -> String {
        var pieces = [
            "VibeVoice finished but did not return any transcript segments."
        ]
        if let tokens = payload.tokens_generated {
            pieces.append("Generated \(tokens) tokens before parsing.")
        }
        if let seconds = payload.wall_clock_seconds {
            pieces.append(String(format: "Generation ran for %.1f seconds.", seconds))
        }
        if let raw = payload.raw_text?.trimmingCharacters(in: .whitespacesAndNewlines),
           !raw.isEmpty {
            let preview = raw.count > 320 ? "...\(raw.suffix(320))" : raw
            pieces.append("Raw output tail: \(preview)")
        } else {
            pieces.append("The raw model output was empty.")
        }
        pieces.append("For long recordings, retry after this build; Consensus now allocates a duration-scaled VibeVoice token budget instead of the old short-recording cap.")
        return pieces.joined(separator: " ")
    }

    /// VibeVoice doesn't emit per-word timings, so we synthesize them by linearly
    /// distributing tokens across the segment duration. Confidence is set to a flat
    /// high value because the model doesn't expose token-level probabilities through
    /// the current mlx-audio API. Synthesized timings keep downstream code (export,
    /// confidence merge, etc.) functional even though the timing is approximate.
    private static func synthesizeWordTimings(
        text: String,
        segmentStart: TimeInterval,
        segmentEnd: TimeInterval
    ) -> [TranscriptionSegment.WordTiming]? {
        let tokens = text.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        guard !tokens.isEmpty else { return nil }

        let duration = max(segmentEnd - segmentStart, 0.001)
        let perToken = duration / Double(tokens.count)
        var timings: [TranscriptionSegment.WordTiming] = []
        timings.reserveCapacity(tokens.count)
        for (index, token) in tokens.enumerated() {
            let start = segmentStart + Double(index) * perToken
            let end = start + perToken
            timings.append(
                TranscriptionSegment.WordTiming(
                    word: token,
                    start: Float(start),
                    end: Float(end),
                    probability: 0.95
                )
            )
        }
        return timings
    }
}
