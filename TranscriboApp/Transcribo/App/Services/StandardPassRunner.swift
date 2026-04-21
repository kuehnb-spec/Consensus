import Foundation

/// Runs the standard (single-engine) transcription pass for the rewritten
/// UI. Wraps the existing `FluidAsrTranscriptionService` (Parakeet) and
/// `SpeakerKitDiarizationService`, merges their outputs via
/// `SegmentMerger`, and emits aggregated progress as one 0–1 fraction so
/// the progress bar in `DeepReadRootView` doesn't have to know about the
/// individual stages.
///
/// Phase 1b implements the Standard-tier path (Engine A only). Phase 1c
/// will layer Engine B + `LLMReconcileService` on top for the Deep tier,
/// reusing this runner's output as the reference pass.
final class StandardPassRunner {
    private let asr = FluidAsrTranscriptionService()
    private let diarizer = SpeakerKitDiarizationService()

    struct Progress: Sendable {
        /// Aggregated fraction across all stages. `0` → `1`.
        let fraction: Double
        /// Short user-facing label ("Loading Parakeet…", "Transcribing 3:12 of 8:00", …).
        let label: String
    }

    struct Options: Sendable {
        var variant: FluidAsrModelVariant = .parakeetV3
        var language: String = "en"
        var requestedSpeakerCount: Int? = nil
        var audioDurationSeconds: Double = 0

        init(
            variant: FluidAsrModelVariant = .parakeetV3,
            language: String = "en",
            requestedSpeakerCount: Int? = nil,
            audioDurationSeconds: Double = 0
        ) {
            self.variant = variant
            self.language = language
            self.requestedSpeakerCount = requestedSpeakerCount
            self.audioDurationSeconds = audioDurationSeconds
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
