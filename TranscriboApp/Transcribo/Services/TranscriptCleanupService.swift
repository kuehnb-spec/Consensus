import Foundation
import MLXLLM
import MLXLMCommon

/// Service that uses a local LLM to clean up and optionally summarize transcripts.
/// Runs entirely on-device via MLX on Apple Silicon.
actor TranscriptCleanupService {
    private var loadedModelID: String?
    private var modelContainer: ModelContainer?

    enum CleanupTask: Hashable, Sendable {
        case cleanup         // Fix obvious errors, normalize formatting
        case summarize       // Generate a concise summary
        case cleanupAndSummarize  // Both

        var systemPrompt: String {
            switch self {
            case .cleanup:
                return """
                You are a transcript editor. Your job is to clean up a raw speech-to-text \
                transcript. Fix obvious transcription errors (misheard words, repeated words, \
                missing punctuation). Preserve the original meaning exactly. Do not add, remove, \
                or rephrase content — only fix clear errors. Keep speaker labels exactly as they \
                appear. Return ONLY the cleaned transcript, no commentary.
                """
            case .summarize:
                return """
                You are a transcript summarizer. Given a transcript of a conversation, produce \
                a clear, structured summary. Begin with a section titled "ACTION ITEMS & DELIVERABLES" \
                that lists every commitment, task, or deliverable that any participant agreed to, \
                attributed to the specific speaker responsible. Format each as: \
                "- [SPEAKER NAME]: Description of deliverable/action item". \
                After the action items section, add a section titled "KEY POINTS" with the main \
                topics discussed, decisions made, and important information shared. \
                Attribute statements to speakers where relevant. Keep the overall summary to roughly \
                10-15% of the original length. Return ONLY the summary, no commentary.
                """
            case .cleanupAndSummarize:
                return """
                You are a transcript editor and summarizer. First, clean up obvious transcription \
                errors (misheard words, repeated words, missing punctuation) while preserving the \
                original meaning exactly. Keep speaker labels exactly as they appear. \
                Then, after the cleaned transcript, add a section titled "SUMMARY". \
                Begin the summary with "ACTION ITEMS & DELIVERABLES" — list every commitment, \
                task, or deliverable that any participant agreed to, attributed to the specific \
                speaker responsible. Format each as: \
                "- [SPEAKER NAME]: Description of deliverable/action item". \
                Follow with "KEY POINTS" covering the main topics discussed, decisions made, \
                and important information shared. Return the cleaned transcript followed by \
                the summary, no other commentary.
                """
            }
        }
    }

    /// Load the specified cleanup model. Downloads from HuggingFace on first use.
    func loadModel(
        _ model: CleanupModel,
        progressCallback: @escaping @Sendable (Double) -> Void
    ) async throws {
        if loadedModelID == model.modelID, modelContainer != nil {
            return  // Already loaded
        }

        // Unload previous model
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
            // Ensure clean state on failure so next attempt starts fresh
            modelContainer = nil
            loadedModelID = nil
            throw error
        }
    }

    /// Process transcript text with the loaded model.
    func process(
        transcript: String,
        task: CleanupTask
    ) async throws -> String {
        try await process(transcript: transcript, task: task, tokenCallback: nil)
    }

    /// Process transcript text with the loaded model, streaming tokens to a callback.
    func process(
        transcript: String,
        task: CleanupTask,
        tokenCallback: (@Sendable (String) -> Void)?
    ) async throws -> String {
        guard let container = modelContainer else {
            throw ConsensusError.transcriptionFailed("No cleanup model loaded.")
        }

        // Estimate reasonable max output: input length * 1.5 (cleanup) or input length * 0.3 (summary)
        // Cap at 8192 to prevent runaway generation (especially Qwen3 thinking mode)
        let inputTokenEstimate = transcript.count / 4  // rough token estimate
        let maxOutput: Int
        switch task {
        case .cleanup: maxOutput = min(8192, max(2048, inputTokenEstimate * 2))
        case .summarize: maxOutput = min(4096, max(1024, inputTokenEstimate / 2))
        case .cleanupAndSummarize: maxOutput = min(8192, max(2048, Int(Double(inputTokenEstimate) * 2.5)))
        }

        // Prepend /no_think for Qwen3 models to disable thinking mode (which generates
        // enormous <think> blocks that can exhaust memory)
        let isQwen = loadedModelID?.lowercased().contains("qwen") ?? false
        let effectivePrompt = isQwen ? "/no_think\n\(transcript)" : transcript

        let session = ChatSession(
            container,
            instructions: task.systemPrompt,
            generateParameters: GenerateParameters(
                maxTokens: maxOutput,
                temperature: 0.3,
                topP: 0.9
            )
        )

        // Use streaming API if we have a callback, otherwise use the simple respond
        if let tokenCallback {
            var fullResponse = ""
            let stream = session.streamResponse(to: effectivePrompt)
            for try await chunk in stream {
                fullResponse += chunk
                tokenCallback(chunk)
            }
            return fullResponse
        } else {
            let response = try await session.respond(to: effectivePrompt)
            return response
        }
    }

    /// Convenience: format a TranscriptionResult as text for LLM processing
    static func formatForCleanup(
        result: TranscriptionResult,
        speakerMapping: SpeakerMapping
    ) -> String {
        var lines: [String] = []
        var currentSpeaker: String?

        for segment in result.segments {
            let speaker = speakerMapping.displayName(for: segment.speakerID)
            let text = segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }

            if speaker != currentSpeaker {
                currentSpeaker = speaker
                lines.append("")
                lines.append("\(speaker.uppercased()):")
            }
            lines.append(text)
        }

        return lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Resolve diarization disagreements using LLM context analysis.
    /// Given transcription segments with multiple speaker assignment candidates,
    /// the LLM picks the most likely correct speaker for each disagreement.
    func resolveDiarizationDisagreements(
        transcriptionSegments: [TranscriptionSegment],
        multiResult: MultiDiarizationResult,
        speakerMapping: SpeakerMapping
    ) async throws -> [DiarizationSegment] {
        guard let container = modelContainer else {
            throw TranscriboError.transcriptionFailed("No cleanup model loaded for diarization resolution.")
        }

        // Build a context window around each disagreement for LLM analysis
        var disagreements: [(index: Int, segment: DiarizationSegment, candidates: [String: String])] = []

        for (i, resolvedSeg) in multiResult.resolved.enumerated() {
            // Check if passes disagree on this segment
            var speakersByPass: [String: String] = [:]
            for pass in multiResult.passes {
                if let match = findBestOverlap(target: resolvedSeg, candidates: pass.segments) {
                    speakersByPass[pass.presetName] = match.speakerID
                }
            }

            let uniqueSpeakers = Set(speakersByPass.values)
            if uniqueSpeakers.count > 1 {
                disagreements.append((index: i, segment: resolvedSeg, candidates: speakersByPass))
            }
        }

        // If no disagreements or too many to process efficiently, return majority-vote result
        guard !disagreements.isEmpty else {
            return multiResult.resolved
        }

        // Build prompt with transcript context around each disagreement
        let contextPrompt = buildDiarizationResolutionPrompt(
            disagreements: disagreements,
            transcriptionSegments: transcriptionSegments,
            speakerMapping: speakerMapping
        )

        let session = ChatSession(
            container,
            instructions: """
            You are a speaker diarization expert. Given a transcript with speaker attribution \
            disagreements between multiple analysis passes, determine the most likely correct \
            speaker for each disputed segment. The candidate speaker IDs have already been \
            aligned into a shared label space across passes. Consider conversational flow, \
            topic continuity, pronouns, and logical consistency. Respond with ONLY the \
            segment numbers and your chosen speaker ID, one per line, in the format: \
            SEGMENT_N: SPEAKER_ID
            """,
            generateParameters: GenerateParameters(maxTokens: 2048, temperature: 0.1, topP: 0.95)
        )

        let response = try await session.respond(to: contextPrompt)

        // Parse LLM response and apply corrections
        var resolved = multiResult.resolved
        let corrections = parseDiarizationCorrections(response: response, disagreements: disagreements)

        for (index, speakerID) in corrections {
            if index < resolved.count {
                resolved[index] = DiarizationSegment(
                    speakerID: speakerID,
                    start: resolved[index].start,
                    end: resolved[index].end,
                    qualityScore: resolved[index].qualityScore
                )
            }
        }

        return resolved
    }

    /// Resolve reconciliation discrepancies using LLM analysis.
    /// For each discrepancy row, the LLM picks the more likely correct version.
    /// Result of LLM pre-resolution: which source to use AND whether the difference is substantive.
    struct PreResolutionResult {
        let choices: [UUID: ReconciliationSourceChoice]
        let trivialRowIDs: Set<UUID>  // Rows where the difference is not substantive
    }

    func preResolveReconciliation(
        rows: [ReconciliationRow],
        speakerMapping: SpeakerMapping
    ) async throws -> PreResolutionResult {
        guard let container = modelContainer else {
            throw TranscriboError.transcriptionFailed("No cleanup model loaded for reconciliation.")
        }

        // Only process rows with actual differences
        let discrepancies = rows.filter { $0.differenceKind.hasDifference }
        guard !discrepancies.isEmpty else {
            return PreResolutionResult(choices: [:], trivialRowIDs: [])
        }

        // Build prompt that asks the LLM to both CLASSIFY and CHOOSE
        var promptLines: [String] = ["""
        You are comparing two transcriptions of the same audio recording. For each difference below, \
        you must decide two things:
        1. Is this difference SUBSTANTIVE (the meaning actually changes) or TRIVIAL (same meaning, \
           just different wording, filler words, punctuation, number formatting like "$14.8 million" \
           vs "14.8 million dollars", or minor phrasing)?
        2. If substantive, which version (A or B) is more likely what was actually said?

        Examples of TRIVIAL differences (do NOT flag these for review):
        - "It's a $14.8 million claim" vs "It's a 14.8 million dollar claim"
        - "you know, I think" vs "I think"
        - "Okay. So" vs "Okay, so"
        - "We'll keep advancing" vs "We'll keep advancing a bit"
        - Missing or extra filler words (um, uh, like, right, okay, you know, I mean)
        - Different punctuation or capitalization
        - Minor word order changes that don't change meaning

        Examples of SUBSTANTIVE differences (DO flag these):
        - SPEAKER ATTRIBUTION: If the two versions attribute the same words to DIFFERENT speakers, \
          this is ALWAYS substantive. It matters enormously who said what — especially in legal, \
          financial, or business contexts. Never mark speaker disagreements as trivial.
        - Different names, numbers, or dates
        - Different actions or commitments described
        - Missing entire sentences with new information
        - Different legal or financial terms

        Here are the discrepancies:

        """]

        for (i, row) in discrepancies.enumerated() {
            let refSpeaker = speakerMapping.displayName(for: row.referenceSpeakerID)
            let candSpeaker = speakerMapping.displayName(for: row.candidateSpeakerID)

            promptLines.append("--- ITEM \(i + 1) [\(TimeFormatting.timestamp(row.start))] ---")
            promptLines.append("A (\(refSpeaker)): \(row.referenceText)")
            promptLines.append("B (\(candSpeaker)): \(row.candidateText)")
            promptLines.append("")
        }

        promptLines.append("""
        For each item, respond with ONLY the number, classification, and choice on one line.
        Format: N: TRIVIAL A  (or TRIVIAL B, or SUBSTANTIVE A, or SUBSTANTIVE B)
        Example:
        1: TRIVIAL A
        2: SUBSTANTIVE B
        3: TRIVIAL A
        """)

        let session = ChatSession(
            container,
            instructions: """
            You are an expert transcript reviewer. Your primary job is to filter out trivial \
            differences between two transcriptions of the same audio so that humans only need \
            to review genuinely substantive discrepancies. Be AGGRESSIVE about marking things \
            as TRIVIAL. Most transcription differences are just different ways of hearing the \
            same words. Only mark something SUBSTANTIVE if the meaning genuinely changes. \
            Respond with ONLY your classifications, no explanation.
            """,
            generateParameters: GenerateParameters(maxTokens: 2048, temperature: 0.1, topP: 0.95)
        )

        let response = try await session.respond(to: promptLines.joined(separator: "\n"))

        // Parse responses
        var choices: [UUID: ReconciliationSourceChoice] = [:]
        var trivialRowIDs = Set<UUID>()
        let lines = response.components(separatedBy: .newlines)

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            // Parse "N: TRIVIAL A" or "N: SUBSTANTIVE B"
            let parts = trimmed.components(separatedBy: ":")
            guard parts.count >= 2,
                  let num = Int(parts[0].trimmingCharacters(in: .whitespaces)),
                  num >= 1, num <= discrepancies.count else { continue }

            let rest = parts[1].trimmingCharacters(in: .whitespaces).uppercased()
            let rowIndex = num - 1
            let rowID = discrepancies[rowIndex].id

            // Check if trivial
            if rest.contains("TRIVIAL") {
                trivialRowIDs.insert(rowID)
            }

            // Extract choice (A or B)
            if rest.contains("A") {
                choices[rowID] = .reference
            } else if rest.contains("B") {
                choices[rowID] = .candidate
            }
        }

        return PreResolutionResult(choices: choices, trivialRowIDs: trivialRowIDs)
    }

    /// Candidate speaker boundaries discovered by any diarization pass.
    struct CandidateBoundary: Sendable {
        let time: TimeInterval
        let beforeSpeaker: String
        let afterSpeaker: String
        let detectedByCount: Int  // how many passes detected this boundary
        let totalPasses: Int
    }

    /// Result of LLM boundary confirmation.
    struct BoundaryConfirmation: Sendable {
        let time: TimeInterval
        let isConfirmed: Bool
    }

    /// Use LLM to confirm or reject candidate speaker boundaries based on transcript context.
    ///
    /// Given a list of candidate speaker-change points (from multiple diarization passes),
    /// the LLM reads the surrounding transcript text and decides whether each boundary
    /// represents a real speaker change based on conversational patterns.
    func confirmSpeakerBoundaries(
        candidates: [CandidateBoundary],
        transcriptionSegments: [TranscriptionSegment],
        speakerMapping: SpeakerMapping
    ) async throws -> [BoundaryConfirmation] {
        guard let container = modelContainer else {
            throw TranscriboError.transcriptionFailed("No cleanup model loaded.")
        }

        guard !candidates.isEmpty else { return [] }

        // Build the prompt with transcript context around each candidate boundary
        var promptLines: [String] = ["""
        You are analyzing a transcript of a conversation. \
        Multiple speaker-detection systems were run on the audio. Most of the time they agree, \
        but at certain points, some systems detected a speaker change that others missed.

        For each candidate speaker change below, I'll show you the transcript text around that \
        point with speaker labels. Based on the conversational context, decide whether a \
        DIFFERENT person is likely speaking after the marked point.

        Key patterns that indicate a real speaker change:
        - Short acknowledgments ("Okay.", "Right.", "Yeah.", "Gotcha.", "Mm-hmm.") between longer statements
        - A question followed by an answer
        - A statement followed by "So..." or "Well..." starting a new thought from a different perspective
        - Change in pronoun perspective ("we filed" -> "you filed")
        - Change in knowledge perspective (explaining something -> asking about it)
        - A speaker switching mid-sentence to respond before the other finishes

        Key patterns that indicate NO speaker change (same person continuing):
        - Continuing the same thought with "And...", "So...", "But..."
        - Self-correction or rephrasing
        - Listing multiple items
        - Filler words mid-sentence ("um", "uh", "you know")
        - Pausing then resuming the same idea

        For each item, respond with ONLY the number and YES or NO:
        1: YES
        2: NO
        3: YES

        """]

        for (i, candidate) in candidates.enumerated() {
            // Get ~15 seconds of transcript before and after the candidate boundary
            let beforeSegments = transcriptionSegments.filter {
                $0.end <= candidate.time + 1 && $0.start >= candidate.time - 15
            }
            let afterSegments = transcriptionSegments.filter {
                $0.start >= candidate.time - 1 && $0.end <= candidate.time + 15
            }

            // Include speaker labels in the context so the LLM can see who's talking
            let beforeText = beforeSegments
                .map { seg in
                    let name = speakerMapping.displayName(for: seg.speakerID)
                    return "[\(name)]: \(seg.text.trimmingCharacters(in: .whitespacesAndNewlines))"
                }
                .joined(separator: " ")
                .suffix(300)

            let afterText = afterSegments
                .map { seg in
                    let name = speakerMapping.displayName(for: seg.speakerID)
                    return "[\(name)]: \(seg.text.trimmingCharacters(in: .whitespacesAndNewlines))"
                }
                .joined(separator: " ")
                .prefix(300)

            let detectionInfo = "\(candidate.detectedByCount) of \(candidate.totalPasses) systems detected a change here"
            let currentSpeaker = speakerMapping.displayName(for: candidate.beforeSpeaker)

            promptLines.append("--- BOUNDARY \(i + 1) at \(TimeFormatting.timestamp(candidate.time)) (\(detectionInfo)) ---")
            promptLines.append("Currently labeled as \(currentSpeaker) speaking throughout.")
            promptLines.append("BEFORE: ...\(beforeText)")
            promptLines.append(">>> POSSIBLE SPEAKER CHANGE <<<")
            promptLines.append("AFTER: \(afterText)...")
            promptLines.append("")
        }

        let isQwen = loadedModelID?.lowercased().contains("qwen") ?? false
        let effectivePrompt = isQwen ? "/no_think\n\(promptLines.joined(separator: "\n"))" : promptLines.joined(separator: "\n")

        let session = ChatSession(
            container,
            instructions: """
            You are a conversation analysis expert. Your job is to identify real speaker changes \
            in a transcript based on conversational context. Be AGGRESSIVE about finding real \
            speaker changes — short responses like "Okay", "Right", "Yeah", "Gotcha" between \
            longer statements are almost always a different person. Respond with ONLY numbers \
            and YES/NO, nothing else.
            """,
            generateParameters: GenerateParameters(maxTokens: 1024, temperature: 0.1, topP: 0.95)
        )

        let response = try await session.respond(to: effectivePrompt)

        // Parse YES/NO responses
        var confirmations: [BoundaryConfirmation] = []
        let lines = response.components(separatedBy: .newlines)

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            let parts = trimmed.components(separatedBy: ":")
            guard parts.count >= 2,
                  let num = Int(parts[0].trimmingCharacters(in: .whitespaces)),
                  num >= 1, num <= candidates.count else { continue }

            let answer = parts[1].trimmingCharacters(in: .whitespaces).uppercased()
            let isConfirmed = answer.contains("YES")

            confirmations.append(BoundaryConfirmation(
                time: candidates[num - 1].time,
                isConfirmed: isConfirmed
            ))
        }

        return confirmations
    }

    func unloadModel() {
        modelContainer = nil
        loadedModelID = nil
    }

    // MARK: - Private Helpers

    private func findBestOverlap(
        target: DiarizationSegment,
        candidates: [DiarizationSegment]
    ) -> DiarizationSegment? {
        var bestOverlap: TimeInterval = 0
        var best: DiarizationSegment?

        for candidate in candidates {
            let overlap = max(0, min(target.end, candidate.end) - max(target.start, candidate.start))
            if overlap > bestOverlap {
                bestOverlap = overlap
                best = candidate
            }
        }

        return best
    }

    private func buildDiarizationResolutionPrompt(
        disagreements: [(index: Int, segment: DiarizationSegment, candidates: [String: String])],
        transcriptionSegments: [TranscriptionSegment],
        speakerMapping: SpeakerMapping
    ) -> String {
        var lines: [String] = ["The following segments have speaker attribution disagreements between multiple diarization passes.\n"]

        for d in disagreements {
            // Find transcript text near this time
            let nearbyText = transcriptionSegments
                .filter { $0.start >= d.segment.start - 10 && $0.end <= d.segment.end + 10 }
                .map { "\(speakerMapping.displayName(for: $0.speakerID)): \($0.text)" }
                .joined(separator: "\n")

            lines.append("--- SEGMENT_\(d.index) [\(TimeFormatting.timestamp(d.segment.start)) - \(TimeFormatting.timestamp(d.segment.end))] ---")
            lines.append("Candidate speakers (aligned IDs): \(d.candidates.map { "\($0.key)=\($0.value)" }.joined(separator: ", "))")
            lines.append("Context:\n\(nearbyText)")
            lines.append("")
        }

        return lines.joined(separator: "\n")
    }

    private func parseDiarizationCorrections(
        response: String,
        disagreements: [(index: Int, segment: DiarizationSegment, candidates: [String: String])]
    ) -> [(index: Int, speakerID: String)] {
        var corrections: [(index: Int, speakerID: String)] = []
        let lines = response.components(separatedBy: .newlines)
        let validSpeakerIDsBySegment = Dictionary(
            uniqueKeysWithValues: disagreements.map { disagreement in
                (disagreement.index, Set(disagreement.candidates.values))
            }
        )

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            // Parse "SEGMENT_N: SPEAKER_ID"
            guard trimmed.hasPrefix("SEGMENT_") else { continue }
            let parts = trimmed.replacingOccurrences(of: "SEGMENT_", with: "").components(separatedBy: ":")
            guard parts.count >= 2,
                  let segIndex = Int(parts[0].trimmingCharacters(in: .whitespaces)) else { continue }

            let speakerID = parts[1].trimmingCharacters(in: .whitespaces)
            guard !speakerID.isEmpty,
                  validSpeakerIDsBySegment[segIndex]?.contains(speakerID) == true else {
                continue
            }

            corrections.append((index: segIndex, speakerID: speakerID))
        }

        return corrections
    }
}
