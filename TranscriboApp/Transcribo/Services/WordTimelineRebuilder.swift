import Foundation

/// Applies a forced-alignment pass's output to a `MergedTranscript`, overwriting
/// per-word timings in place.
///
/// This is the glue between `ForcedAlignmentService` (which produces raw
/// aligned words from audio + text) and the reconciliation UI model (which
/// carries speaker, provenance, and flag metadata on every word).
///
/// The rebuilder is deliberately *additive*: it only overwrites `.start` and
/// `.end` on existing `MergedWord` instances. Text, speaker, provenance, and
/// flag ranges are preserved exactly. If the aligner produces more or fewer
/// tokens than the merged word stream, unmatched merged words keep their
/// original timings — the pass is best-effort.
enum WordTimelineRebuilder {

    // MARK: - Configuration

    /// When searching for an aligned-word match for a given merged word, don't
    /// look further than this many seconds from the merged word's midpoint.
    /// This bounds the greedy matcher's reach; larger windows cost linear
    /// scan time per word but survive noisier ASR timings.
    private static let searchWindow: TimeInterval = 3.0

    /// Text similarity bonus when the normalized word strings match.
    /// Same convention as `ConfidenceMergeService`.
    private static let textMatchScore: Float = 1.0

    // MARK: - Public API

    /// Apply aligned words to a merged transcript.
    ///
    /// - Parameters:
    ///   - merged: The transcript whose word timings should be rebuilt.
    ///   - alignedWords: Output of a `ForcedAlignmentService.align(...)` call
    ///     over the merged transcript's full text.
    ///   - alignerLabel: Human-readable aligner name (e.g. "Qwen3-ForcedAligner")
    ///     recorded on the returned transcript.
    /// - Returns: The updated transcript plus a `ForcedAlignmentDelta`
    ///   summarizing how much timings moved.
    static func apply(
        to merged: MergedTranscript,
        alignedWords: [AlignedWordTiming],
        alignerLabel: String
    ) -> (transcript: MergedTranscript, delta: ForcedAlignmentDelta) {
        guard !alignedWords.isEmpty else {
            return (merged, ForcedAlignmentDelta(
                wordsAligned: 0,
                wordsUnmatched: merged.segments.reduce(0) { $0 + $1.words.count },
                meanStartDelta: 0,
                maxStartDelta: 0,
                meanDurationDelta: 0
            ))
        }

        // Flatten the merged word stream while remembering where each word
        // lives in the segment structure, so we can write back in place.
        struct Cursor {
            let segmentIndex: Int
            let wordIndex: Int
        }
        var cursors: [Cursor] = []
        var mergedWords: [MergedWord] = []
        for (segIdx, segment) in merged.segments.enumerated() {
            for (wIdx, word) in segment.words.enumerated() {
                cursors.append(Cursor(segmentIndex: segIdx, wordIndex: wIdx))
                mergedWords.append(word)
            }
        }

        // Greedy match: walk both streams forward, advancing whichever is
        // behind in time, preferring exact-normalized text matches.
        var alignedCursor = 0
        var deltas: [TimeInterval] = []
        var durationDeltas: [TimeInterval] = []
        var matchedCount = 0
        var updatedMergedWords = mergedWords

        for mIdx in 0..<mergedWords.count {
            let mWord = mergedWords[mIdx]
            let mMid = TimeInterval((mWord.start + mWord.end) / 2.0)
            let normalizedMergedText = normalize(mWord.word)

            // Advance past aligned words that are far in the past.
            while alignedCursor < alignedWords.count,
                  alignedWords[alignedCursor].end < TimeInterval(mWord.start) - searchWindow {
                alignedCursor += 1
            }

            // Scan the next few aligned words; pick the best score.
            var bestIdx: Int?
            var bestScore: Float = -1
            var scanIdx = alignedCursor
            while scanIdx < alignedWords.count {
                let aWord = alignedWords[scanIdx]
                if aWord.start > TimeInterval(mWord.end) + searchWindow { break }

                let score = matchScore(
                    mergedText: normalizedMergedText,
                    mergedMidpoint: mMid,
                    aligned: aWord
                )
                if score > bestScore {
                    bestScore = score
                    bestIdx = scanIdx
                }
                scanIdx += 1
            }

            // Require a positive score to accept the match.
            guard let bestIdx, bestScore > 0 else { continue }

            let chosen = alignedWords[bestIdx]
            let newStart = Float(chosen.start)
            let newEnd = Float(chosen.end)

            deltas.append(abs(TimeInterval(newStart - mWord.start)))
            let oldDuration = TimeInterval(mWord.end - mWord.start)
            let newDuration = TimeInterval(newEnd - newStart)
            durationDeltas.append(abs(newDuration - oldDuration))

            let updated = MergedWord(
                id: mWord.id,
                word: mWord.word,
                start: newStart,
                end: newEnd,
                confidence: mWord.confidence,
                source: mWord.source,
                speakerID: mWord.speakerID
            )
            updatedMergedWords[mIdx] = updated
            matchedCount += 1

            // Prefer not to re-match the same aligned word: advance the cursor
            // past it so the next merged word starts from here. This is a
            // simplification; true optimal matching would use Hungarian, but
            // greedy is robust for 95%+ cases and an order of magnitude cheaper.
            alignedCursor = bestIdx + 1
        }

        // Write updated words back into segments.
        var newSegments = merged.segments
        for (flatIdx, cursor) in cursors.enumerated() {
            newSegments[cursor.segmentIndex].words[cursor.wordIndex] = updatedMergedWords[flatIdx]
        }

        var updated = merged
        updated.segments = newSegments
        updated.wordTimingsRefined = true
        updated.wordTimingsAlignerLabel = alignerLabel
        updated.updatedAt = Date()

        let delta = ForcedAlignmentDelta(
            wordsAligned: matchedCount,
            wordsUnmatched: mergedWords.count - matchedCount,
            meanStartDelta: deltas.isEmpty ? 0 : deltas.reduce(0, +) / Double(deltas.count),
            maxStartDelta: deltas.max() ?? 0,
            meanDurationDelta: durationDeltas.isEmpty ? 0 : durationDeltas.reduce(0, +) / Double(durationDeltas.count)
        )
        return (updated, delta)
    }

    // MARK: - Helpers

    /// Build the text blob to feed to the aligner. Whitespace-normalized,
    /// preserves punctuation (aligners generally handle it better than stripped).
    static func buildTextForAlignment(_ merged: MergedTranscript) -> String {
        merged.segments
            .map { segment in
                segment.words
                    .map(\.word)
                    .joined(separator: " ")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    /// Total word count across all segments — useful as `hintedWordCount`.
    static func totalWordCount(_ merged: MergedTranscript) -> Int {
        merged.segments.reduce(0) { $0 + $1.words.count }
    }

    // MARK: - Private scoring

    private static func matchScore(
        mergedText: String,
        mergedMidpoint: TimeInterval,
        aligned: AlignedWordTiming
    ) -> Float {
        let alignedMid = (aligned.start + aligned.end) / 2.0
        let distance = abs(mergedMidpoint - alignedMid)
        guard distance <= searchWindow else { return -1 }

        // Time proximity score: 1 at zero distance, 0 at searchWindow.
        let timeScore = Float(max(0, 1 - distance / searchWindow))

        // Text similarity bonus.
        let textScore: Float = normalize(aligned.text) == mergedText ? textMatchScore : 0

        return timeScore + textScore
    }

    private static func normalize(_ word: String) -> String {
        word.lowercased()
            .replacingOccurrences(of: "[^a-z0-9']", with: "", options: .regularExpression)
    }
}
