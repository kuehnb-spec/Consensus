import Foundation
import MLXLLM
import MLXLMCommon

/// Service that uses a local LLM to reconcile multiple transcription engines' output
/// into a single best transcript. Runs entirely on-device via MLX on Apple Silicon,
/// using the same Qwen model family as `TranscriptCleanupService`.
///
/// Architecture rationale: experimental benchmarking on April 21, 2026 proved that
/// word-level timestamp alignment (the legacy `ConfidenceMergeService` approach)
/// produces 2-3× worse cpWER than simply passing Engine A through unchanged. LLM
/// reconciliation at the content level — reading both engines' complete transcripts
/// and using world knowledge + context to resolve disagreements — achieved 11.53%
/// cpWER vs the word-aligner's best of 12.89% and the broken merge's 37.59%. This
/// service is the production implementation of that breakthrough.
///
/// Scope note: this first implementation handles the 2-engine case in a single
/// LLM pass. Chunking for long recordings (>10 minutes) and the 3+-engine path
/// are flagged with TODOs for a follow-up session once the 2-engine flow is
/// validated end-to-end in the Swift pipeline.
actor LLMReconcileService {
    private var loadedModelID: String?
    private var modelContainer: ModelContainer?

    /// Single reconciled segment returned by the LLM, matched to our transcription
    /// model. Ordered by `start` time. Word-level timings are not produced by the
    /// LLM — consumers that need them should run forced alignment on the output.
    struct ReconciledSegment: Sendable {
        let speakerID: String  // same ID space as the reference pass
        let start: TimeInterval
        let end: TimeInterval
        let text: String
        let isUncertain: Bool  // LLM flagged this segment as genuinely ambiguous
    }

    struct ReconcileOptions: Sendable {
        /// Optional domain hint ("legal", "meeting", "interview", "general conversation").
        /// Prepended to the prompt to help the LLM resolve domain-specific terms.
        var domainHint: String? = nil
        /// Pre-known speaker display names ("Brant Kuehn", "Marie Larsen"). When
        /// provided, helps the LLM pick correct proper noun spellings in intros
        /// ("Hello, this is Brant Kuehn" instead of "Brankine").
        var knownSpeakerNames: [String] = []
        /// Maximum tokens to generate. Default scales with input length but caps at
        /// a reasonable ceiling to prevent runaway generation.
        var maxTokens: Int = 12_000
    }

    /// Load the LLM model. Mirrors `TranscriptCleanupService.loadModel` — both
    /// services should ideally share a single loaded container to avoid loading the
    /// 4-8 GB Qwen model twice. TODO: refactor to share the container at the
    /// ViewModel level.
    func loadModel(
        _ model: CleanupModel,
        progressCallback: @escaping @Sendable (Double) -> Void
    ) async throws {
        if loadedModelID == model.modelID, modelContainer != nil {
            return
        }
        modelContainer = nil
        loadedModelID = nil
        do {
            let container = try await loadModelContainer(
                id: model.modelID,
                progressHandler: { progress in
                    progressCallback(progress.fractionCompleted)
                }
            )
            modelContainer = container
            loadedModelID = model.modelID
        } catch {
            modelContainer = nil
            loadedModelID = nil
            throw error
        }
    }

    /// Reconcile engine outputs into a single transcript.
    ///
    /// - Parameter referencePass: Engine A output, treated as the source of speaker
    ///     labels and rough turn structure. The LLM is instructed to respect its
    ///     speaker attribution decisions.
    /// - Parameter candidatePass: Engine B output (typically no/weak speakers but
    ///     often finer turn boundaries and different word-level errors than A).
    /// - Parameter additionalPasses: Further engine outputs for 3+-engine
    ///     reconciliation. Empty in the default Deep Review flow.
    /// - Parameter speakerMapping: Maps `SPEAKER_N` IDs to display names. Used to
    ///     render the prompt with human-readable speaker labels and to interpret
    ///     the LLM's output.
    /// - Parameter options: Domain hint, known speaker names, token budget.
    /// - Parameter tokenCallback: Receives streaming LLM output for UI feedback.
    /// - Returns: Reconciled segments in time order.
    func reconcile(
        referencePass: TranscriptionPass,
        candidatePass: TranscriptionPass,
        additionalPasses: [TranscriptionPass] = [],
        speakerMapping: SpeakerMapping,
        options: ReconcileOptions = ReconcileOptions(),
        tokenCallback: (@Sendable (String) -> Void)? = nil
    ) async throws -> [ReconciledSegment] {
        guard let container = modelContainer else {
            throw ConsensusError.transcriptionFailed("No reconcile model loaded.")
        }

        let prompt = Self.buildPrompt(
            referencePass: referencePass,
            candidatePass: candidatePass,
            additionalPasses: additionalPasses,
            speakerMapping: speakerMapping,
            options: options
        )

        let isQwen = loadedModelID?.lowercased().contains("qwen") ?? false
        let effectivePrompt = isQwen ? "/no_think\n\(prompt.user)" : prompt.user

        let session = ChatSession(
            container,
            instructions: prompt.system,
            generateParameters: GenerateParameters(
                maxTokens: options.maxTokens,
                temperature: 0.1,
                topP: 0.9
            )
        )

        let response: String
        if let tokenCallback {
            var full = ""
            for try await chunk in session.streamResponse(to: effectivePrompt) {
                full += chunk
                tokenCallback(chunk)
            }
            response = full
        } else {
            response = try await session.respond(to: effectivePrompt)
        }

        return try Self.parseResponse(response, speakerMapping: speakerMapping)
    }

    /// Convert a list of reconciled segments into a full `TranscriptionResult` suitable
    /// for storing as a pass. Word-level timings are not populated — run forced
    /// alignment afterward if the export pipeline needs them.
    static func buildResult(
        from segments: [ReconciledSegment],
        audioPath: String,
        audioDuration: TimeInterval
    ) -> TranscriptionResult {
        let tsSegments = segments.map { seg in
            TranscriptionSegment(
                speakerID: seg.speakerID,
                start: seg.start,
                end: seg.end,
                text: seg.text,
                words: nil
            )
        }
        return TranscriptionResult(
            audioPath: audioPath,
            duration: audioDuration,
            segments: tsSegments
        )
    }

    func unload() {
        modelContainer = nil
        loadedModelID = nil
    }

    // MARK: - Prompt building

    private struct Prompt {
        let system: String
        let user: String
    }

    private static func buildPrompt(
        referencePass: TranscriptionPass,
        candidatePass: TranscriptionPass,
        additionalPasses: [TranscriptionPass],
        speakerMapping: SpeakerMapping,
        options: ReconcileOptions
    ) -> Prompt {
        var domain = options.domainHint ?? "general conversation"
        if !options.knownSpeakerNames.isEmpty {
            domain += ". Known speaker names: \(options.knownSpeakerNames.joined(separator: ", "))"
        }

        let system = """
        You are a precise transcription editor. You will receive two or more \
        independent transcripts of the same audio from different speech recognition \
        engines. Your task is to produce the single most accurate transcript by \
        reasoning about content.

        Rules:
          1. Both engines have errors. Use their agreement where possible; when they \
        disagree, pick the option that makes sense in context.
          2. PRESERVE the speaker labels and turn structure from Engine A — its \
        diarization has been validated. You may split a long Engine A turn into \
        multiple turns where another engine shows the conversation clearly \
        alternates inside it, but keep Engine A's speaker IDs.
          3. Apply domain knowledge: recognize terminology. Do NOT invent words that \
        no engine produced.
          4. If a segment is genuinely ambiguous after reasoning, set isUncertain \
        to true on that segment. Still provide your best-guess text.
          5. Output STRICTLY valid JSON — an array of objects with keys \
        "speaker", "start", "end", "text", and "isUncertain" (boolean). No commentary \
        before or after the JSON. No markdown code fences.

        Context: this is a \(domain).
        """

        var lines: [String] = []
        lines.append("ENGINE A (reference — speaker labels are authoritative):")
        lines.append("")
        lines.append(formatPass(referencePass, includeSpeakers: true, speakerMapping: speakerMapping))
        lines.append("")
        lines.append("--- END ENGINE A ---")
        lines.append("")
        lines.append("ENGINE B:")
        lines.append("")
        lines.append(formatPass(candidatePass, includeSpeakers: false, speakerMapping: speakerMapping))
        lines.append("")
        lines.append("--- END ENGINE B ---")
        lines.append("")
        for (i, pass) in additionalPasses.enumerated() {
            lines.append("ENGINE \(Character(UnicodeScalar(67 + i)!)):")
            lines.append("")
            lines.append(formatPass(pass, includeSpeakers: false, speakerMapping: speakerMapping))
            lines.append("")
            lines.append("--- END ENGINE \(Character(UnicodeScalar(67 + i)!)) ---")
            lines.append("")
        }
        lines.append("Produce the reconciled transcript now as a JSON array. The speaker field should match Engine A's speaker IDs exactly (e.g., \"SPEAKER_0\", \"SPEAKER_1\").")

        return Prompt(system: system, user: lines.joined(separator: "\n"))
    }

    private static func formatPass(
        _ pass: TranscriptionPass,
        includeSpeakers: Bool,
        speakerMapping: SpeakerMapping
    ) -> String {
        var out: [String] = []
        for segment in pass.result.segments {
            let text = segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            if includeSpeakers {
                let label = speakerMapping.displayName(for: segment.speakerID)
                out.append("[\(label) (\(segment.speakerID)) @ \(String(format: "%.1f", segment.start))s-\(String(format: "%.1f", segment.end))s]")
            } else {
                out.append("[\(String(format: "%.1f", segment.start))s]")
            }
            out.append(text)
        }
        return out.joined(separator: "\n")
    }

    // MARK: - Response parsing

    private static func parseResponse(
        _ response: String,
        speakerMapping: SpeakerMapping
    ) throws -> [ReconciledSegment] {
        // Strip leading/trailing whitespace + optional markdown fences
        var trimmed = response.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("```") {
            if let first = trimmed.range(of: "\n") {
                trimmed = String(trimmed[first.upperBound...])
            }
        }
        if trimmed.hasSuffix("```") {
            trimmed = String(trimmed.dropLast(3))
        }
        trimmed = trimmed.trimmingCharacters(in: .whitespacesAndNewlines)

        guard let data = trimmed.data(using: .utf8) else {
            throw ConsensusError.transcriptionFailed("LLM reconcile output not UTF-8 decodable.")
        }

        // Expect an array of objects.
        guard let raw = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            throw ConsensusError.transcriptionFailed("LLM reconcile output did not parse as JSON array.")
        }

        // Build a lookup from display name to speakerID so the LLM can return either.
        var displayToID: [String: String] = [:]
        for (id, name) in speakerMapping.names {
            displayToID[name.uppercased()] = id
        }

        return raw.compactMap { obj in
            let speakerValue = (obj["speaker"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !speakerValue.isEmpty else { return nil }
            let speakerID = displayToID[speakerValue.uppercased()] ?? speakerValue
            let start = (obj["start"] as? Double) ?? 0
            let end = (obj["end"] as? Double) ?? start
            let text = (obj["text"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !text.isEmpty else { return nil }
            let uncertain = (obj["isUncertain"] as? Bool) ?? false
            return ReconciledSegment(
                speakerID: speakerID,
                start: start,
                end: max(start + 0.1, end),
                text: text,
                isUncertain: uncertain
            )
        }
    }

    // MARK: - Judgment-only mode (dispute windows)

    /// A localized window of disagreement between two engines for the same audio
    /// span. Produced by `findDisputes` and fed to `judgeDisputes`. Kept small
    /// (one Engine A segment worth of text) so the LLM can reason about it in
    /// isolation instead of holding the full transcript in attention.
    struct DisputeWindow: Sendable, Identifiable {
        let id: Int  // stable index used to match the LLM's JSON response
        let segmentIndex: Int  // index into the reference pass's segments
        let timeStart: TimeInterval
        let timeEnd: TimeInterval
        let speakerID: String
        let engineAText: String
        let engineBText: String
    }

    /// The LLM's verdict for a single dispute window.
    enum DisputeChoice: Sendable, Equatable {
        /// Engine A's version is correct — no change needed.
        case preferA
        /// Engine B's version is correct — substitute B's text into the merged
        /// transcript.
        case preferB
        /// Neither engine got it right; use the LLM's suggested text.
        case suggest(String)
        /// The disagreement is meaningful but the LLM can't tell which is right
        /// without hearing the audio. The window is surfaced as an unresolved
        /// flag so the user can review (or trigger a targeted re-transcription).
        case uncertain(reason: String)
    }

    struct DisputeResolution: Sendable, Identifiable {
        var id: Int { window.id }
        let window: DisputeWindow
        let choice: DisputeChoice
    }

    /// Default filler tokens stripped during dispute detection. Only removed for
    /// the "is this a substantive disagreement?" check — the original text is
    /// preserved when building the merged transcript.
    private static let fillerTokens: Set<String> = [
        "um", "uh", "uhh", "ah", "ahh", "mm", "mmm", "hmm", "hmmm",
        "er", "erm", "oh",
    ]

    /// Find windows where Engine A and Engine B substantively disagree. A
    /// "window" is one Engine A segment (a speaker turn) paired with whatever
    /// Engine B text overlaps the same time range. The comparison normalizes
    /// case, punctuation, and filler words before deciding whether to surface
    /// a window — so "um yes, I did" vs "Yes I did." is NOT a dispute, but
    /// "yes I did" vs "no I didn't" IS.
    static func findDisputes(
        referencePass: TranscriptionPass,
        candidatePass: TranscriptionPass
    ) -> [DisputeWindow] {
        let refSegments = referencePass.result.segments
        let candSegments = candidatePass.result.segments
        guard !refSegments.isEmpty, !candSegments.isEmpty else { return [] }

        var disputes: [DisputeWindow] = []
        var nextID = 0

        for (segIndex, refSeg) in refSegments.enumerated() {
            let refText = refSeg.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !refText.isEmpty else { continue }

            // Gather all candidate segments that overlap the reference window
            // by at least 30% of the reference duration (loose — we want any
            // meaningful overlap, not a perfect match).
            let refDuration = max(0.1, refSeg.end - refSeg.start)
            let overlapping = candSegments.filter { cand in
                let overlapStart = max(cand.start, refSeg.start)
                let overlapEnd = min(cand.end, refSeg.end)
                let overlap = overlapEnd - overlapStart
                return overlap / refDuration >= 0.3
            }
            guard !overlapping.isEmpty else {
                // Engine B has nothing here — that's itself a dispute (missing
                // phrase vs extra phrase). Surface it only if Engine A's text
                // is longer than a few words (otherwise noise).
                if refText.split(whereSeparator: \.isWhitespace).count >= 4 {
                    disputes.append(DisputeWindow(
                        id: nextID,
                        segmentIndex: segIndex,
                        timeStart: refSeg.start,
                        timeEnd: refSeg.end,
                        speakerID: refSeg.speakerID,
                        engineAText: refText,
                        engineBText: ""
                    ))
                    nextID += 1
                }
                continue
            }

            let candText = overlapping
                .map { $0.text.trimmingCharacters(in: .whitespacesAndNewlines) }
                .joined(separator: " ")

            if normalizeForDisputeCheck(refText) == normalizeForDisputeCheck(candText) {
                continue  // trivial diff — skip
            }

            disputes.append(DisputeWindow(
                id: nextID,
                segmentIndex: segIndex,
                timeStart: refSeg.start,
                timeEnd: refSeg.end,
                speakerID: refSeg.speakerID,
                engineAText: refText,
                engineBText: candText
            ))
            nextID += 1
        }

        return disputes
    }

    /// Normalize for the "is this diff substantive?" check: lowercase, strip
    /// punctuation, drop filler tokens, collapse whitespace. Does NOT modify
    /// the text that ends up in the transcript.
    private static func normalizeForDisputeCheck(_ text: String) -> String {
        let lower = text.lowercased()
        let stripped = lower.unicodeScalars.map { scalar -> Character in
            if CharacterSet.punctuationCharacters.contains(scalar) { return " " }
            if CharacterSet.symbols.contains(scalar) { return " " }
            return Character(scalar)
        }
        let collapsed = String(stripped)
        let tokens = collapsed.split(whereSeparator: \.isWhitespace).map(String.init)
        let kept = tokens.filter { !fillerTokens.contains($0) }
        return kept.joined(separator: " ")
    }

    /// Ask the LLM to judge each dispute window. Batches windows so no single
    /// prompt overruns the context — the LLM sees a short list of localized
    /// disagreements instead of two full transcripts, which both saves tokens
    /// and keeps its attention focused on the parts that actually matter.
    func judgeDisputes(
        _ windows: [DisputeWindow],
        options: ReconcileOptions = ReconcileOptions(),
        tokenCallback: (@Sendable (String) -> Void)? = nil
    ) async throws -> [DisputeResolution] {
        guard let container = modelContainer else {
            throw ConsensusError.transcriptionFailed("No reconcile model loaded.")
        }
        guard !windows.isEmpty else { return [] }

        let batchSize = 25  // keeps prompts under ~2K tokens
        var resolutions: [DisputeResolution] = []
        resolutions.reserveCapacity(windows.count)

        for batchStart in stride(from: 0, to: windows.count, by: batchSize) {
            let batch = Array(windows[batchStart ..< min(batchStart + batchSize, windows.count)])
            let prompt = Self.buildJudgmentPrompt(windows: batch, options: options)
            let isQwen = loadedModelID?.lowercased().contains("qwen") ?? false
            let effectivePrompt = isQwen ? "/no_think\n\(prompt.user)" : prompt.user

            let session = ChatSession(
                container,
                instructions: prompt.system,
                generateParameters: GenerateParameters(
                    maxTokens: options.maxTokens,
                    temperature: 0.1,
                    topP: 0.9
                )
            )

            let response: String
            if let tokenCallback {
                var full = ""
                for try await chunk in session.streamResponse(to: effectivePrompt) {
                    full += chunk
                    tokenCallback(chunk)
                }
                response = full
            } else {
                response = try await session.respond(to: effectivePrompt)
            }

            let batchResolutions = Self.parseJudgmentResponse(response, windows: batch)
            resolutions.append(contentsOf: batchResolutions)
        }

        return resolutions
    }

    private static func buildJudgmentPrompt(
        windows: [DisputeWindow],
        options: ReconcileOptions
    ) -> Prompt {
        var domain = options.domainHint ?? "general conversation"
        if !options.knownSpeakerNames.isEmpty {
            domain += ". Known speaker names: \(options.knownSpeakerNames.joined(separator: ", "))"
        }

        let system = """
        You are a transcription judge. For each numbered window, two speech \
        recognition engines produced different text for the same audio. Your \
        job is to decide which version is correct. Use context and world \
        knowledge — do not invent words that neither engine produced unless \
        both are clearly garbled and the correct phrase is obvious from context.

        For every window, return one of these choices:
          "A" — Engine A's text is correct.
          "B" — Engine B's text is correct.
          "SUGGEST" — neither is right; provide the corrected text in "text".
          "UNCERTAIN" — the disagreement is meaningful but you genuinely cannot \
            tell which is right. Provide a one-sentence "reason".

        Output STRICTLY valid JSON: an array of objects, one per window, keyed \
        by "window" (integer), "choice" (string), and optionally "text" (for \
        SUGGEST) or "reason" (for UNCERTAIN). No markdown, no commentary.

        Context: this is a \(domain).
        """

        var lines: [String] = []
        lines.append("WINDOWS:")
        lines.append("")
        for w in windows {
            lines.append("[\(w.id)] \(String(format: "%.1f", w.timeStart))s-\(String(format: "%.1f", w.timeEnd))s speaker=\(w.speakerID)")
            lines.append("  Engine A: \(w.engineAText)")
            if w.engineBText.isEmpty {
                lines.append("  Engine B: (silence / nothing transcribed)")
            } else {
                lines.append("  Engine B: \(w.engineBText)")
            }
            lines.append("")
        }
        lines.append("Return the JSON array now. Every window id from the list above must appear exactly once in your response.")

        return Prompt(system: system, user: lines.joined(separator: "\n"))
    }

    private static func parseJudgmentResponse(
        _ response: String,
        windows: [DisputeWindow]
    ) -> [DisputeResolution] {
        var trimmed = response.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("```") {
            if let first = trimmed.range(of: "\n") {
                trimmed = String(trimmed[first.upperBound...])
            }
        }
        if trimmed.hasSuffix("```") {
            trimmed = String(trimmed.dropLast(3))
        }
        trimmed = trimmed.trimmingCharacters(in: .whitespacesAndNewlines)

        let windowByID = Dictionary(uniqueKeysWithValues: windows.map { ($0.id, $0) })

        guard let data = trimmed.data(using: .utf8),
              let raw = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]
        else {
            // Parser failed — conservatively mark every window as preferA so the
            // user still sees Engine A text and nothing is silently corrupted.
            return windows.map {
                DisputeResolution(window: $0, choice: .preferA)
            }
        }

        var resolutions: [DisputeResolution] = []
        var seenIDs: Set<Int> = []
        for obj in raw {
            guard let id = obj["window"] as? Int,
                  let window = windowByID[id]
            else { continue }
            if seenIDs.contains(id) { continue }
            seenIDs.insert(id)

            let rawChoice = (obj["choice"] as? String)?.uppercased().trimmingCharacters(in: .whitespacesAndNewlines) ?? "A"
            let choice: DisputeChoice
            switch rawChoice {
            case "A": choice = .preferA
            case "B": choice = .preferB
            case "SUGGEST":
                let text = (obj["text"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                choice = text.isEmpty ? .preferA : .suggest(text)
            case "UNCERTAIN":
                let reason = (obj["reason"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "LLM flagged as ambiguous"
                choice = .uncertain(reason: reason)
            default:
                choice = .preferA
            }
            resolutions.append(DisputeResolution(window: window, choice: choice))
        }

        // Any window the LLM skipped is conservatively left as Engine A.
        for window in windows where !seenIDs.contains(window.id) {
            resolutions.append(DisputeResolution(window: window, choice: .preferA))
        }

        return resolutions.sorted { $0.window.id < $1.window.id }
    }
}
