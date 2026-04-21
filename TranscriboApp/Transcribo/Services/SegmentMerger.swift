import Foundation

/// Represents a diarization segment (speaker label + time range).
struct DiarizationSegment: Sendable {
    let speakerID: String
    let start: TimeInterval
    let end: TimeInterval
    let qualityScore: Float
}

/// Merges transcription segments with diarization results by time overlap,
/// with multi-layer post-processing to reduce fragmentation.
enum SegmentMerger {

    // MARK: - Configuration

    /// Diarization segments shorter than this are absorbed into the surrounding speaker.
    /// Kept low (0.3s) because even very short interjections ("Okay", "Right") are
    /// legitimate speaker changes in conversational audio.
    private static let minimumSegmentDuration: TimeInterval = 0.3

    /// Same-speaker diarization segments separated by less than this are merged.
    private static let sameSpkMergeGap: TimeInterval = 0.5

    /// A speaker appearing for less than this duration between two segments of another
    /// speaker is considered a false detection and absorbed — but only if it's very brief.
    private static let microFlipThreshold: TimeInterval = 0.5

    /// When a transcription segment's overlap margin between two speakers is less than
    /// this ratio of the segment duration, use contextual smoothing instead.
    private static let ambiguousOverlapRatio: Double = 0.10

    /// When word-level speaker votes are nearly tied, prefer local smoothing over
    /// creating a one-word speaker flip.
    private static let ambiguousWordMarginRatio: Double = 0.20

    /// Same-speaker word groups separated by more than this are broken into distinct
    /// transcript segments even if the speaker does not change.
    private static let wordSegmentGapThreshold: TimeInterval = 2.0

    // MARK: - Public API

    /// Assign speaker IDs to transcription segments based on diarization,
    /// with post-processing to reduce fragmentation.
    ///
    /// - Parameter diagnostic: optional per-reassignment callback used when the user
    ///     has turned on Diagnostic Mode. Forwarded to the Layer-4 smoother so every
    ///     word-level reassignment logs a human-readable description.
    static func merge(
        transcriptionSegments: [TranscriptionSegment],
        diarizationSegments: [DiarizationSegment],
        diagnostic: ((String) -> Void)? = nil
    ) -> [TranscriptionSegment] {
        guard !diarizationSegments.isEmpty else {
            return smoothSentenceBoundaries(transcriptionSegments, diagnostic: diagnostic)
        }

        // Layer 1: Post-process diarization segments to remove noise
        let cleaned = postProcessDiarization(diarizationSegments)

        // Prefer word-level speaker assignment whenever timings are available.
        if let wordAssigned = wordAwareMerge(
            transcriptionSegments: transcriptionSegments,
            diarizationSegments: cleaned
        ), !wordAssigned.isEmpty {
            return smoothSentenceBoundaries(fillUnknownSpeakers(wordAssigned), diagnostic: diagnostic)
        }

        // Layer 2: Context-aware speaker assignment
        var assigned = contextAwareMerge(
            transcriptionSegments: transcriptionSegments,
            diarizationSegments: cleaned
        )

        // Layer 3: Fill any remaining UNKNOWN segments by nearest neighbor
        assigned = fillUnknownSpeakers(assigned)

        // Layer 4: Sentence-coherence smoother — collapses A-B-A single-word flips
        // caused by noisy word timestamps landing on the wrong side of a diarization
        // boundary inside a continuous sentence.
        return smoothSentenceBoundaries(assigned, diagnostic: diagnostic)
    }

    // MARK: - Layer 1: Diarization Post-Processing

    /// Clean up raw diarization output by merging same-speaker gaps,
    /// removing micro-segments, and absorbing false speaker flips.
    static func postProcessDiarization(_ segments: [DiarizationSegment]) -> [DiarizationSegment] {
        guard !segments.isEmpty else { return [] }

        var result = segments.sorted { $0.start < $1.start }

        // Pass 0: Reassign UNKNOWN segments to the nearest known speaker
        result = reassignUnknownSpeakers(result)

        // Pass 1: Merge consecutive same-speaker segments with small gaps
        result = mergeSameSpeakerGaps(result)

        // Pass 2: Absorb micro-segments into surrounding speaker
        result = absorbMicroSegments(result)

        // Pass 3: Absorb "sandwich" flips (A-B-A where B is very short)
        result = absorbSandwichFlips(result)

        // Pass 4: Final same-speaker merge (may have created new adjacencies)
        result = mergeSameSpeakerGaps(result)

        return result
    }

    /// Reassign segments labeled "UNKNOWN" to the nearest known speaker by time proximity.
    /// This preserves all explicit speaker IDs because this merge stage does not know
    /// the user's requested speaker count.
    private static func reassignUnknownSpeakers(_ segments: [DiarizationSegment]) -> [DiarizationSegment] {
        guard !segments.isEmpty else { return segments }

        let knownSpeakers = Set(segments.map(\.speakerID)).subtracting(["UNKNOWN"])
        guard !knownSpeakers.isEmpty else { return segments }

        return segments.map { seg in
            guard seg.speakerID == "UNKNOWN" else { return seg }

            // Find the nearest known speaker segment by time distance
            let midpoint = (seg.start + seg.end) / 2
            var bestSpeaker: String?
            var bestDistance: TimeInterval = .greatestFiniteMagnitude

            for other in segments where knownSpeakers.contains(other.speakerID) {
                let otherMid = (other.start + other.end) / 2
                let distance = abs(midpoint - otherMid)
                if distance < bestDistance {
                    bestDistance = distance
                    bestSpeaker = other.speakerID
                }
            }

            guard let speaker = bestSpeaker else { return seg }
            return DiarizationSegment(
                speakerID: speaker,
                start: seg.start,
                end: seg.end,
                qualityScore: seg.qualityScore * 0.8
            )
        }
    }

    /// Merge consecutive segments from the same speaker separated by a small gap.
    private static func mergeSameSpeakerGaps(_ segments: [DiarizationSegment]) -> [DiarizationSegment] {
        guard !segments.isEmpty else { return [] }

        var merged: [DiarizationSegment] = [segments[0]]

        for i in 1..<segments.count {
            let current = segments[i]
            let last = merged[merged.count - 1]

            if current.speakerID == last.speakerID &&
               (current.start - last.end) < sameSpkMergeGap {
                // Merge: extend the previous segment to cover both
                merged[merged.count - 1] = DiarizationSegment(
                    speakerID: last.speakerID,
                    start: last.start,
                    end: max(last.end, current.end),
                    qualityScore: (last.qualityScore + current.qualityScore) / 2
                )
            } else {
                merged.append(current)
            }
        }

        return merged
    }

    /// Remove segments shorter than the minimum duration by absorbing them
    /// into the nearest neighboring segment.
    private static func absorbMicroSegments(_ segments: [DiarizationSegment]) -> [DiarizationSegment] {
        guard segments.count > 1 else { return segments }

        var result: [DiarizationSegment] = []

        for i in 0..<segments.count {
            let seg = segments[i]
            let duration = seg.end - seg.start

            if duration >= minimumSegmentDuration {
                result.append(seg)
            } else {
                // This segment is too short — absorb it into the nearest neighbor
                let prevSpeaker = i > 0 ? segments[i - 1].speakerID : nil
                let nextSpeaker = i + 1 < segments.count ? segments[i + 1].speakerID : nil

                // If both neighbors are the same speaker, absorb completely (gap will be merged later)
                if prevSpeaker == nextSpeaker, let speaker = prevSpeaker {
                    // Extend previous segment to cover this gap
                    if let lastIdx = result.lastIndex(where: { $0.speakerID == speaker }) {
                        result[lastIdx] = DiarizationSegment(
                            speakerID: speaker,
                            start: result[lastIdx].start,
                            end: seg.end,
                            qualityScore: result[lastIdx].qualityScore
                        )
                    }
                } else if prevSpeaker != nil {
                    // Assign to previous speaker
                    if !result.isEmpty {
                        let lastIdx = result.count - 1
                        result[lastIdx] = DiarizationSegment(
                            speakerID: result[lastIdx].speakerID,
                            start: result[lastIdx].start,
                            end: seg.end,
                            qualityScore: result[lastIdx].qualityScore
                        )
                    }
                } else {
                    // No previous — assign to next speaker (will be handled by next iteration)
                    result.append(seg)
                }
            }
        }

        return result
    }

    /// Detect "sandwich" patterns: Speaker A, then Speaker B for a short time,
    /// then Speaker A again. The B in the middle is likely a false detection.
    private static func absorbSandwichFlips(_ segments: [DiarizationSegment]) -> [DiarizationSegment] {
        guard segments.count >= 3 else { return segments }

        var result = segments
        var i = 1

        while i < result.count - 1 {
            let prev = result[i - 1]
            let current = result[i]
            let next = result[i + 1]

            let middleDuration = current.end - current.start

            // If the same speaker is on both sides and the middle is short, absorb it
            if prev.speakerID == next.speakerID && middleDuration < microFlipThreshold {
                // Replace all three with one merged segment
                let merged = DiarizationSegment(
                    speakerID: prev.speakerID,
                    start: prev.start,
                    end: next.end,
                    qualityScore: (prev.qualityScore + next.qualityScore) / 2
                )
                result.replaceSubrange((i - 1)...(i + 1), with: [merged])
                // Don't advance i — check the new configuration
            } else {
                i += 1
            }
        }

        return result
    }

    // MARK: - Layer 2: Context-Aware Speaker Assignment

    /// Word-level speaker assignment. Each word gets its own speaker match first,
    /// then the stream is re-grouped into readable speaker-homogeneous segments.
    private static func wordAwareMerge(
        transcriptionSegments: [TranscriptionSegment],
        diarizationSegments: [DiarizationSegment]
    ) -> [TranscriptionSegment]? {
        let positionedWords = extractPositionedWords(from: transcriptionSegments)
        guard !positionedWords.isEmpty else { return nil }

        var assignedWords = positionedWords.map { positionedWord in
            let bestMatches = findBestWordMatches(
                start: TimeInterval(positionedWord.timing.start),
                end: TimeInterval(positionedWord.timing.end),
                diarizationSegments: diarizationSegments
            )

            let duration = TimeInterval(positionedWord.timing.end - positionedWord.timing.start)
            let margin = max(0, bestMatches.bestOverlap - bestMatches.secondBestOverlap)
            let speakerID = bestMatches.bestSpeakerID ?? "UNKNOWN"
            let qualityScore = bestMatches.bestQualityScore ?? 0

            return AssignedWord(
                text: positionedWord.text,
                timing: positionedWord.timing,
                speakerID: speakerID,
                qualityScore: qualityScore,
                overlap: bestMatches.bestOverlap,
                margin: margin,
                sourceSegmentIndex: positionedWord.sourceSegmentIndex,
                duration: duration
            )
        }

        assignedWords = smoothWordAssignments(assignedWords)

        var mergedSegments: [TranscriptionSegment] = []
        var currentWords: [AssignedWord] = []

        func flushCurrentWords() {
            guard !currentWords.isEmpty else { return }
            mergedSegments.append(
                buildWordLevelSegment(
                    words: currentWords,
                    sourceSegments: transcriptionSegments
                )
            )
            currentWords.removeAll(keepingCapacity: true)
        }

        for word in assignedWords {
            if shouldSplitWordSegment(beforeAppending: word, currentWords: currentWords) {
                flushCurrentWords()
            }

            currentWords.append(word)
        }

        flushCurrentWords()
        return mergedSegments
    }

    /// Assign speakers with awareness of surrounding context, not just raw overlap.
    private static func contextAwareMerge(
        transcriptionSegments: [TranscriptionSegment],
        diarizationSegments: [DiarizationSegment]
    ) -> [TranscriptionSegment] {
        // First pass: assign by maximum overlap (same as before)
        var assigned = transcriptionSegments.map { segment -> TranscriptionSegment in
            var merged = segment
            if let match = findBestSpeaker(
                start: segment.start,
                end: segment.end,
                diarizationSegments: diarizationSegments
            ) {
                merged.speakerID = match.speakerID
                merged.diarizationQuality = match.qualityScore
                merged.diarizationOverlap = match.overlap
            }
            return merged
        }

        // Second pass: smooth isolated speaker changes
        // If a single segment has a different speaker than both its neighbors,
        // and the overlap margin was small, flip it to match the neighbors.
        for i in 1..<(assigned.count - 1) {
            let prev = assigned[i - 1]
            let current = assigned[i]
            let next = assigned[i + 1]

            // Check if this segment is an isolated speaker change
            if prev.speakerID == next.speakerID && current.speakerID != prev.speakerID {
                let segDuration = current.end - current.start

                // Check how ambiguous the overlap was
                let overlaps = computeOverlaps(
                    start: current.start,
                    end: current.end,
                    diarizationSegments: diarizationSegments
                )

                let currentSpeakerOverlap = overlaps[current.speakerID] ?? 0
                let neighborSpeakerOverlap = overlaps[prev.speakerID] ?? 0
                let margin = currentSpeakerOverlap - neighborSpeakerOverlap

                // If the margin is slim (less than 15% of segment duration), flip to neighbor
                if margin < segDuration * ambiguousOverlapRatio {
                    assigned[i].speakerID = prev.speakerID
                }
            }
        }

        // Third pass: smooth runs of 2 isolated segments
        // Pattern: A A B B A A where the B-B is short → flip to A
        for i in 1..<(assigned.count - 2) {
            let prev = assigned[i - 1]
            let current = assigned[i]
            let next = assigned[i + 1]
            let afterNext = assigned[i + 2]

            if prev.speakerID == afterNext.speakerID &&
               current.speakerID == next.speakerID &&
               current.speakerID != prev.speakerID {
                let runDuration = next.end - current.start
                if runDuration < microFlipThreshold {
                    assigned[i].speakerID = prev.speakerID
                    assigned[i + 1].speakerID = prev.speakerID
                }
            }
        }

        return assigned
    }

    private static func extractPositionedWords(
        from transcriptionSegments: [TranscriptionSegment]
    ) -> [PositionedWord] {
        var positionedWords: [PositionedWord] = []

        for (segmentIndex, segment) in transcriptionSegments.enumerated() {
            let wordTimings = segment.words?.isEmpty == false
                ? segment.words!
                : estimateWordTimings(for: segment)

            for wordTiming in wordTimings {
                let cleanedWord = wordTiming.word.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !cleanedWord.isEmpty else { continue }

                positionedWords.append(
                    PositionedWord(
                        text: cleanedWord,
                        timing: TranscriptionSegment.WordTiming(
                            word: cleanedWord,
                            start: wordTiming.start,
                            end: wordTiming.end,
                            probability: wordTiming.probability
                        ),
                        sourceSegmentIndex: segmentIndex
                    )
                )
            }
        }

        return positionedWords.sorted { $0.timing.start < $1.timing.start }
    }

    private static func estimateWordTimings(
        for segment: TranscriptionSegment
    ) -> [TranscriptionSegment.WordTiming] {
        let textWords = segment.text.split(whereSeparator: \.isWhitespace).map(String.init)
        guard !textWords.isEmpty else { return [] }

        let segmentDuration = max(0.01, segment.end - segment.start)
        let wordDuration = segmentDuration / Double(textWords.count)
        let defaultConfidence = segment.averageWordConfidence ?? 0.5

        return textWords.enumerated().map { index, word in
            let start = Float(segment.start + (Double(index) * wordDuration))
            let end = Float(segment.start + (Double(index + 1) * wordDuration))
            return TranscriptionSegment.WordTiming(
                word: word,
                start: start,
                end: end,
                probability: defaultConfidence
            )
        }
    }

    private static func findBestWordMatches(
        start: TimeInterval,
        end: TimeInterval,
        diarizationSegments: [DiarizationSegment]
    ) -> WordMatchSummary {
        var bestSpeakerID: String?
        var bestOverlap: TimeInterval = 0
        var bestQualityScore: Float?
        var secondBestOverlap: TimeInterval = 0

        for diarSeg in diarizationSegments {
            let overlapStart = max(start, diarSeg.start)
            let overlapEnd = min(end, diarSeg.end)
            let overlap = max(0, overlapEnd - overlapStart)

            guard overlap > 0 else { continue }

            if overlap > bestOverlap {
                secondBestOverlap = bestOverlap
                bestOverlap = overlap
                bestSpeakerID = diarSeg.speakerID
                bestQualityScore = diarSeg.qualityScore
            } else if overlap > secondBestOverlap {
                secondBestOverlap = overlap
            }
        }

        return WordMatchSummary(
            bestSpeakerID: bestSpeakerID,
            bestOverlap: bestOverlap,
            secondBestOverlap: secondBestOverlap,
            bestQualityScore: bestQualityScore
        )
    }

    private static func smoothWordAssignments(_ words: [AssignedWord]) -> [AssignedWord] {
        guard words.count >= 3 else { return words }

        var smoothed = words

        for index in 1..<(smoothed.count - 1) {
            let previous = smoothed[index - 1]
            let current = smoothed[index]
            let next = smoothed[index + 1]

            guard previous.speakerID == next.speakerID,
                  current.speakerID != previous.speakerID,
                  current.speakerID != "UNKNOWN" else {
                continue
            }

            let marginThreshold = current.duration * ambiguousWordMarginRatio
            let hasWeakEvidence = current.margin < marginThreshold || current.overlap < (current.duration * 0.35)

            if hasWeakEvidence {
                smoothed[index].speakerID = previous.speakerID
            }
        }

        return smoothed
    }

    private static func shouldSplitWordSegment(
        beforeAppending nextWord: AssignedWord,
        currentWords: [AssignedWord]
    ) -> Bool {
        guard let lastWord = currentWords.last,
              let firstWord = currentWords.first else {
            return false
        }

        if nextWord.speakerID != lastWord.speakerID {
            return true
        }

        let gap = TimeInterval(nextWord.timing.start - lastWord.timing.end)
        let currentDuration = TimeInterval(nextWord.timing.end - firstWord.timing.start)
        let sentenceEnded = lastWord.text.last.map { ".!?".contains($0) } ?? false

        // Only split on long pauses (someone stopped talking)
        if gap > wordSegmentGapThreshold {
            return true
        }

        // Split at sentence boundaries if the segment is already substantial
        if sentenceEnded && currentDuration >= 8.0 {
            return true
        }

        // Hard cap at 30 seconds
        if currentDuration > 30.0 {
            return true
        }

        return false
    }

    private static func buildWordLevelSegment(
        words: [AssignedWord],
        sourceSegments: [TranscriptionSegment]
    ) -> TranscriptionSegment {
        let segmentWords = words.map(\.timing)
        let speakerID = words.first?.speakerID ?? "UNKNOWN"
        let start = TimeInterval(segmentWords.first?.start ?? 0)
        let end = TimeInterval(segmentWords.last?.end ?? segmentWords.first?.start ?? 0)
        let text = normalizeSegmentText(segmentWords.map(\.word).joined(separator: " "))
        let sourceWeights = words.reduce(into: [Int: Int]()) { partialResult, word in
            partialResult[word.sourceSegmentIndex, default: 0] += 1
        }

        let diarizationQualities = words
            .filter { $0.qualityScore > 0 }
            .map(\.qualityScore)
        let totalOverlap = words.reduce(into: TimeInterval.zero) { total, word in
            total += word.overlap
        }
        let segmentDuration = max(0, end - start)

        return TranscriptionSegment(
            speakerID: speakerID,
            start: start,
            end: end,
            text: text,
            words: segmentWords,
            averageLogProb: weightedAverage(
                for: sourceWeights,
                in: sourceSegments,
                value: { $0.averageLogProb }
            ),
            noSpeechProb: weightedAverage(
                for: sourceWeights,
                in: sourceSegments,
                value: { $0.noSpeechProb }
            ),
            decodingTemperature: weightedAverage(
                for: sourceWeights,
                in: sourceSegments,
                value: { $0.decodingTemperature }
            ),
            compressionRatio: weightedAverage(
                for: sourceWeights,
                in: sourceSegments,
                value: { $0.compressionRatio }
            ),
            diarizationQuality: average(of: diarizationQualities),
            diarizationOverlap: min(segmentDuration, totalOverlap)
        )
    }

    private static func weightedAverage(
        for weights: [Int: Int],
        in sourceSegments: [TranscriptionSegment],
        value: (TranscriptionSegment) -> Float?
    ) -> Float? {
        var weightedTotal: Float = 0
        var totalWeight: Float = 0

        for (segmentIndex, weight) in weights {
            guard sourceSegments.indices.contains(segmentIndex),
                  let segmentValue = value(sourceSegments[segmentIndex]) else {
                continue
            }

            weightedTotal += segmentValue * Float(weight)
            totalWeight += Float(weight)
        }

        guard totalWeight > 0 else { return nil }
        return weightedTotal / totalWeight
    }

    private static func average(of values: [Float]) -> Float? {
        guard !values.isEmpty else { return nil }
        let total = values.reduce(Float.zero, +)
        return total / Float(values.count)
    }

    private static func normalizeSegmentText(_ text: String) -> String {
        text
            .replacingOccurrences(of: " ,", with: ",")
            .replacingOccurrences(of: " .", with: ".")
            .replacingOccurrences(of: " !", with: "!")
            .replacingOccurrences(of: " ?", with: "?")
            .replacingOccurrences(of: " ;", with: ";")
            .replacingOccurrences(of: " :", with: ":")
            .replacingOccurrences(of: " n't", with: "n't")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Compute all speaker overlaps for a time interval (not just the best one).
    private static func computeOverlaps(
        start: TimeInterval,
        end: TimeInterval,
        diarizationSegments: [DiarizationSegment]
    ) -> [String: TimeInterval] {
        var overlaps: [String: TimeInterval] = [:]

        for seg in diarizationSegments {
            let overlapStart = max(start, seg.start)
            let overlapEnd = min(end, seg.end)
            let overlap = max(0, overlapEnd - overlapStart)
            if overlap > 0 {
                overlaps[seg.speakerID, default: 0] += overlap
            }
        }

        return overlaps
    }

    // MARK: - Fill Unknown Speakers

    /// Any transcription segments still labeled "UNKNOWN" (no diarization overlap found)
    /// get assigned to the nearest known speaker by time proximity.
    private static func fillUnknownSpeakers(_ segments: [TranscriptionSegment]) -> [TranscriptionSegment] {
        let knownSegments = segments.filter { $0.speakerID != "UNKNOWN" }
        guard !knownSegments.isEmpty else { return segments }

        return segments.map { seg in
            guard seg.speakerID == "UNKNOWN" else { return seg }

            let midpoint = (seg.start + seg.end) / 2
            var bestSpeaker: String?
            var bestDistance: TimeInterval = .greatestFiniteMagnitude

            for known in knownSegments {
                let knownMid = (known.start + known.end) / 2
                let distance = abs(midpoint - knownMid)
                if distance < bestDistance {
                    bestDistance = distance
                    bestSpeaker = known.speakerID
                }
            }

            guard let speaker = bestSpeaker else { return seg }
            var fixed = seg
            fixed.speakerID = speaker
            return fixed
        }
    }

    // MARK: - Core Overlap Matching

    /// Find the diarization speaker with the most time overlap for a given interval.
    private static func findBestSpeaker(
        start: TimeInterval,
        end: TimeInterval,
        diarizationSegments: [DiarizationSegment]
    ) -> MatchResult? {
        var bestMatch: MatchResult?
        var bestOverlap: TimeInterval = 0

        for diarSeg in diarizationSegments {
            let overlapStart = max(start, diarSeg.start)
            let overlapEnd = min(end, diarSeg.end)
            let overlap = max(0, overlapEnd - overlapStart)

            if overlap > bestOverlap {
                bestOverlap = overlap
                bestMatch = MatchResult(
                    speakerID: diarSeg.speakerID,
                    qualityScore: diarSeg.qualityScore,
                    overlap: overlap
                )
            }
        }

        return bestMatch
    }

    // MARK: - Layer 4: Sentence-Coherence Smoother

    /// Back-channel vocabulary that legitimately appears as a short speaker flip.
    /// When a middle segment matches one of these, we DO leave the A-B-A pattern
    /// alone — it's probably a real short interjection.
    private static let backchannelVocabulary: Set<String> = [
        "yeah", "yep", "yup",
        "okay", "ok",
        "right", "correct",
        "mmhmm", "mhmm", "mm-hmm", "mhm",
        "uh-huh", "uhhuh",
        "gotcha", "sure", "understood", "true",
        "yes", "no", "nope", "exactly"
    ]

    /// Minimum gap (seconds) above which adjacent same-speaker segments will NOT be
    /// coalesced even when their speakerIDs match. Preserves distinct turns separated
    /// by real pauses.
    private static let coalesceMaxGap: TimeInterval = 2.0

    /// Detect and repair speaker flips inside continuous sentences. These are almost
    /// always word-timestamp edge errors: a word whose ASR timestamp (±100–200 ms for
    /// Whisper, ±50-100 ms for Parakeet) fell on the wrong side of a diarization
    /// boundary (which itself has a few hundred ms of uncertainty), turning a
    /// single speaker's sentence into a phantom A→B or A→B→A speaker change.
    ///
    /// Operates at the WORD level (not the segment level), so it catches patterns the
    /// segment-level A-B-A sandwich check missed:
    ///   - A-B at a sentence-internal boundary: SPEAKER_0 says "I was thinking" then
    ///     SPEAKER_1 says "we should leave" — one continuous sentence split across
    ///     a segment boundary.
    ///   - Multiple words flipped at a sentence edge: "consider." getting pulled into
    ///     the next speaker's segment.
    ///
    /// Safeguards against over-correction (conservative by design):
    ///   - The majority speaker must hold AT LEAST 3× as many words as the minority.
    ///     A 4-vs-3 split isn't smoothed — both speakers have meaningful presence and
    ///     the sentence likely crosses speakers for real.
    ///   - Minority run must be ≤3 CONTIGUOUS words AT the start or end of a sentence
    ///     (never in the middle — those could be genuine handoffs).
    ///   - Skips sentences where the minority's text is a known back-channel token.
    ///   - Skips sentences shorter than 6 words (insufficient statistics).
    ///   - Only acts on sentences with exactly two speakers (3+ speakers present →
    ///     rapid-fire exchange, leave alone).
    ///
    /// Falls back to the legacy A-B-A segment-level smoother when word timings are
    /// not present on all segments (e.g. forced alignment failed and we have segment-
    /// level text only).
    ///
    /// - Parameter diagnostic: Optional callback invoked once per reassignment with
    ///     a human-readable description. Used by Diagnostic Mode to write a detailed
    ///     per-change audit to the process log / diagnostic report file.
    static func smoothSentenceBoundaries(
        _ segments: [TranscriptionSegment],
        diagnostic: ((String) -> Void)? = nil
    ) -> [TranscriptionSegment] {
        guard segments.count >= 2 else { return segments }

        let allHaveWords = segments.allSatisfy { ($0.words?.isEmpty == false) }
        guard allHaveWords else {
            return legacySandwichSmoother(segments, diagnostic: diagnostic)
        }

        // Flatten to word stream with mutable speaker IDs
        var stream: [(word: TranscriptionSegment.WordTiming, speakerID: String, originSegID: UUID)] = []
        for segment in segments {
            for w in segment.words ?? [] {
                stream.append((word: w, speakerID: segment.speakerID, originSegID: segment.id))
            }
        }
        guard stream.count >= 6 else { return segments }

        // Find sentence boundaries: words that end with `.`, `!`, or `?` start a new
        // sentence at the NEXT word.
        var sentenceStarts: [Int] = [0]
        for index in 0..<stream.count {
            let text = stream[index].word.word.trimmingCharacters(in: .whitespacesAndNewlines)
            if let last = text.last,
               last == "." || last == "!" || last == "?",
               index + 1 < stream.count {
                sentenceStarts.append(index + 1)
            }
        }

        // Walk each sentence and apply edge-reassignment rules
        var reassigned = 0
        var sentencesTouched = 0
        var sentencesSkipped = 0

        for sentenceIndex in 0..<sentenceStarts.count {
            let start = sentenceStarts[sentenceIndex]
            let end = sentenceIndex + 1 < sentenceStarts.count
                ? sentenceStarts[sentenceIndex + 1]
                : stream.count
            // Require at least 6 words for stable majority decisions
            guard end - start >= 6 else { continue }

            var counts: [String: Int] = [:]
            for j in start..<end { counts[stream[j].speakerID, default: 0] += 1 }
            guard counts.count == 2 else { continue }

            let sorted = counts.sorted { $0.value > $1.value }
            let majority = sorted[0].key
            let majorityCount = sorted[0].value
            let minority = sorted[1].key
            let minorityCount = sorted[1].value

            // Require minority ≤3 words AND a strong majority (≥3× the minority).
            // A 4-vs-3 split looks ambiguous; wait for acoustic or LLM evidence.
            guard minorityCount <= 3, majorityCount >= minorityCount * 3 else {
                sentencesSkipped += 1
                continue
            }

            // Minority words must be CONTIGUOUS and at the START or END of the sentence.
            let minorityPositions = (start..<end).filter { stream[$0].speakerID == minority }
            guard !minorityPositions.isEmpty else { continue }
            let allAtStart = minorityPositions.allSatisfy { $0 < start + minorityCount }
            let allAtEnd = minorityPositions.allSatisfy { $0 >= end - minorityCount }
            guard allAtStart || allAtEnd else {
                sentencesSkipped += 1
                continue
            }

            // Skip standalone back-channel interjections.
            let minorityText = minorityPositions
                .map {
                    stream[$0].word.word
                        .lowercased()
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                        .trimmingCharacters(in: .punctuationCharacters)
                }
                .joined(separator: " ")
            if backchannelVocabulary.contains(minorityText) {
                sentencesSkipped += 1
                continue
            }

            if let diagnostic {
                let sentenceText = (start..<end).map { stream[$0].word.word }.joined(separator: " ")
                let minorityPhrase = minorityPositions.map { stream[$0].word.word }.joined(separator: " ")
                let edge = allAtStart ? "start" : "end"
                let firstMinorityTime = stream[minorityPositions.first!].word.start
                diagnostic(
                    "Smoother reassigning \(minorityCount) word(s) at sentence \(edge) " +
                    "[~\(String(format: "%.1f", firstMinorityTime))s]: " +
                    "\"\(minorityPhrase)\" from \(minority) → \(majority) " +
                    "(sentence: \"\(sentenceText.prefix(100))\(sentenceText.count > 100 ? "…" : "")\", " +
                    "majority \(majorityCount)-\(minorityCount))"
                )
            }

            for pos in minorityPositions {
                stream[pos].speakerID = majority
                reassigned += 1
            }
            sentencesTouched += 1
        }

        if let diagnostic, reassigned > 0 {
            diagnostic(
                "Smoother summary: \(reassigned) words reassigned across \(sentencesTouched) sentences. " +
                "\(sentencesSkipped) sentence(s) inspected and skipped (majority threshold / non-edge / back-channel)."
            )
        } else if let diagnostic {
            diagnostic("Smoother: no reassignments applied (\(sentencesSkipped) sentence(s) inspected).")
        }

        guard reassigned > 0 else { return segments }

        return regroupFromWordStream(stream, using: segments)
    }

    /// Rebuild a segment list from the (possibly re-attributed) word stream. For each
    /// run of consecutive same-speaker words, emit one TranscriptionSegment. Metadata
    /// fields (averageLogProb etc.) are pulled from the original segment that owned
    /// the run's first word.
    private static func regroupFromWordStream(
        _ stream: [(word: TranscriptionSegment.WordTiming, speakerID: String, originSegID: UUID)],
        using originalSegments: [TranscriptionSegment]
    ) -> [TranscriptionSegment] {
        guard !stream.isEmpty else { return [] }

        let segmentsByID = Dictionary(uniqueKeysWithValues: originalSegments.map { ($0.id, $0) })

        var result: [TranscriptionSegment] = []
        var runStart = 0
        while runStart < stream.count {
            let speaker = stream[runStart].speakerID
            var runEnd = runStart + 1
            while runEnd < stream.count && stream[runEnd].speakerID == speaker {
                runEnd += 1
            }

            let runWords = (runStart..<runEnd).map { stream[$0].word }
            let runText = runWords.map(\.word).joined(separator: " ")
            let originSegID = stream[runStart].originSegID
            let meta = segmentsByID[originSegID]

            result.append(TranscriptionSegment(
                speakerID: speaker,
                start: TimeInterval(runWords.first?.start ?? 0),
                end: TimeInterval(runWords.last?.end ?? 0),
                text: runText,
                words: runWords,
                averageLogProb: meta?.averageLogProb,
                noSpeechProb: meta?.noSpeechProb,
                decodingTemperature: meta?.decodingTemperature,
                compressionRatio: meta?.compressionRatio,
                diarizationQuality: meta?.diarizationQuality,
                diarizationOverlap: meta?.diarizationOverlap
            ))
            runStart = runEnd
        }

        return coalesceAdjacentSameSpeakerSegments(result)
    }

    /// Segment-level A-B-A sandwich smoother. Kept as a fallback for the case where
    /// word timings are absent, in which case the word-level pass can't operate.
    private static func legacySandwichSmoother(
        _ segments: [TranscriptionSegment],
        diagnostic: ((String) -> Void)?
    ) -> [TranscriptionSegment] {
        guard segments.count >= 3 else { return segments }

        var working = segments
        var reassignmentCount = 0

        for i in 1..<(working.count - 1) {
            let prev = working[i - 1]
            let current = working[i]
            let next = working[i + 1]

            guard prev.speakerID == next.speakerID,
                  current.speakerID != prev.speakerID else { continue }

            let wordCount = current.words?.count ?? estimateWordCount(current.text)
            let duration = current.end - current.start
            guard wordCount <= 2, duration < 1.0 else { continue }

            if endsOnSentencePunctuation(prev.text) { continue }
            if looksLikeBackchannel(current.text) { continue }

            if let diagnostic {
                diagnostic(
                    "Legacy smoother: A-B-A sandwich at \(String(format: "%.1f", current.start))s " +
                    "\"\(current.text.trimmingCharacters(in: .whitespacesAndNewlines))\" " +
                    "from \(current.speakerID) → \(prev.speakerID)"
                )
            }

            working[i].speakerID = prev.speakerID
            reassignmentCount += 1
        }

        guard reassignmentCount > 0 else { return working }
        return coalesceAdjacentSameSpeakerSegments(working)
    }

    /// Merge adjacent segments that share a speaker and whose gap is small enough to
    /// represent one continuous turn. Called after `smoothSentenceBoundaries` so that
    /// the A-B-A → A-A-A we just created becomes one flowing A segment.
    private static func coalesceAdjacentSameSpeakerSegments(
        _ segments: [TranscriptionSegment]
    ) -> [TranscriptionSegment] {
        guard !segments.isEmpty else { return segments }

        var result: [TranscriptionSegment] = []
        result.reserveCapacity(segments.count)

        for segment in segments {
            guard let last = result.last,
                  last.speakerID == segment.speakerID,
                  segment.start - last.end < coalesceMaxGap else {
                result.append(segment)
                continue
            }

            let lastText = last.text.trimmingCharacters(in: .whitespacesAndNewlines)
            let segText = segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
            let mergedText = lastText.isEmpty
                ? segText
                : (segText.isEmpty ? lastText : "\(lastText) \(segText)")

            let mergedWords: [TranscriptionSegment.WordTiming]? = {
                switch (last.words, segment.words) {
                case (nil, nil): return nil
                case (let a?, nil): return a
                case (nil, let b?): return b
                case (let a?, let b?):
                    return (a + b).sorted { $0.start < $1.start }
                }
            }()

            let merged = TranscriptionSegment(
                id: last.id,
                speakerID: last.speakerID,
                start: last.start,
                end: segment.end,
                text: mergedText,
                words: mergedWords,
                averageLogProb: last.averageLogProb,
                noSpeechProb: last.noSpeechProb,
                decodingTemperature: last.decodingTemperature,
                compressionRatio: last.compressionRatio,
                diarizationQuality: last.diarizationQuality,
                diarizationOverlap: last.diarizationOverlap
            )
            result[result.count - 1] = merged
        }

        return result
    }

    private static func estimateWordCount(_ text: String) -> Int {
        text.split(whereSeparator: \.isWhitespace).count
    }

    private static func endsOnSentencePunctuation(_ text: String) -> Bool {
        guard let last = text.trimmingCharacters(in: .whitespacesAndNewlines).last else {
            return false
        }
        return last == "." || last == "!" || last == "?"
    }

    private static func looksLikeBackchannel(_ text: String) -> Bool {
        let cleaned = text
            .lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: .punctuationCharacters)
        // Single-token check: the whole segment is exactly one back-channel word
        return backchannelVocabulary.contains(cleaned)
    }
}

private struct MatchResult: Sendable {
    let speakerID: String
    let qualityScore: Float
    let overlap: TimeInterval
}

private struct PositionedWord: Sendable {
    let text: String
    let timing: TranscriptionSegment.WordTiming
    let sourceSegmentIndex: Int
}

private struct AssignedWord: Sendable {
    let text: String
    let timing: TranscriptionSegment.WordTiming
    var speakerID: String
    let qualityScore: Float
    let overlap: TimeInterval
    let margin: TimeInterval
    let sourceSegmentIndex: Int
    let duration: TimeInterval
}

private struct WordMatchSummary: Sendable {
    let bestSpeakerID: String?
    let bestOverlap: TimeInterval
    let secondBestOverlap: TimeInterval
    let bestQualityScore: Float?
}
