import Foundation

/// Runs the Deep-tier pipeline on top of a completed Standard pass:
/// Engine B (WhisperKit) + local LLM reconciliation via `LLMReconcileService`.
/// Produces the `.deep` `TranscriptPass` that becomes the project's active
/// transcript (cpWER ~11–12% on the April 21 benchmark vs ~17% for the
/// Standard-tier output alone).
///
/// The caller hands in the Standard pass from `StandardPassRunner` plus
/// the user-confirmed speaker roster. This runner does not re-diarize —
/// Engine A's speaker decisions are authoritative; Engine B contributes
/// only finer turn boundaries and a second opinion on word-level content.
///
/// Phase 1c.2 ships the single-engine-B, single-shot path. Later phases
/// will add chunking for >12-minute audio (current LLM context ceiling),
/// Engine C support, and the question-loop second pass for resolving
/// user-answered uncertainties.
final class DeepPassRunner {
    private let whisper = TranscriptionService()
    private let llm = LLMReconcileService()

    struct Options: Sendable {
        var whisperModel: WhisperModel = .largeV3
        var llmModel: CleanupModel = CleanupModel.recommended()
        var domainHint: DomainHint = .general
        var language: String = "en"
        var audioDurationSeconds: Double = 0
    }

    struct Progress: Sendable {
        let fraction: Double
        let label: String
    }

    /// Stage weights sum to 1.0. Whisper dominates the wall-clock budget
    /// on first run because the large-v3 weights are ~3 GB to download.
    private enum Weights {
        static let whisperLoad: Double = 0.15
        static let whisperRun: Double = 0.35
        static let llmLoad: Double = 0.15
        static let llmReconcile: Double = 0.35
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

        // --- Stage 1: load WhisperKit (Engine B) -----------------------
        let whisperLoadStart = Date()
        progress(Progress(fraction: 0, label: "Loading Whisper (\(options.whisperModel.displayName))…"))
        try await whisper.loadModel(
            variant: options.whisperModel.rawValue,
            progressCallback: { fraction in
                let firstRunHint = fraction < 1.0
                    ? "Downloading Whisper \(options.whisperModel.displayName) (\(options.whisperModel.approximateSize))…"
                    : "Loading Whisper \(options.whisperModel.displayName)…"
                progress(Progress(
                    fraction: fraction * Weights.whisperLoad,
                    label: firstRunHint
                ))
            }
        )
        stageTimings["whisperLoad"] = Date().timeIntervalSince(whisperLoadStart)

        // --- Stage 2: transcribe with Whisper (Engine B) ---------------
        let whisperRunStart = Date()
        let audioPath = audioURL.path
        let engineBSegments = try await whisper.transcribe(
            audioPath: audioPath,
            language: options.language,
            audioDuration: options.audioDurationSeconds,
            progressCallback: { fraction, _ in
                let elapsedAudio = fraction * options.audioDurationSeconds
                let durationLabel = options.audioDurationSeconds > 0
                    ? " of \(Self.formattedDuration(options.audioDurationSeconds))"
                    : ""
                let prefix = options.audioDurationSeconds > 0
                    ? "Engine B transcribing \(Self.formattedDuration(elapsedAudio))\(durationLabel)"
                    : "Engine B transcribing…"
                progress(Progress(
                    fraction: Weights.whisperLoad + fraction * Weights.whisperRun,
                    label: prefix
                ))
                return true
            }
        )
        stageTimings["whisperRun"] = Date().timeIntervalSince(whisperRunStart)

        // --- Stage 3: load LLM -----------------------------------------
        let llmLoadStart = Date()
        progress(Progress(
            fraction: Weights.whisperLoad + Weights.whisperRun,
            label: "Loading reconciliation LLM (\(options.llmModel.displayName))…"
        ))
        try await llm.loadModel(options.llmModel) { fraction in
            let firstRunHint = fraction < 1.0
                ? "Downloading \(options.llmModel.displayName) (\(options.llmModel.approximateSize))…"
                : "Loading \(options.llmModel.displayName)…"
            progress(Progress(
                fraction: Weights.whisperLoad + Weights.whisperRun + fraction * Weights.llmLoad,
                label: firstRunHint
            ))
        }
        stageTimings["llmLoad"] = Date().timeIntervalSince(llmLoadStart)

        // --- Stage 4: reconcile ----------------------------------------
        let reconcileStart = Date()
        progress(Progress(
            fraction: Weights.whisperLoad + Weights.whisperRun + Weights.llmLoad,
            label: "Reconciling transcripts…"
        ))

        let referencePass = Self.legacyPass(
            kind: .standard,
            engine: standardPass.engineAttribution.primaryEngine,
            diarizer: standardPass.engineAttribution.diarizer ?? "unknown",
            language: options.language,
            audioPath: audioPath,
            durationSeconds: options.audioDurationSeconds,
            segments: standardPass.segments
        )

        let candidatePass = Self.legacyPass(
            kind: .deepReviewComparison,
            engine: "WhisperKit",
            diarizer: "none",
            language: options.language,
            audioPath: audioPath,
            durationSeconds: options.audioDurationSeconds,
            segments: engineBSegments
        )

        let mapping = SpeakerMapping(
            names: Dictionary(uniqueKeysWithValues: speakers.map { ($0.id, $0.displayName) })
        )

        let knownNames = speakers
            .filter(\.isConfirmed)
            .map(\.displayName)
            .filter { !$0.isEmpty }

        let reconcileOptions = LLMReconcileService.ReconcileOptions(
            domainHint: Self.domainHintToken(options.domainHint),
            knownSpeakerNames: knownNames,
            maxTokens: 12_000
        )

        // The LLM streams tokens; translate a token counter into a rough
        // fraction within the reconcile weight so the bar keeps moving.
        let tokenCounter = TokenCounter()
        let reconciled = try await llm.reconcile(
            referencePass: referencePass,
            candidatePass: candidatePass,
            additionalPasses: [],
            speakerMapping: mapping,
            options: reconcileOptions,
            tokenCallback: { _ in
                let tokens = tokenCounter.increment()
                let approxFraction = min(1.0, Double(tokens) / Double(reconcileOptions.maxTokens))
                progress(Progress(
                    fraction: Weights.whisperLoad + Weights.whisperRun + Weights.llmLoad + approxFraction * Weights.llmReconcile,
                    label: "Reconciling transcripts… (\(tokens) tokens)"
                ))
            }
        )
        stageTimings["llmReconcile"] = Date().timeIntervalSince(reconcileStart)

        progress(Progress(fraction: 1.0, label: "Done"))
        stageTimings["deepTotal"] = Date().timeIntervalSince(runStart)

        // --- Build the deep pass ---------------------------------------
        let mergedSegments = reconciled.map { seg in
            TranscriptionSegment(
                speakerID: seg.speakerID,
                start: seg.start,
                end: seg.end,
                text: seg.text,
                words: nil
            )
        }
        let uncertainIndices = Set(
            reconciled.enumerated().compactMap { $0.element.isUncertain ? $0.offset : nil }
        )

        // Pair reconciled (clean) text with Engine A-derived verbatim text.
        // Engine A's output carries the acoustic ground truth — including
        // disfluencies, false starts, fillers — that the LLM tends to
        // smooth away. Aligning by time overlap lets the user toggle
        // between "grammatically-smoothed" and "faithful-to-audio" views
        // without a second LLM pass.
        let styles = Self.buildStylePair(
            reconciled: mergedSegments,
            engineA: standardPass.segments
        )

        // For each LLM-flagged uncertain turn, capture the Engine A and
        // Engine B text as click-to-apply alternatives in the review
        // popover. Sourced now (not at click time) so the UI doesn't have
        // to hold onto Engine B's full output indefinitely.
        let engineAName = standardPass.engineAttribution.primaryEngine.isEmpty
            ? "Engine A"
            : "\(standardPass.engineAttribution.primaryEngine) (Engine A)"
        let engineBName = "\(options.whisperModel.displayName) (Engine B)"
        let alternatives = Self.buildAlternatives(
            uncertainIndices: uncertainIndices,
            reconciled: mergedSegments,
            engineA: standardPass.segments,
            engineB: engineBSegments,
            engineALabel: engineAName,
            engineBLabel: engineBName
        )

        return TranscriptPass(
            kind: .deep,
            segments: mergedSegments,
            uncertainSegmentIndices: uncertainIndices,
            alternativesByIndex: alternatives,
            engineAttribution: EngineAttribution(
                primaryEngine: standardPass.engineAttribution.primaryEngine,
                supportingEngines: [options.whisperModel.displayName] + standardPass.engineAttribution.supportingEngines,
                diarizer: standardPass.engineAttribution.diarizer,
                language: options.language
            ),
            styles: styles,
            quality: QualitySummary(
                diarizationConfidence: standardPass.quality.diarizationConfidence,
                uncertainSegmentCount: uncertainIndices.count,
                stageTimings: stageTimings
            )
        )
    }

    /// For each uncertain segment index, build the list of alternatives
    /// (Engine A overlap + Engine B overlap). Skips sources that overlap
    /// zero text, skips duplicates of the current reconciled text.
    private static func buildAlternatives(
        uncertainIndices: Set<Int>,
        reconciled: [TranscriptionSegment],
        engineA: [TranscriptionSegment],
        engineB: [TranscriptionSegment],
        engineALabel: String,
        engineBLabel: String
    ) -> [Int: [TurnAlternative]] {
        var out: [Int: [TurnAlternative]] = [:]
        for idx in uncertainIndices.sorted() {
            guard idx >= 0, idx < reconciled.count else { continue }
            let seg = reconciled[idx]
            let aText = overlappingText(engine: engineA, around: seg)
            let bText = overlappingText(engine: engineB, around: seg)
            var list: [TurnAlternative] = []
            if !aText.isEmpty && aText != seg.text {
                list.append(TurnAlternative(source: engineALabel, text: aText))
            }
            if !bText.isEmpty && bText != seg.text && bText != aText {
                list.append(TurnAlternative(source: engineBLabel, text: bText))
            }
            if !list.isEmpty {
                out[idx] = list
            }
        }
        return out
    }

    private static func overlappingText(
        engine: [TranscriptionSegment],
        around seg: TranscriptionSegment
    ) -> String {
        engine
            .filter { $0.end > seg.start && $0.start < seg.end }
            .map { $0.text.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    /// For each reconciled (clean) segment, concatenates Engine A segments
    /// whose time range overlaps to produce the verbatim counterpart.
    /// Falls back to the clean text when no Engine A overlap is found
    /// (rare, typically only happens with very short segments at the edges).
    private static func buildStylePair(
        reconciled: [TranscriptionSegment],
        engineA: [TranscriptionSegment]
    ) -> StylePair {
        var verbatim: [String] = []
        var clean: [String] = []
        for seg in reconciled {
            let overlapping = engineA.filter { a in
                a.end > seg.start && a.start < seg.end
            }
            let joined = overlapping
                .map { $0.text.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
                .joined(separator: " ")
            verbatim.append(joined.isEmpty ? seg.text : joined)
            clean.append(seg.text)
        }
        return StylePair(verbatimText: verbatim, cleanText: clean)
    }

    // MARK: - Adapters

    /// Build a legacy `TranscriptionPass` struct around `segments` so
    /// the LLM reconcile service (which pre-dates the new pass model) can
    /// consume it without modification.
    private static func legacyPass(
        kind: TranscriptionPassKind,
        engine: String,
        diarizer: String,
        language: String,
        audioPath: String,
        durationSeconds: Double,
        segments: [TranscriptionSegment]
    ) -> TranscriptionPass {
        TranscriptionPass(
            kind: kind,
            engineName: engine,
            modelName: engine,
            diarizationEngineName: diarizer,
            language: language,
            minSpeakers: nil,
            maxSpeakers: nil,
            sourcePassID: nil,
            warnings: [],
            result: TranscriptionResult(
                audioPath: audioPath,
                duration: durationSeconds,
                segments: segments
            ),
            qualitySummary: TranscriptQualitySummary(
                averageWordConfidence: nil,
                averageSegmentConfidence: nil,
                averageDiarizationQuality: nil,
                averageLogProb: nil,
                averageCompressionRatio: nil,
                averageNoSpeechProbability: nil,
                lowConfidenceWordCount: 0,
                lowConfidenceSegmentCount: 0,
                lowDiarizationSegmentCount: 0,
                unknownSpeakerSegmentCount: 0,
                riskySegments: []
            )
        )
    }

    private static func domainHintToken(_ hint: DomainHint) -> String? {
        switch hint {
        case .general: return nil          // LLMReconcileService defaults to "general conversation"
        case .legal:   return "legal"
        case .medical: return "medical"
        case .technical: return "technical"
        case .business:  return "business"
        case .custom(let text):
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
    }

    // MARK: - Helpers

    private static func formattedDuration(_ seconds: Double) -> String {
        let total = Int(seconds.rounded())
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    /// Simple thread-safe counter for token-callback progress hints.
    private final class TokenCounter: @unchecked Sendable {
        private let lock = NSLock()
        private var value: Int = 0
        func increment() -> Int {
            lock.lock()
            defer { lock.unlock() }
            value += 1
            return value
        }
    }
}
