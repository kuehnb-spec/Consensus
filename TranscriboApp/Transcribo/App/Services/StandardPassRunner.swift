import Foundation

/// Runs the standard (single-engine) transcription pass for the rewritten
/// UI. Wraps the existing `FluidAsrTranscriptionService` (Parakeet) and
/// `SpeakerKitDiarizationService`, merges their outputs via
/// `SegmentMerger`, and emits aggregated progress as one 0–1 fraction so
/// the progress bar in `DeepReadRootView` doesn't have to know about the
/// individual stages.
///
/// The Standard pass is now the canonical draft for Deep Review. The Deep
/// tier layers second-opinion ASR and patch-centered audio verification on
/// top of this output rather than asking an LLM to rewrite the transcript.
final class StandardPassRunner {
    private let asr = FluidAsrTranscriptionService()
    private let diarizer = SpeakerKitDiarizationService()
    private let vibevoice = VibeVoiceTranscriptionService()

    struct Progress: Sendable {
        /// Aggregated fraction across all stages. `0` → `1`.
        let fraction: Double
        /// Short user-facing label ("Loading Parakeet…", "Transcribing 3:12 of 8:00", …).
        let label: String
        /// Machine/status detail suitable for a fixed-width status strip.
        let status: String?
        /// Incremental live transcript text emitted by VibeVoice.
        let recentText: String?
        /// Total generated tokens reported by VibeVoice.
        let tokenCount: Int?
        /// Current VibeVoice streaming speed.
        let tokensPerSecond: Double?

        init(
            fraction: Double,
            label: String,
            status: String? = nil,
            recentText: String? = nil,
            tokenCount: Int? = nil,
            tokensPerSecond: Double? = nil
        ) {
            self.fraction = fraction
            self.label = label
            self.status = status
            self.recentText = recentText
            self.tokenCount = tokenCount
            self.tokensPerSecond = tokensPerSecond
        }
    }

    struct Options: Sendable {
        /// Which Standard-pass engine to run. Default is VibeVoice (April 28
        /// benchmark winner; runs joint ASR + diarization in a single pass
        /// and skips the separate SpeakerKit step).
        var engine: RewrittenEngineChoice = .vibevoice
        var variant: FluidAsrModelVariant = .parakeetV3
        var language: String = "en"
        var requestedSpeakerCount: Int? = nil
        var audioDurationSeconds: Double = 0
        /// Optional hotwords forwarded to VibeVoice's `context=` parameter.
        /// Comma-separated, e.g. "Brant Kuehn, Marie Larsen, JAMS". Ignored
        /// for engines other than VibeVoice.
        var vibeVoiceContext: String? = nil

        init(
            engine: RewrittenEngineChoice = .vibevoice,
            variant: FluidAsrModelVariant = .parakeetV3,
            language: String = "en",
            requestedSpeakerCount: Int? = nil,
            audioDurationSeconds: Double = 0,
            vibeVoiceContext: String? = nil
        ) {
            self.engine = engine
            self.variant = variant
            self.language = language
            self.requestedSpeakerCount = requestedSpeakerCount
            self.audioDurationSeconds = audioDurationSeconds
            self.vibeVoiceContext = vibeVoiceContext
        }
    }

    /// Stage weightings used to map sub-stage progress into the unified
    /// 0–1 range. Tuned to match rough wall-clock ratios on Apple Silicon.
    private enum Weights {
        static let modelPrep: Double = 0.15
        static let transcribe: Double = 0.55
        static let diarize: Double = 0.25
        static let merge: Double = 0.05
    }

    /// Run the full standard pass. `progress` is called on the caller's
    /// actor/task — wrap in `Task { @MainActor in … }` if you're updating
    /// SwiftUI state from it.
    func run(
        audioURL: URL,
        options: Options,
        progress: @escaping @Sendable (Progress) -> Void
    ) async throws -> TranscriptPass {
        switch options.engine {
        case .vibevoice:
            return try await runVibeVoice(audioURL: audioURL, options: options, progress: progress)
        case .parakeet:
            return try await runParakeet(audioURL: audioURL, options: options, progress: progress)
        }
    }

    // MARK: - VibeVoice path (joint ASR + diarization)

    private func runVibeVoice(
        audioURL: URL,
        options: Options,
        progress: @escaping @Sendable (Progress) -> Void
    ) async throws -> TranscriptPass {
        let start = Date()
        var stageTimings: [String: Double] = [:]

        if let issue = VibeVoiceTranscriptionService.availabilityError() {
            throw ConsensusError.modelDownloadFailed(issue)
        }

        progress(Progress(fraction: 0, label: "Preparing VibeVoice…"))

        let transcribeStart = Date()

        // VibeVoice does ASR + diarization in one pass — single weighted
        // stage that covers everything except the final "merge" no-op.
        let asrAndDiarWeight = Weights.modelPrep + Weights.transcribe + Weights.diarize
        let segments = try await vibevoice.transcribe(
            audioURL: audioURL,
            context: options.vibeVoiceContext,
            audioDuration: options.audioDurationSeconds,
            progressCallback: { fraction, status, recentText, tokenCount, tokensPerSecond in
                let statusLine = (status?.isEmpty == false ? status! : "Transcribing with VibeVoice")
                progress(Progress(
                    fraction: max(0.05, fraction * asrAndDiarWeight),
                    label: statusLine,
                    status: statusLine,
                    recentText: recentText,
                    tokenCount: tokenCount,
                    tokensPerSecond: tokensPerSecond
                ))
            }
        )
        stageTimings["vibevoice"] = Date().timeIntervalSince(transcribeStart)

        progress(Progress(fraction: asrAndDiarWeight, label: "Finalizing…"))
        stageTimings["total"] = Date().timeIntervalSince(start)

        progress(Progress(fraction: 1.0, label: "Done"))

        return TranscriptPass(
            kind: .standard,
            segments: segments,
            engineAttribution: EngineAttribution(
                primaryEngine: "VibeVoice ASR (MLX 4-bit)",
                supportingEngines: [],
                diarizer: "VibeVoice (built-in)",
                language: options.language
            ),
            styles: nil,
            quality: QualitySummary(
                diarizationConfidence: 0.95,
                uncertainSegmentCount: 0,
                stageTimings: stageTimings
            )
        )
    }

    // MARK: - Parakeet path (FluidAudio + SpeakerKit, original implementation)

    private func runParakeet(
        audioURL: URL,
        options: Options,
        progress: @escaping @Sendable (Progress) -> Void
    ) async throws -> TranscriptPass {
        let start = Date()
        var stageTimings: [String: Double] = [:]

        // --- Stage 1: model preparation --------------------------------
        progress(Progress(fraction: 0, label: "Preparing models…"))
        let prepStart = Date()

        async let asrPrep: Void = asr.prepareModel(variant: options.variant) { fraction in
            progress(Progress(
                fraction: fraction * Weights.modelPrep * 0.5,
                label: "Loading Parakeet…"
            ))
        }

        async let diarPrep: Void = diarizer.prepareModels { fraction in
            progress(Progress(
                fraction: Weights.modelPrep * 0.5 + fraction * Weights.modelPrep * 0.5,
                label: "Loading SpeakerKit…"
            ))
        }

        _ = try await (asrPrep, diarPrep)
        stageTimings["modelPrep"] = Date().timeIntervalSince(prepStart)

        // --- Stage 2: transcribe --------------------------------------
        let transcribeStart = Date()
        let durationLabel = options.audioDurationSeconds > 0
            ? " of \(Self.formattedDuration(options.audioDurationSeconds))"
            : ""

        let segments = try await asr.transcribe(
            audioURL: audioURL,
            variant: options.variant,
            progressCallback: { fraction in
                let elapsedAudio = fraction * options.audioDurationSeconds
                let prefix = options.audioDurationSeconds > 0
                    ? "Transcribing \(Self.formattedDuration(elapsedAudio))\(durationLabel)"
                    : "Transcribing…"
                progress(Progress(
                    fraction: Weights.modelPrep + fraction * Weights.transcribe,
                    label: prefix
                ))
            }
        )
        stageTimings["transcribe"] = Date().timeIntervalSince(transcribeStart)

        // --- Stage 3: diarize -----------------------------------------
        let diarizeStart = Date()
        let diarization = try await diarizer.diarize(
            audioURL: audioURL,
            numberOfSpeakers: options.requestedSpeakerCount,
            clusterDistanceThreshold: nil,
            progressCallback: { fraction in
                progress(Progress(
                    fraction: Weights.modelPrep + Weights.transcribe + fraction * Weights.diarize,
                    label: "Identifying speakers…"
                ))
            }
        )
        stageTimings["diarize"] = Date().timeIntervalSince(diarizeStart)

        // --- Stage 4: merge -------------------------------------------
        let mergeStart = Date()
        progress(Progress(
            fraction: Weights.modelPrep + Weights.transcribe + Weights.diarize,
            label: "Merging…"
        ))
        let merged = SegmentMerger.merge(
            transcriptionSegments: segments,
            diarizationSegments: diarization
        )
        stageTimings["merge"] = Date().timeIntervalSince(mergeStart)

        // --- Quality summary -------------------------------------------
        let diarizationConfidence = diarization.isEmpty
            ? nil
            : diarization.map { Double($0.qualityScore) }.reduce(0, +) / Double(diarization.count)
        stageTimings["total"] = Date().timeIntervalSince(start)

        progress(Progress(fraction: 1.0, label: "Done"))

        return TranscriptPass(
            kind: .standard,
            segments: merged,
            engineAttribution: EngineAttribution(
                primaryEngine: options.variant.displayName,
                supportingEngines: [],
                diarizer: "SpeakerKit (pyannote v4)",
                language: options.language
            ),
            styles: nil,
            quality: QualitySummary(
                diarizationConfidence: diarizationConfidence,
                uncertainSegmentCount: 0,
                stageTimings: stageTimings
            )
        )
    }

    /// Returns the speaker roster for the merged segments, assigning a
    /// stable palette index per unique speaker ID in first-appearance order.
    static func speakerRoster(for segments: [TranscriptionSegment]) -> [Speaker] {
        var seen: [String: Int] = [:]
        var roster: [Speaker] = []
        for segment in segments {
            if seen[segment.speakerID] == nil {
                let index = seen.count
                seen[segment.speakerID] = index
                roster.append(Speaker(
                    id: segment.speakerID,
                    displayName: Self.defaultDisplayName(for: segment.speakerID, index: index),
                    voiceLibraryID: nil,
                    isConfirmed: false,
                    paletteIndex: index % ConsensusTheme.Colors.speakerPalette.count
                ))
            }
        }
        return roster
    }

    private static func defaultDisplayName(for speakerID: String, index: Int) -> String {
        // Pretty-print "SPEAKER_0" → "Speaker 1" for the initial roster;
        // user confirms or renames on the Phase 1c naming screen.
        if speakerID.uppercased().hasPrefix("SPEAKER_"),
           let n = Int(speakerID.split(separator: "_").last ?? "") {
            return "Speaker \(n + 1)"
        }
        return "Speaker \(index + 1)"
    }

    // MARK: - Helpers

    private static func formattedDuration(_ seconds: Double) -> String {
        let total = Int(seconds.rounded())
        let m = total / 60
        let s = total % 60
        return String(format: "%d:%02d", m, s)
    }
}
