import Foundation

enum ReconciliationService {
    static func buildDraft(
        referencePass: TranscriptionPass,
        candidatePass: TranscriptionPass,
        existingConsensusPass: TranscriptionPass? = nil
    ) -> ReconciliationDraft {
        // Pre-merge consecutive same-speaker segments
        let mergedReference = mergeConsecutiveSpeakerSegments(referencePass.result.segments)
        let mergedCandidate = mergeConsecutiveSpeakerSegments(candidatePass.result.segments)

        // Build time-aligned groups (same as before)
        let groups = buildGroups(reference: mergedReference, candidate: mergedCandidate)
        let consensusSegments = existingConsensusPass?.result.segments ?? []

        // Now split each group into sentence-level rows
        var rows: [ReconciliationRow] = []

        for group in groups {
            let sentenceRows = buildSentenceRows(
                group: group,
                consensusSegments: consensusSegments
            )
            rows.append(contentsOf: sentenceRows)
        }

        return ReconciliationDraft(
            referencePassID: referencePass.id,
            candidatePassID: candidatePass.id,
            consensusPassID: existingConsensusPass?.id,
            referenceLabel: "\(referencePass.kind.displayName) \u{2022} \(referencePass.modelName)",
            candidateLabel: "\(candidatePass.kind.displayName) \u{2022} \(candidatePass.modelName)",
            rows: rows
        )
    }

    // MARK: - Sentence-Level Row Building

    /// Split a time-aligned group into sentence-level rows.
    /// Sentences that are substantively identical between ref and candidate become
    /// a single collapsed "aligned" row. Sentences that differ become expanded
    /// discrepancy rows.
    private static func buildSentenceRows(
        group: SegmentGroup,
        consensusSegments: [TranscriptionSegment]
    ) -> [ReconciliationRow] {
        let refText = canonicalText(group.referenceSegments)
        let candText = canonicalText(group.candidateSegments)

        // If one side is empty, just make one row for the whole group
        guard !group.referenceSegments.isEmpty, !group.candidateSegments.isEmpty else {
            return [buildWholeGroupRow(group: group, consensusSegments: consensusSegments)]
        }

        // Split both sides into sentences
        let refSentences = splitIntoSentences(refText)
        let candSentences = splitIntoSentences(candText)

        // Use LCS on normalized sentences to align them
        let matches = sentenceLCSMatches(lhs: refSentences, rhs: candSentences)

        var rows: [ReconciliationRow] = []
        var refUsed = Set<Int>()
        var candUsed = Set<Int>()

        // Estimate time per character for proportional timing
        let totalRefChars = max(1, refText.count)
        let totalCandChars = max(1, candText.count)
        let referenceRanges = estimatedSentenceRanges(
            sentences: refSentences,
            segments: group.referenceSegments,
            totalChars: totalRefChars
        )
        let candidateRanges = estimatedSentenceRanges(
            sentences: candSentences,
            segments: group.candidateSegments,
            totalChars: totalCandChars
        )

        // Process matched pairs
        for (refIdx, candIdx) in matches {
            refUsed.insert(refIdx)
            candUsed.insert(candIdx)

            let refSent = refSentences[refIdx]
            let candSent = candSentences[candIdx]
            let normalizedRef = deepNormalize(refSent)
            let normalizedCand = deepNormalize(candSent)
            let refRange = referenceRanges[refIdx]
            let candRange = candidateRanges[candIdx]
            let rowReferenceSegments = sentenceSourceSegments(
                group.referenceSegments,
                start: refRange.start,
                end: refRange.end
            )
            let rowCandidateSegments = sentenceSourceSegments(
                group.candidateSegments,
                start: candRange.start,
                end: candRange.end
            )
            let rowReferenceSpeaker = ReconciliationSegmentSummary.primarySpeakerID(rowReferenceSegments)
            let rowCandidateSpeaker = ReconciliationSegmentSummary.primarySpeakerID(rowCandidateSegments)

            // Estimate timing for this sentence
            let sentStart = min(refRange.start, candRange.start)
            let sentEnd = max(refRange.end, candRange.end)

            let speakerMatches = rowReferenceSpeaker == rowCandidateSpeaker
            let differenceKind: ReconciliationDifferenceKind

            if normalizedRef == normalizedCand {
                differenceKind = speakerMatches ? .aligned : .speaker
            } else if refSent.lowercased() == candSent.lowercased() {
                differenceKind = speakerMatches ? .punctuation : .speaker
            } else {
                differenceKind = speakerMatches ? .text : .textAndSpeaker
            }

            let preferredSource: ReconciliationSourceChoice = score(rowCandidateSegments) > score(rowReferenceSegments) ? .candidate : .reference
            let draftText = preferredSource == .candidate ? candSent : refSent
            let resolvedSpeaker = preferredSource == .candidate ? rowCandidateSpeaker : rowReferenceSpeaker

            // Check for existing consensus
            let consensusMatch = consensusSegments.first { seg in
                abs(seg.start - sentStart) < 2.0 && abs(seg.end - sentEnd) < 2.0
            }

            let finalDraftText: String
            let finalSource: ReconciliationSourceChoice
            let finalSpeaker: String

            if let consensusMatch, !consensusMatch.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                finalDraftText = consensusMatch.text
                finalSpeaker = consensusMatch.speakerID
                if deepNormalize(consensusMatch.text) == normalizedRef {
                    finalSource = .reference
                } else if deepNormalize(consensusMatch.text) == normalizedCand {
                    finalSource = .candidate
                } else {
                    finalSource = .manual
                }
            } else {
                finalDraftText = draftText
                finalSource = preferredSource
                finalSpeaker = resolvedSpeaker
            }

            rows.append(ReconciliationRow(
                start: sentStart,
                end: sentEnd,
                referenceSegments: rowReferenceSegments,
                candidateSegments: rowCandidateSegments,
                differenceKind: differenceKind,
                selectedSource: finalSource,
                draftText: finalDraftText,
                resolvedSpeakerID: finalSpeaker,
                needsReview: differenceKind.hasDifference && !differenceKind.isSoftDifference && consensusMatch == nil,
                referenceSentence: refSent,
                candidateSentence: candSent
            ))
        }

        // Handle unmatched reference sentences (missing from candidate)
        for refIdx in refSentences.indices where !refUsed.contains(refIdx) {
            let refSent = refSentences[refIdx]
            if deepNormalize(refSent).isEmpty { continue }

            let refRange = referenceRanges[refIdx]
            let rowReferenceSegments = sentenceSourceSegments(
                group.referenceSegments,
                start: refRange.start,
                end: refRange.end
            )
            let rowReferenceSpeaker = ReconciliationSegmentSummary.primarySpeakerID(rowReferenceSegments)

            rows.append(ReconciliationRow(
                start: refRange.start,
                end: refRange.end,
                referenceSegments: rowReferenceSegments,
                candidateSegments: [],
                differenceKind: .missing,
                selectedSource: .reference,
                draftText: refSent,
                resolvedSpeakerID: rowReferenceSpeaker,
                needsReview: true,
                referenceSentence: refSent,
                candidateSentence: ""
            ))
        }

        // Handle unmatched candidate sentences (missing from reference)
        for candIdx in candSentences.indices where !candUsed.contains(candIdx) {
            let candSent = candSentences[candIdx]
            if deepNormalize(candSent).isEmpty { continue }

            let candRange = candidateRanges[candIdx]
            let rowCandidateSegments = sentenceSourceSegments(
                group.candidateSegments,
                start: candRange.start,
                end: candRange.end
            )
            let rowCandidateSpeaker = ReconciliationSegmentSummary.primarySpeakerID(rowCandidateSegments)

            rows.append(ReconciliationRow(
                start: candRange.start,
                end: candRange.end,
                referenceSegments: [],
                candidateSegments: rowCandidateSegments,
                differenceKind: .missing,
                selectedSource: .candidate,
                draftText: candSent,
                resolvedSpeakerID: rowCandidateSpeaker,
                needsReview: true,
                referenceSentence: "",
                candidateSentence: candSent
            ))
        }

        return rows.sorted { $0.start < $1.start }
    }

    private static func buildWholeGroupRow(
        group: SegmentGroup,
        consensusSegments: [TranscriptionSegment]
    ) -> ReconciliationRow {
        let refText = canonicalText(group.referenceSegments)
        let candText = canonicalText(group.candidateSegments)
        let refSpeaker = ReconciliationSegmentSummary.primarySpeakerID(group.referenceSegments)
        let candSpeaker = ReconciliationSegmentSummary.primarySpeakerID(group.candidateSegments)

        let differenceKind: ReconciliationDifferenceKind
        if group.referenceSegments.isEmpty || group.candidateSegments.isEmpty {
            differenceKind = .missing
        } else if deepNormalize(refText) == deepNormalize(candText) {
            differenceKind = refSpeaker == candSpeaker ? .aligned : .speaker
        } else {
            differenceKind = refSpeaker == candSpeaker ? .text : .textAndSpeaker
        }

        let preferredSource: ReconciliationSourceChoice
        if group.candidateSegments.isEmpty { preferredSource = .reference }
        else if group.referenceSegments.isEmpty { preferredSource = .candidate }
        else { preferredSource = score(group.candidateSegments) > score(group.referenceSegments) ? .candidate : .reference }

        let draftText = preferredSource == .candidate ? candText : refText
        let resolvedSpeaker = preferredSource == .candidate ? candSpeaker : refSpeaker

        return ReconciliationRow(
            start: group.start,
            end: group.end,
            referenceSegments: group.referenceSegments,
            candidateSegments: group.candidateSegments,
            differenceKind: differenceKind,
            selectedSource: preferredSource,
            draftText: draftText,
            resolvedSpeakerID: resolvedSpeaker,
            needsReview: differenceKind.hasDifference && !differenceKind.isSoftDifference,
            referenceSentence: refText,
            candidateSentence: candText
        )
    }

    // MARK: - Sentence Splitting

    /// Split text into sentences. Uses period/question mark/exclamation as delimiters,
    /// but avoids splitting on abbreviations or decimals.
    private static func splitIntoSentences(_ text: String) -> [String] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        // Simple sentence boundary: split on .!? followed by space+uppercase or end of string
        var sentences: [String] = []
        var current = ""

        let chars = Array(trimmed)
        for i in chars.indices {
            current.append(chars[i])

            let isEndPunct = chars[i] == "." || chars[i] == "?" || chars[i] == "!"

            if isEndPunct {
                // Check if next char is space followed by uppercase, or end of string
                let isEndOfString = i == chars.count - 1
                let nextIsSpaceUpper = i + 2 < chars.count && chars[i + 1].isWhitespace && chars[i + 2].isUppercase

                if isEndOfString || nextIsSpaceUpper {
                    let sentence = current.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !sentence.isEmpty {
                        sentences.append(sentence)
                    }
                    current = ""
                }
            }
        }

        // Remaining text
        let remaining = current.trimmingCharacters(in: .whitespacesAndNewlines)
        if !remaining.isEmpty {
            sentences.append(remaining)
        }

        // If no sentence boundaries found, split on commas at reasonable lengths
        if sentences.count == 1 && sentences[0].count > 200 {
            return splitLongTextOnClauses(sentences[0])
        }

        return sentences
    }

    /// For very long text without sentence boundaries, split on clause boundaries.
    private static func splitLongTextOnClauses(_ text: String) -> [String] {
        var chunks: [String] = []
        var current = ""

        let words = text.split(whereSeparator: \.isWhitespace)
        for word in words {
            current += (current.isEmpty ? "" : " ") + word

            // Split at comma or natural pause point if chunk is long enough
            let lastChar = current.last
            if current.count > 100 && (lastChar == "," || lastChar == ";") {
                chunks.append(current.trimmingCharacters(in: .whitespacesAndNewlines))
                current = ""
            }
        }

        if !current.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            chunks.append(current.trimmingCharacters(in: .whitespacesAndNewlines))
        }

        return chunks.isEmpty ? [text] : chunks
    }

    // MARK: - Deep Normalization (filler word stripping)

    /// Common filler words and verbal tics that should be ignored in comparison.
    private static let fillerPatterns: Set<String> = [
        "um", "uh", "uh-huh", "mm-hmm", "mmm", "hmm", "hm",
        "like", "you know", "i mean", "right", "okay", "ok",
        "so", "well", "yeah", "yep", "yup", "nah",
        "actually", "basically", "literally", "honestly",
        "sort of", "kind of", "kinda", "sorta",
    ]

    /// Filler words as individual tokens for word-level removal.
    private static let fillerWords: Set<String> = [
        "um", "uh", "uh-huh", "mm-hmm", "mmm", "hmm", "hm",
        "like", "right", "okay", "ok", "so", "well",
        "yeah", "yep", "yup", "nah",
        "actually", "basically", "literally", "honestly",
        "kinda", "sorta",
    ]

    /// Deep normalization: strip filler words, punctuation, and normalize whitespace.
    static func deepNormalize(_ text: String) -> String {
        var result = text
            .lowercased()
            .replacingOccurrences(of: "[^a-z0-9\\s']", with: " ", options: .regularExpression)

        // Remove filler words (as whole words)
        for filler in fillerWords {
            result = result.replacingOccurrences(
                of: "\\b\(NSRegularExpression.escapedPattern(for: filler))\\b",
                with: " ",
                options: .regularExpression
            )
        }

        return result
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Sentence LCS Matching

    /// Align sentences between reference and candidate using LCS on normalized content.
    private static func sentenceLCSMatches(
        lhs: [String],
        rhs: [String]
    ) -> [(Int, Int)] {
        guard !lhs.isEmpty, !rhs.isEmpty else { return [] }

        let lhsNorm = lhs.map { deepNormalize($0) }
        let rhsNorm = rhs.map { deepNormalize($0) }

        let lhsCount = lhs.count
        let rhsCount = rhs.count

        // Use similarity threshold instead of exact match
        // This way "almost the same" sentences still align
        var table = Array(repeating: Array(repeating: 0, count: rhsCount + 1), count: lhsCount + 1)

        for i in 0..<lhsCount {
            for j in 0..<rhsCount {
                if sentenceSimilarity(lhsNorm[i], rhsNorm[j]) > 0.5 {
                    table[i + 1][j + 1] = table[i][j] + 1
                } else {
                    table[i + 1][j + 1] = max(table[i][j + 1], table[i + 1][j])
                }
            }
        }

        // Backtrack
        var matches: [(Int, Int)] = []
        var i = lhsCount
        var j = rhsCount

        while i > 0 && j > 0 {
            if sentenceSimilarity(lhsNorm[i - 1], rhsNorm[j - 1]) > 0.5 {
                matches.append((i - 1, j - 1))
                i -= 1
                j -= 1
            } else if table[i - 1][j] >= table[i][j - 1] {
                i -= 1
            } else {
                j -= 1
            }
        }

        return matches.reversed()
    }

    /// Word-level Jaccard similarity between two normalized sentences.
    private static func sentenceSimilarity(_ a: String, _ b: String) -> Double {
        let aWords = Set(a.split(whereSeparator: \.isWhitespace).map(String.init))
        let bWords = Set(b.split(whereSeparator: \.isWhitespace).map(String.init))

        guard !aWords.isEmpty || !bWords.isEmpty else { return 1.0 }

        let intersection = aWords.intersection(bWords).count
        let union = aWords.union(bWords).count
        return Double(intersection) / Double(max(1, union))
    }

    // MARK: - Time Estimation Helpers

    private static func estimatePosition(sentenceIndex: Int, sentences: [String], totalChars: Int) -> Double {
        let charsBefore = sentences.prefix(sentenceIndex).reduce(0) { $0 + $1.count }
        return Double(charsBefore) / Double(max(1, totalChars))
    }

    private static func estimateLength(sentence: String, totalChars: Int) -> Double {
        return Double(sentence.count) / Double(max(1, totalChars))
    }

    private static func estimatedSentenceRanges(
        sentences: [String],
        segments: [TranscriptionSegment],
        totalChars: Int
    ) -> [(start: TimeInterval, end: TimeInterval)] {
        guard !sentences.isEmpty else { return [] }

        let segmentStart = segments.map(\.start).min() ?? 0
        let segmentEnd = segments.map(\.end).max() ?? segmentStart
        let duration = max(0, segmentEnd - segmentStart)

        return sentences.enumerated().map { index, sentence in
            let start = segmentStart + duration * estimatePosition(
                sentenceIndex: index,
                sentences: sentences,
                totalChars: totalChars
            )
            let end = start + duration * estimateLength(sentence: sentence, totalChars: totalChars)
            return (start: start, end: max(start, end))
        }
    }

    private static func sentenceSourceSegments(
        _ segments: [TranscriptionSegment],
        start: TimeInterval,
        end: TimeInterval
    ) -> [TranscriptionSegment] {
        let overlapping = segments.filter { segment in
            max(segment.start, start) < min(segment.end, end)
        }

        if !overlapping.isEmpty {
            return overlapping
        }

        guard let nearest = segments.min(by: {
            segmentDistance($0, to: start, end: end) < segmentDistance($1, to: start, end: end)
        }) else {
            return []
        }

        return [nearest]
    }

    private static func segmentDistance(
        _ segment: TranscriptionSegment,
        to start: TimeInterval,
        end: TimeInterval
    ) -> TimeInterval {
        let targetMidpoint = (start + end) / 2
        let segmentMidpoint = (segment.start + segment.end) / 2
        return abs(segmentMidpoint - targetMidpoint)
    }

    // MARK: - Existing Helpers (unchanged)

    private static func buildGroups(
        reference: [TranscriptionSegment],
        candidate: [TranscriptionSegment]
    ) -> [SegmentGroup] {
        let orderedNodes = (
            reference.enumerated().map { SegmentNode.reference(index: $0.offset, segment: $0.element) } +
            candidate.enumerated().map { SegmentNode.candidate(index: $0.offset, segment: $0.element) }
        )
        .sorted { lhs, rhs in
            if lhs.start == rhs.start {
                return lhs.end < rhs.end
            }
            return lhs.start < rhs.start
        }

        var visitedReference = Set<Int>()
        var visitedCandidate = Set<Int>()
        var groups: [SegmentGroup] = []

        for node in orderedNodes {
            switch node {
            case .reference(let index, _) where visitedReference.contains(index):
                continue
            case .candidate(let index, _) where visitedCandidate.contains(index):
                continue
            default:
                break
            }

            var queue: [SegmentNode] = [node]
            var referenceSegments: [TranscriptionSegment] = []
            var candidateSegments: [TranscriptionSegment] = []

            while let current = queue.popLast() {
                switch current {
                case .reference(let index, let segment):
                    guard visitedReference.insert(index).inserted else { continue }
                    referenceSegments.append(segment)
                    for (candidateIndex, candidateSegment) in candidate.enumerated()
                    where !visitedCandidate.contains(candidateIndex) && overlaps(segment, candidateSegment) {
                        queue.append(.candidate(index: candidateIndex, segment: candidateSegment))
                    }
                case .candidate(let index, let segment):
                    guard visitedCandidate.insert(index).inserted else { continue }
                    candidateSegments.append(segment)
                    for (referenceIndex, referenceSegment) in reference.enumerated()
                    where !visitedReference.contains(referenceIndex) && overlaps(segment, referenceSegment) {
                        queue.append(.reference(index: referenceIndex, segment: referenceSegment))
                    }
                }
            }

            groups.append(
                SegmentGroup(
                    referenceSegments: referenceSegments.sorted { $0.start < $1.start },
                    candidateSegments: candidateSegments.sorted { $0.start < $1.start }
                )
            )
        }

        return groups.sorted { $0.start < $1.start }
    }

    private static func canonicalText(_ segments: [TranscriptionSegment]) -> String {
        ReconciliationSegmentSummary.joinedText(segments)
    }

    private static func score(_ segments: [TranscriptionSegment]) -> Float {
        guard !segments.isEmpty else { return -.greatestFiniteMagnitude }
        let weightedConfidence = weightedAverage(
            values: segments.map { $0.averageWordConfidence ?? 0.5 },
            weights: segments.map { max(0.01, Float($0.end - $0.start)) }
        )
        let diarizationBonus = (ReconciliationSegmentSummary.averageDiarizationQuality(segments) ?? 0.5) * 0.12
        let unknownPenalty: Float = ReconciliationSegmentSummary.primarySpeakerID(segments) == "UNKNOWN" ? -0.05 : 0
        return weightedConfidence + diarizationBonus + unknownPenalty
    }

    private static func weightedAverage(values: [Float], weights: [Float]) -> Float {
        let denominator = weights.reduce(Float.zero, +)
        guard denominator > 0 else { return 0 }
        let numerator = zip(values, weights).reduce(Float.zero) { $0 + ($1.0 * $1.1) }
        return numerator / denominator
    }

    private static func overlaps(_ lhs: TranscriptionSegment, _ rhs: TranscriptionSegment) -> Bool {
        max(lhs.start, rhs.start) < min(lhs.end, rhs.end)
    }

    private static func mergeConsecutiveSpeakerSegments(
        _ segments: [TranscriptionSegment],
        gapTolerance: TimeInterval = 0.5
    ) -> [TranscriptionSegment] {
        guard !segments.isEmpty else { return [] }
        var merged: [TranscriptionSegment] = []
        var accumulator = segments[0]

        for i in 1..<segments.count {
            let current = segments[i]
            let sameSpeaker = current.speakerID == accumulator.speakerID
            let closeInTime = (current.start - accumulator.end) < gapTolerance

            if sameSpeaker && closeInTime {
                let combinedText = [
                    accumulator.text.trimmingCharacters(in: .whitespacesAndNewlines),
                    current.text.trimmingCharacters(in: .whitespacesAndNewlines)
                ].filter { !$0.isEmpty }.joined(separator: " ")

                let combinedWords: [TranscriptionSegment.WordTiming]?
                if let accWords = accumulator.words, let curWords = current.words {
                    combinedWords = accWords + curWords
                } else {
                    combinedWords = accumulator.words ?? current.words
                }

                accumulator = TranscriptionSegment(
                    speakerID: accumulator.speakerID,
                    start: accumulator.start,
                    end: current.end,
                    text: combinedText,
                    words: combinedWords,
                    averageLogProb: averagePair(accumulator.averageLogProb, current.averageLogProb),
                    noSpeechProb: averagePair(accumulator.noSpeechProb, current.noSpeechProb),
                    decodingTemperature: averagePair(accumulator.decodingTemperature, current.decodingTemperature),
                    compressionRatio: averagePair(accumulator.compressionRatio, current.compressionRatio),
                    diarizationQuality: averagePair(accumulator.diarizationQuality, current.diarizationQuality),
                    diarizationOverlap: maxDoublePair(accumulator.diarizationOverlap, current.diarizationOverlap)
                )
            } else {
                merged.append(accumulator)
                accumulator = current
            }
        }
        merged.append(accumulator)
        return merged
    }

    private static func averagePair(_ a: Float?, _ b: Float?) -> Float? {
        switch (a, b) {
        case let (a?, b?): return (a + b) / 2.0
        case let (a?, nil): return a
        case let (nil, b?): return b
        case (nil, nil): return nil
        }
    }

    private static func maxDoublePair(_ a: TimeInterval?, _ b: TimeInterval?) -> TimeInterval? {
        switch (a, b) {
        case let (a?, b?): return max(a, b)
        case let (a?, nil): return a
        case let (nil, b?): return b
        case (nil, nil): return nil
        }
    }
}

private struct SegmentGroup: Sendable {
    let referenceSegments: [TranscriptionSegment]
    let candidateSegments: [TranscriptionSegment]

    var start: TimeInterval {
        (referenceSegments + candidateSegments).map(\.start).min() ?? 0
    }

    var end: TimeInterval {
        (referenceSegments + candidateSegments).map(\.end).max() ?? start
    }
}

private enum SegmentNode: Sendable {
    case reference(index: Int, segment: TranscriptionSegment)
    case candidate(index: Int, segment: TranscriptionSegment)

    var start: TimeInterval {
        switch self {
        case .reference(_, let segment), .candidate(_, let segment):
            return segment.start
        }
    }

    var end: TimeInterval {
        switch self {
        case .reference(_, let segment), .candidate(_, let segment):
            return segment.end
        }
    }
}
