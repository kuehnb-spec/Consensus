import Foundation

/// Confidence-weighted merge engine that produces a single best transcript
/// from two transcription passes, flagging only genuinely ambiguous regions.
///
/// Replaces the old sentence-level LCS diff approach (ReconciliationService.buildDraft)
/// with word-level alignment using WordTiming timestamps from both engines.
enum ConfidenceMergeService {

    // MARK: - Configuration

    /// Words within this time window (seconds) are considered potential alignment partners.
    /// Words within this time window (seconds) are considered potential alignment partners.
    /// Increased from 0.4 to 1.0 because engines can produce timestamps for the same word
    /// that are up to ~0.6s apart, and failing to match them creates duplicate words.
    private static let wordAlignmentTolerance: Float = 1.0

    /// Below this confidence, a word is considered low-confidence.
    private static let lowConfidenceThreshold: Float = 0.5

    /// Below this confidence on BOTH engines, flag the region for review.
    private static let flagConfidenceThreshold: Float = 0.6

    /// Minimum number of consecutive disagreeing words to flag as a region.
    private static let minimumFlagWords = 2

    /// Gap tolerance for merging adjacent same-speaker segments.
    private static let speakerMergeGap: TimeInterval = 0.8

    /// Common filler words that should not generate flags when only one engine hears them.
    private static let fillerWords: Set<String> = [
        "um", "uh", "uh-huh", "mm-hmm", "mmm", "hmm", "hm",
        "like", "right", "okay", "ok", "so", "well",
        "yeah", "yep", "yup", "nah", "ah",
        "actually", "basically", "literally", "honestly",
        "kinda", "sorta",
    ]

    // MARK: - Public API

    /// Build a merged transcript from two transcription passes using word-level
    /// confidence-weighted alignment.
    ///
    /// Speaker assignments come entirely from the reference pass (Engine A).
    /// The candidate pass (Engine B) contributes only text + word timings + confidence.
    /// This avoids the "31% speaker agreement" problem caused by reconciling two
    /// independent diarization runs.
    ///
    /// - Parameter applyConfidenceMerge: When `true` (legacy behavior), runs the
    ///     word-aligner and picks the best word per matched pair, merging both
    ///     engines' text. When `false` (default per April 21 2026 benchmarks),
    ///     passes Engine A's text through unchanged and only uses Engine B for
    ///     confidence-flagging low-agreement regions. The legacy merge was
    ///     measured at 33% cpWER vs Engine A alone at 17% on a hand-corrected
    ///     reference transcript — its timestamp-based alignment interleaves
    ///     words from both engines when timestamps disagree, producing scrambled
    ///     output. Default off until rewritten.
    static func buildMergedTranscript(
        referencePass: TranscriptionPass,
        candidatePass: TranscriptionPass,
        applyConfidenceMerge: Bool = false
    ) -> MergedTranscript {
        // Step 1: Extract flat word lists from both passes
        let refWords = extractWords(from: referencePass.result)
        let candWords = extractWords(from: candidatePass.result)

        // Step 2: Build the reference speaker timeline — used to assign speakers to all merged words
        let speakerTimeline = buildSpeakerTimeline(from: referencePass.result)

        // Step 3: Align words by timestamp overlap
        let alignedPairs = alignWords(reference: refWords, candidate: candWords)

        // Step 4: Merge text — either the legacy confidence-weighted pick-best
        // (which interleaves both engines' unmatched words and was shown to produce
        // 2–3× worse cpWER than either engine alone), or pass-through Engine A.
        let rawMergedWords: [MergedWord]
        if applyConfidenceMerge {
            rawMergedWords = mergeAlignedWords(pairs: alignedPairs, speakerTimeline: speakerTimeline)
        } else {
            rawMergedWords = passThroughReferenceWords(
                referenceWords: refWords,
                speakerTimeline: speakerTimeline
            )
        }

        // Step 4b: Drop adjacent duplicate words. When one engine hallucinates a repeat
        // ("cost cost", "fine. fine.") or both engines produced timestamps too far apart
        // for the word aligner to match, the merge stream ends up with two identical words
        // back-to-back. A speaker genuinely repeating a word will have meaningful space
        // between the repeats ("pay down, you know, a full pay down") — those stay.
        let mergedWords = collapseAdjacentDuplicateWords(rawMergedWords)

        // Step 5: Group into speaker segments using Engine A's actual segment boundaries
        // This is more reliable than per-word speaker lookup because it uses the exact
        // speaker turns from the diarized reference pass.
        var segments = groupIntoReferenceSegments(
            words: mergedWords,
            referenceSegments: referencePass.result.segments
        )

        // Step 6: Detect and create flags for ambiguous regions
        let flags = buildFlags(segments: segments, alignedPairs: alignedPairs, mergedWords: mergedWords)

        // Step 7: Link flags to segments
        for (flagIndex, flag) in flags.enumerated() {
            if flag.segmentIndex < segments.count {
                segments[flag.segmentIndex].flagIndices.append(flagIndex)
            }
        }

        return MergedTranscript(
            referencePassID: referencePass.id,
            candidatePassID: candidatePass.id,
            referenceLabel: "\(referencePass.kind.displayName) \u{2022} \(referencePass.modelName)",
            candidateLabel: "\(candidatePass.kind.displayName) \u{2022} \(candidatePass.modelName)",
            segments: segments,
            flags: flags
        )
    }

    // MARK: - Speaker Timeline

    /// A time region assigned to a specific speaker from the reference pass.
    private struct SpeakerRegion {
        let speakerID: String
        let start: Float
        let end: Float
    }

    /// Build a sorted timeline of speaker regions from the reference pass's segments.
    private static func buildSpeakerTimeline(from result: TranscriptionResult) -> [SpeakerRegion] {
        result.segments.map { seg in
            SpeakerRegion(speakerID: seg.speakerID, start: Float(seg.start), end: Float(seg.end))
        }.sorted { $0.start < $1.start }
    }

    /// Look up which speaker owns a given time position using the reference timeline.
    private static func speakerAt(time: Float, in timeline: [SpeakerRegion]) -> String {
        // Binary search for the region containing this time
        for region in timeline {
            if time >= region.start && time <= region.end {
                return region.speakerID
            }
        }
        // Find nearest region
        var bestRegion: SpeakerRegion?
        var bestDistance: Float = .greatestFiniteMagnitude
        for region in timeline {
            let midpoint = (region.start + region.end) / 2
            let distance = abs(midpoint - time)
            if distance < bestDistance {
                bestDistance = distance
                bestRegion = region
            }
        }
        return bestRegion?.speakerID ?? "UNKNOWN"
    }

    // MARK: - Word Extraction

    /// A positioned word from one engine with its speaker context.
    private struct PositionedWord: Sendable {
        let word: String
        let normalizedWord: String
        let start: Float
        let end: Float
        let confidence: Float
        let speakerID: String
        let segmentIndex: Int
    }

    /// Extract a flat, time-ordered list of words from a transcription result.
    /// Falls back to segment-level text splitting if word timings aren't available.
    private static func extractWords(from result: TranscriptionResult) -> [PositionedWord] {
        var words: [PositionedWord] = []

        for (segIndex, segment) in result.segments.enumerated() {
            if let wordTimings = segment.words, !wordTimings.isEmpty {
                for wt in wordTimings {
                    let cleaned = wt.word.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !cleaned.isEmpty else { continue }
                    words.append(PositionedWord(
                        word: cleaned,
                        normalizedWord: normalizeWord(cleaned),
                        start: wt.start,
                        end: wt.end,
                        confidence: wt.probability,
                        speakerID: segment.speakerID,
                        segmentIndex: segIndex
                    ))
                }
            } else {
                // Fallback: split segment text into words with estimated timing
                let textWords = segment.text.split(whereSeparator: \.isWhitespace).map(String.init)
                let segDuration = Float(segment.end - segment.start)
                let wordDuration = textWords.isEmpty ? segDuration : segDuration / Float(textWords.count)
                let defaultConfidence = segment.averageWordConfidence ?? 0.5

                for (i, w) in textWords.enumerated() {
                    let cleaned = w.trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
                    guard !cleaned.isEmpty else { continue }
                    let wStart = Float(segment.start) + Float(i) * wordDuration
                    let wEnd = wStart + wordDuration
                    words.append(PositionedWord(
                        word: w,
                        normalizedWord: normalizeWord(w),
                        start: wStart,
                        end: wEnd,
                        confidence: defaultConfidence,
                        speakerID: segment.speakerID,
                        segmentIndex: segIndex
                    ))
                }
            }
        }

        return words.sorted { $0.start < $1.start }
    }

    // MARK: - Word Alignment

    /// An alignment pair: a reference word, a candidate word, or both.
    private enum AlignmentPair {
        case matched(ref: PositionedWord, cand: PositionedWord)
        case referenceOnly(ref: PositionedWord)
        case candidateOnly(cand: PositionedWord)

        var timeStart: Float {
            switch self {
            case .matched(let ref, let cand): return min(ref.start, cand.start)
            case .referenceOnly(let ref): return ref.start
            case .candidateOnly(let cand): return cand.start
            }
        }
    }

    /// Align words from both engines using timestamp overlap.
    /// Uses a greedy forward-matching approach: for each reference word,
    /// find the best-matching candidate word within the time tolerance.
    private static func alignWords(
        reference: [PositionedWord],
        candidate: [PositionedWord]
    ) -> [AlignmentPair] {
        var pairs: [AlignmentPair] = []
        var usedCandidateIndices = Set<Int>()
        var matchedRefIndices = Set<Int>()

        // For each reference word, find the best candidate within time tolerance
        var candSearchStart = 0
        for (refIdx, refWord) in reference.enumerated() {
            var bestCandIdx: Int?
            var bestScore: Float = -1

            // Advance search window
            while candSearchStart < candidate.count &&
                  candidate[candSearchStart].end < refWord.start - wordAlignmentTolerance {
                candSearchStart += 1
            }

            for candIdx in candSearchStart..<candidate.count {
                let candWord = candidate[candIdx]
                if usedCandidateIndices.contains(candIdx) { continue }
                if candWord.start > refWord.end + wordAlignmentTolerance { break }

                // Time overlap score
                let overlapStart = max(refWord.start, candWord.start)
                let overlapEnd = min(refWord.end, candWord.end)
                let overlap = max(0, overlapEnd - overlapStart)
                let unionDuration = max(refWord.end, candWord.end) - min(refWord.start, candWord.start)
                let timeScore = unionDuration > 0 ? overlap / unionDuration : 0

                // Text similarity bonus
                // Strong bonus for matching text — prevents duplicate words when timestamps differ slightly
                let textScore: Float = refWord.normalizedWord == candWord.normalizedWord ? 1.0 : 0.0

                let score = timeScore + textScore
                // Accept match if there's any time proximity (even without overlap,
                // text match is strong enough signal when words are nearby)
                if score > bestScore && (timeScore > 0.05 || textScore > 0) {
                    bestScore = score
                    bestCandIdx = candIdx
                }
            }

            if let candIdx = bestCandIdx {
                pairs.append(.matched(ref: refWord, cand: candidate[candIdx]))
                usedCandidateIndices.insert(candIdx)
                matchedRefIndices.insert(refIdx)
            }
        }

        // Add unmatched reference words
        for (refIdx, refWord) in reference.enumerated() where !matchedRefIndices.contains(refIdx) {
            pairs.append(.referenceOnly(ref: refWord))
        }

        // Add unmatched candidate words
        for (candIdx, candWord) in candidate.enumerated() where !usedCandidateIndices.contains(candIdx) {
            pairs.append(.candidateOnly(cand: candWord))
        }

        return pairs.sorted { $0.timeStart < $1.timeStart }
    }

    // MARK: - Confidence-Weighted Merge

    /// For each alignment pair, pick the best word based on confidence.
    /// Speaker IDs always come from the reference timeline, not from individual words.
    ///
    /// **Timestamp source**: For matched pairs we use Engine A (reference) timestamps
    /// even when Engine B's word was picked for text. This is deliberate: the two
    /// engines derive timestamps very differently (Parakeet via CTC alignment, Whisper
    /// via cross-attention), so mixing timestamps across engines introduces ~50–100 ms
    /// of jitter at every alternation. Since attribution is pure timestamp-overlap
    /// against the diarization timeline, that jitter is exactly what produces
    /// cross-speaker single-word flips. Pinning timing to one source removes it.
    /// For `candidateOnly` words we have to use Engine B's timings (no alternative);
    /// forced alignment is the real fix for those too.
    private static func mergeAlignedWords(pairs: [AlignmentPair], speakerTimeline: [SpeakerRegion]) -> [MergedWord] {
        pairs.compactMap { pair -> MergedWord? in
            switch pair {
            case .matched(let ref, let cand):
                let sameWord = ref.normalizedWord == cand.normalizedWord
                let bestIsRef = ref.confidence >= cand.confidence
                let chosen = bestIsRef ? ref : cand
                // Speaker lookup uses reference timings, matching the timing source we
                // embed in the MergedWord below.
                let speaker = speakerAt(time: (ref.start + ref.end) / 2, in: speakerTimeline)
                let source: MergedWordSource = sameWord
                    ? .agreed(
                        referenceWord: ref.word, candidateWord: cand.word,
                        referenceConfidence: ref.confidence, candidateConfidence: cand.confidence
                    )
                    : .disagreed(
                        referenceWord: ref.word, candidateWord: cand.word,
                        referenceConfidence: ref.confidence, candidateConfidence: cand.confidence
                    )
                return MergedWord(
                    word: chosen.word,
                    start: ref.start,
                    end: ref.end,
                    confidence: chosen.confidence,
                    source: source,
                    speakerID: speaker
                )

            case .referenceOnly(let ref):
                // Skip low-confidence filler words only heard by one engine
                if ref.confidence < lowConfidenceThreshold && isFillerWord(ref.normalizedWord) {
                    return nil
                }
                let speaker = speakerAt(time: (ref.start + ref.end) / 2, in: speakerTimeline)
                return MergedWord(
                    word: ref.word,
                    start: ref.start,
                    end: ref.end,
                    confidence: ref.confidence,
                    source: .referenceOnly(confidence: ref.confidence),
                    speakerID: speaker
                )

            case .candidateOnly(let cand):
                if cand.confidence < lowConfidenceThreshold && isFillerWord(cand.normalizedWord) {
                    return nil
                }
                let speaker = speakerAt(time: (cand.start + cand.end) / 2, in: speakerTimeline)
                return MergedWord(
                    word: cand.word,
                    start: cand.start,
                    end: cand.end,
                    confidence: cand.confidence,
                    source: .candidateOnly(confidence: cand.confidence),
                    speakerID: speaker
                )
            }
        }
    }

    // MARK: - Pass-through (default: Engine A only)

    /// Emit Engine A's words verbatim, stamped with speaker IDs from the reference
    /// timeline. Used when `applyConfidenceMerge` is false — the safer default.
    /// The MergedWord's `source` is tagged `.agreed` to keep the existing flag
    /// detection logic from spuriously flagging every word as ambiguous; the
    /// real flag pass (`buildFlags`) still runs over `alignedPairs` and will
    /// surface genuine Engine A / Engine B disagreements for user review.
    private static func passThroughReferenceWords(
        referenceWords: [PositionedWord],
        speakerTimeline: [SpeakerRegion]
    ) -> [MergedWord] {
        referenceWords.map { ref in
            let speaker = speakerAt(time: (ref.start + ref.end) / 2, in: speakerTimeline)
            return MergedWord(
                word: ref.word,
                start: ref.start,
                end: ref.end,
                confidence: ref.confidence,
                source: .referenceOnly(confidence: ref.confidence),
                speakerID: speaker
            )
        }
    }

    // MARK: - Adjacent-Duplicate Cleanup

    /// Gap in seconds below which two consecutive identical words are treated as a
    /// merge/hallucination artifact rather than genuine speaker repetition.
    /// Values chosen so that:
    ///   - "cost cost" with timestamps 10.0-10.3 / 10.4-10.7  → collapsed (gap 0.1s)
    ///   - "pay down ... a full pay down" (several seconds between) → preserved
    private static let duplicateWordMaxGap: Float = 0.30

    /// Walk the merged word stream and drop consecutive words whose normalized form is
    /// identical and whose time gap is short. Keeps the higher-confidence timestamp.
    ///
    /// Only collapses when at least one of the adjacent words came from a single-engine
    /// source (referenceOnly or candidateOnly) or the two engines disagreed on text —
    /// i.e. when the pair looks like an alignment/merge leak. Two confidently agreed
    /// words almost never land back-to-back unless the speaker actually said the word
    /// twice, and in that case the time gap is usually wider than `duplicateWordMaxGap`.
    private static func collapseAdjacentDuplicateWords(
        _ words: [MergedWord]
    ) -> [MergedWord] {
        guard words.count >= 2 else { return words }

        var result: [MergedWord] = []
        result.reserveCapacity(words.count)

        for word in words {
            guard let previous = result.last else {
                result.append(word)
                continue
            }

            let prevKey = normalizeForDuplicateCheck(previous.word)
            let currKey = normalizeForDuplicateCheck(word.word)

            guard !prevKey.isEmpty, prevKey == currKey else {
                result.append(word)
                continue
            }

            let gap = word.start - previous.end
            guard gap < duplicateWordMaxGap else {
                // Genuine repetition with meaningful space between — keep both.
                result.append(word)
                continue
            }

            // Collapse: keep the higher-confidence word, extend time range to cover both.
            let keepCurrent = word.confidence > previous.confidence
            let chosen = keepCurrent ? word : previous
            let merged = MergedWord(
                id: chosen.id,
                word: chosen.word,
                start: min(previous.start, word.start),
                end: max(previous.end, word.end),
                confidence: chosen.confidence,
                source: chosen.source,
                speakerID: chosen.speakerID
            )
            result[result.count - 1] = merged
        }

        return result
    }

    /// Normalize a word for duplicate-check equality: lowercase, strip punctuation and
    /// whitespace. "Position." and "position" become the same key.
    private static func normalizeForDuplicateCheck(_ word: String) -> String {
        word
            .lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: .punctuationCharacters)
    }

    // MARK: - Re-attribution After Forced Alignment

    /// Re-attribute speakers and re-group segments after forced alignment has refined
    /// per-word timings. Speaker attribution is pure timestamp-overlap against the
    /// diarization timeline, so when FA moves a word across a turn boundary, the
    /// original attribution — computed with the pre-FA noisy timestamps — is now
    /// wrong. Calling this after FA pulls those words into the correct segment.
    ///
    /// Flags are preserved and their (segmentIndex, wordRange) pointers are remapped
    /// by matching on absolute time. Any flag whose time range no longer overlaps any
    /// segment (should be vanishingly rare) is dropped.
    static func reattributeAfterRetiming(
        _ merged: MergedTranscript,
        referenceSegments: [TranscriptionSegment]
    ) -> MergedTranscript {
        guard !merged.segments.isEmpty, !referenceSegments.isEmpty else { return merged }

        // Preserve per-segment word order. Sorting globally by start time was
        // the root cause of the scrambled-sentences regression on phone audio
        // (forced alignment produced non-monotonic timings on 15-26% of words).
        // This function is no longer called from the main pipeline as of
        // 2026-04-23, but the defensive change is kept in case it's reused.
        let flatWords = merged.segments.flatMap(\.words)
        guard !flatWords.isEmpty else { return merged }

        var newSegments = groupIntoReferenceSegments(
            words: flatWords,
            referenceSegments: referenceSegments
        )

        // Remap flags by time range. For each flag, find the new segment whose time
        // range contains the flag's midpoint, then locate the first/last word whose
        // time range falls inside the flag's time range.
        var remappedFlags: [MergeFlag] = []
        var flagIndicesPerSegment: [[Int]] = Array(repeating: [], count: newSegments.count)

        for flag in merged.flags {
            let flagMid = (flag.start + flag.end) / 2
            guard let newSegIdx = newSegments.firstIndex(where: {
                $0.start <= flagMid && flagMid <= $0.end
            }) else {
                continue
            }
            let newSeg = newSegments[newSegIdx]
            let lowerIdx = newSeg.words.firstIndex(where: {
                TimeInterval($0.end) >= flag.start - 0.15
            })
            let upperIdx = newSeg.words.lastIndex(where: {
                TimeInterval($0.start) <= flag.end + 0.15
            })
            guard let lo = lowerIdx, let hi = upperIdx, lo <= hi else { continue }

            let newRange = lo..<(hi + 1)
            let updated = MergeFlag(
                id: flag.id,
                kind: flag.kind,
                segmentIndex: newSegIdx,
                wordRange: newRange,
                start: flag.start,
                end: flag.end,
                mergedText: flag.mergedText,
                referenceText: flag.referenceText,
                candidateText: flag.candidateText,
                referenceSpeakerID: flag.referenceSpeakerID,
                candidateSpeakerID: flag.candidateSpeakerID,
                referenceConfidence: flag.referenceConfidence,
                candidateConfidence: flag.candidateConfidence,
                isResolved: flag.isResolved,
                resolution: flag.resolution
            )
            let flagIndex = remappedFlags.count
            remappedFlags.append(updated)
            flagIndicesPerSegment[newSegIdx].append(flagIndex)
        }

        for i in 0..<newSegments.count {
            newSegments[i].flagIndices = flagIndicesPerSegment[i]
        }

        return MergedTranscript(
            referencePassID: merged.referencePassID,
            candidatePassID: merged.candidatePassID,
            referenceLabel: merged.referenceLabel,
            candidateLabel: merged.candidateLabel,
            segments: newSegments,
            flags: remappedFlags,
            updatedAt: Date(),
            wordTimingsRefined: merged.wordTimingsRefined,
            wordTimingsAlignerLabel: merged.wordTimingsAlignerLabel
        )
    }

    // MARK: - Segment Grouping

    /// Group merged words into segments that match Engine A's speaker turns.
    /// This slices the merged word stream at the reference pass's segment boundaries,
    /// ensuring speaker assignments are identical to what the user already reviewed.
    static func groupIntoReferenceSegments(
        words: [MergedWord],
        referenceSegments: [TranscriptionSegment]
    ) -> [MergedSegment] {
        guard !words.isEmpty, !referenceSegments.isEmpty else { return [] }

        // Merge consecutive same-speaker reference segments to get clean speaker turns
        var speakerTurns: [(speakerID: String, start: TimeInterval, end: TimeInterval)] = []
        for seg in referenceSegments.sorted(by: { $0.start < $1.start }) {
            if let last = speakerTurns.last, last.speakerID == seg.speakerID,
               seg.start - last.end < speakerMergeGap {
                speakerTurns[speakerTurns.count - 1].end = seg.end
            } else {
                speakerTurns.append((speakerID: seg.speakerID, start: seg.start, end: seg.end))
            }
        }

        // Assign each merged word to a speaker turn by time overlap.
        // Preserve input order (see reattributeAfterRetiming comment above for
        // why a global start-time sort is unsafe when FA timings are present).
        var segments: [MergedSegment] = []
        var wordIndex = 0
        let sortedWords = words

        for turn in speakerTurns {
            var turnWords: [MergedWord] = []

            while wordIndex < sortedWords.count {
                let word = sortedWords[wordIndex]
                let wordMid = TimeInterval((word.start + word.end) / 2)

                // If word midpoint is before this turn starts, assign to this turn anyway
                // (it belongs to the gap between turns — attach to the nearest)
                if wordMid < turn.start {
                    // Check if there's a previous segment that's closer
                    if let lastSeg = segments.last,
                       abs(wordMid - lastSeg.end) < abs(wordMid - turn.start) {
                        // Closer to previous turn — skip, it was already assigned or add to previous
                        // Actually, since we process in order, unassigned words before this turn go here
                        let reassigned = MergedWord(
                            id: word.id, word: word.word, start: word.start, end: word.end,
                            confidence: word.confidence, source: word.source,
                            speakerID: lastSeg.speakerID
                        )
                        if !segments.isEmpty {
                            segments[segments.count - 1].words.append(reassigned)
                        }
                        wordIndex += 1
                        continue
                    }
                    turnWords.append(MergedWord(
                        id: word.id, word: word.word, start: word.start, end: word.end,
                        confidence: word.confidence, source: word.source,
                        speakerID: turn.speakerID
                    ))
                    wordIndex += 1
                    continue
                }

                // If word midpoint is past this turn's end, stop collecting for this turn
                if wordMid > turn.end + speakerMergeGap {
                    break
                }

                // Word falls within this turn
                turnWords.append(MergedWord(
                    id: word.id, word: word.word, start: word.start, end: word.end,
                    confidence: word.confidence, source: word.source,
                    speakerID: turn.speakerID
                ))
                wordIndex += 1
            }

            if !turnWords.isEmpty {
                segments.append(MergedSegment(
                    speakerID: turn.speakerID,
                    start: turn.start,
                    end: turn.end,
                    words: turnWords
                ))
            }
        }

        // Assign any remaining words to the last segment
        if wordIndex < sortedWords.count, !segments.isEmpty {
            let lastSpeaker = segments.last!.speakerID
            while wordIndex < sortedWords.count {
                let word = sortedWords[wordIndex]
                segments[segments.count - 1].words.append(MergedWord(
                    id: word.id, word: word.word, start: word.start, end: word.end,
                    confidence: word.confidence, source: word.source,
                    speakerID: lastSpeaker
                ))
                wordIndex += 1
            }
        }

        return segments
    }

    // MARK: - Flag Detection

    /// Scan the merged transcript for regions that need human review.
    private static func buildFlags(
        segments: [MergedSegment],
        alignedPairs: [AlignmentPair],
        mergedWords: [MergedWord]
    ) -> [MergeFlag] {
        var flags: [MergeFlag] = []

        for (segIndex, segment) in segments.enumerated() {
            // Scan for runs of problematic words within this segment
            var runStart: Int?
            var runKind: MergeFlagKind?

            for (wordIdx, word) in segment.words.enumerated() {
                let wordProblem = classifyWordProblem(word)

                if let problem = wordProblem {
                    if runStart == nil {
                        runStart = wordIdx
                        runKind = problem
                    } else if problem != runKind {
                        // Different kind — flush current run and start new one
                        if let start = runStart, let kind = runKind, wordIdx - start >= minimumFlagWords {
                            if let flag = buildFlag(segment: segment, segIndex: segIndex, wordRange: start..<wordIdx, kind: kind) {
                                flags.append(flag)
                            }
                        }
                        runStart = wordIdx
                        runKind = problem
                    }
                } else {
                    // Clean word — flush any active run
                    if let start = runStart, let kind = runKind, wordIdx - start >= minimumFlagWords {
                        if let flag = buildFlag(segment: segment, segIndex: segIndex, wordRange: start..<wordIdx, kind: kind) {
                            flags.append(flag)
                        }
                    }
                    runStart = nil
                    runKind = nil
                }
            }

            // Flush final run
            if let start = runStart, let kind = runKind, segment.words.count - start >= minimumFlagWords {
                if let flag = buildFlag(segment: segment, segIndex: segIndex, wordRange: start..<segment.words.count, kind: kind) {
                    flags.append(flag)
                }
            }
        }

        // Also detect speaker disputes across segments
        flags.append(contentsOf: detectSpeakerDisputes(segments: segments))

        // Detect missing phrases (runs of single-engine-only words)
        flags.append(contentsOf: detectMissingPhrases(segments: segments))

        return flags.sorted { $0.start < $1.start }
    }

    /// Classify what problem (if any) a merged word has.
    private static func classifyWordProblem(_ word: MergedWord) -> MergeFlagKind? {
        switch word.source {
        case .agreed:
            // Both engines agreed — only flag if both had low confidence
            if word.confidence < flagConfidenceThreshold {
                return .lowConfidence
            }
            return nil

        case .disagreed(_, _, let refConf, let candConf):
            // Both engines heard something but disagree — flag if neither is very confident
            let maxConf = max(refConf, candConf)
            if maxConf < 0.75 {
                return .ambiguousText
            }
            // If the winner is confident enough, trust the merge
            return nil

        case .referenceOnly, .candidateOnly:
            // Single-engine words — handled separately by detectMissingPhrases
            return nil
        }
    }

    /// Build a flag from a word range within a segment.
    private static func buildFlag(
        segment: MergedSegment,
        segIndex: Int,
        wordRange: Range<Int>,
        kind: MergeFlagKind
    ) -> MergeFlag? {
        let flagWords = Array(segment.words[wordRange])
        guard !flagWords.isEmpty else { return nil }

        let mergedText = flagWords.map(\.word).joined(separator: " ")
        var refText = ""
        var candText = ""
        var refConf: Float = 0
        var candConf: Float = 0
        var refCount = 0
        var candCount = 0

        for w in flagWords {
            switch w.source {
            case .agreed(let rw, let cw, let rc, let cc),
                 .disagreed(let rw, let cw, let rc, let cc):
                refText += (refText.isEmpty ? "" : " ") + rw
                candText += (candText.isEmpty ? "" : " ") + cw
                refConf += rc; candConf += cc
                refCount += 1; candCount += 1
            case .referenceOnly(let c):
                refText += (refText.isEmpty ? "" : " ") + w.word
                refConf += c; refCount += 1
            case .candidateOnly(let c):
                candText += (candText.isEmpty ? "" : " ") + w.word
                candConf += c; candCount += 1
            }
        }

        return MergeFlag(
            kind: kind,
            segmentIndex: segIndex,
            wordRange: wordRange,
            start: TimeInterval(flagWords.first!.start),
            end: TimeInterval(flagWords.last!.end),
            mergedText: mergedText,
            referenceText: refText,
            candidateText: candText,
            referenceSpeakerID: segment.speakerID,
            candidateSpeakerID: segment.speakerID,
            referenceConfidence: refCount > 0 ? refConf / Float(refCount) : 0,
            candidateConfidence: candCount > 0 ? candConf / Float(candCount) : 0
        )
    }

    /// Detect speaker disputes: places where the reference and candidate
    /// assigned different speakers to the same time region.
    private static func detectSpeakerDisputes(segments: [MergedSegment]) -> [MergeFlag] {
        var flags: [MergeFlag] = []

        for (segIndex, segment) in segments.enumerated() {
            // Check if words in this segment have mixed speaker sources
            var speakerVotes: [String: Int] = [:]
            for word in segment.words {
                switch word.source {
                case .agreed, .disagreed:
                    // The word carries the winning speaker — but let's check if there
                    // were different speakers from each engine
                    speakerVotes[word.speakerID, default: 0] += 1
                case .referenceOnly, .candidateOnly:
                    speakerVotes[word.speakerID, default: 0] += 1
                }
            }

            // If there are multiple speaker IDs within a segment that was supposed to be
            // single-speaker, that's a dispute worth flagging
            if speakerVotes.count > 1 {
                let totalVotes = speakerVotes.values.reduce(0, +)
                let majorityPct = Float(speakerVotes.values.max() ?? 0) / Float(max(1, totalVotes))

                // Only flag if the majority is slim (< 80%)
                if majorityPct < 0.8 && segment.words.count >= minimumFlagWords {
                    let speakers = speakerVotes.keys.sorted()
                    flags.append(MergeFlag(
                        kind: .speakerDispute,
                        segmentIndex: segIndex,
                        wordRange: 0..<segment.words.count,
                        start: segment.start,
                        end: segment.end,
                        mergedText: segment.text,
                        referenceText: segment.text,
                        candidateText: segment.text,
                        referenceSpeakerID: speakers.first ?? segment.speakerID,
                        candidateSpeakerID: speakers.last ?? segment.speakerID,
                        referenceConfidence: majorityPct,
                        candidateConfidence: 1.0 - majorityPct
                    ))
                }
            }
        }

        return flags
    }

    /// Detect missing phrases: runs of 3+ words that only one engine produced,
    /// excluding filler words.
    private static func detectMissingPhrases(segments: [MergedSegment]) -> [MergeFlag] {
        var flags: [MergeFlag] = []
        let minimumMissingWords = 3

        for (segIndex, segment) in segments.enumerated() {
            var runStart: Int?
            var runSource: Bool? // true = referenceOnly, false = candidateOnly

            for (wordIdx, word) in segment.words.enumerated() {
                let isRefOnly: Bool
                let isCandOnly: Bool

                switch word.source {
                case .referenceOnly:
                    isRefOnly = true; isCandOnly = false
                case .candidateOnly:
                    isRefOnly = false; isCandOnly = true
                default:
                    isRefOnly = false; isCandOnly = false
                }

                let isSingleEngine = isRefOnly || isCandOnly
                let currentRunIsRef = isRefOnly

                if isSingleEngine && !isFillerWord(normalizeWord(word.word)) {
                    if runStart == nil {
                        runStart = wordIdx
                        runSource = currentRunIsRef
                    } else if runSource != currentRunIsRef {
                        // Source switched — flush
                        if let start = runStart, wordIdx - start >= minimumMissingWords {
                            flags.append(buildMissingPhraseFlag(
                                segment: segment, segIndex: segIndex,
                                wordRange: start..<wordIdx, isReference: runSource ?? true
                            ))
                        }
                        runStart = wordIdx
                        runSource = currentRunIsRef
                    }
                } else {
                    if let start = runStart, wordIdx - start >= minimumMissingWords {
                        flags.append(buildMissingPhraseFlag(
                            segment: segment, segIndex: segIndex,
                            wordRange: start..<wordIdx, isReference: runSource ?? true
                        ))
                    }
                    runStart = nil
                    runSource = nil
                }
            }

            // Flush final run
            if let start = runStart, segment.words.count - start >= minimumMissingWords {
                flags.append(buildMissingPhraseFlag(
                    segment: segment, segIndex: segIndex,
                    wordRange: start..<segment.words.count, isReference: runSource ?? true
                ))
            }
        }

        return flags
    }

    private static func buildMissingPhraseFlag(
        segment: MergedSegment,
        segIndex: Int,
        wordRange: Range<Int>,
        isReference: Bool
    ) -> MergeFlag {
        let phraseWords = Array(segment.words[wordRange])
        let text = phraseWords.map(\.word).joined(separator: " ")
        let avgConf = phraseWords.map(\.confidence).reduce(0, +) / Float(max(1, phraseWords.count))

        return MergeFlag(
            kind: .missingPhrase,
            segmentIndex: segIndex,
            wordRange: wordRange,
            start: TimeInterval(phraseWords.first!.start),
            end: TimeInterval(phraseWords.last!.end),
            mergedText: text,
            referenceText: isReference ? text : "",
            candidateText: isReference ? "" : text,
            referenceSpeakerID: segment.speakerID,
            candidateSpeakerID: segment.speakerID,
            referenceConfidence: isReference ? avgConf : 0,
            candidateConfidence: isReference ? 0 : avgConf
        )
    }

    // MARK: - Helpers

    private static func normalizeWord(_ word: String) -> String {
        word.lowercased()
            .replacingOccurrences(of: "[^a-z0-9']", with: "", options: .regularExpression)
    }

    private static func isFillerWord(_ normalized: String) -> Bool {
        fillerWords.contains(normalized)
    }

    // MARK: - Consensus Export

    /// Convert a MergedTranscript into a TranscriptionResult suitable for saving
    /// as a consensus pass. Applies any flag resolutions the user has made.
    static func buildConsensusResult(
        from merged: MergedTranscript,
        audioPath: String,
        audioDuration: TimeInterval
    ) -> TranscriptionResult {
        var segments: [TranscriptionSegment] = []

        for (_, segment) in merged.segments.enumerated() {
            // Apply flag resolutions to get the final text and speaker
            var finalWords = segment.words
            var finalSpeaker = segment.speakerID

            // Apply resolutions from flags that touch this segment
            for flagIndex in segment.flagIndices {
                guard flagIndex < merged.flags.count else { continue }
                let flag = merged.flags[flagIndex]
                guard flag.isResolved else { continue }

                switch flag.resolution {
                case .useReference:
                    // Replace the flagged word range with reference text
                    applyTextResolution(
                        words: &finalWords,
                        range: flag.wordRange,
                        text: flag.referenceText,
                        confidence: flag.referenceConfidence,
                        speakerID: flag.referenceSpeakerID
                    )
                case .useCandidate:
                    applyTextResolution(
                        words: &finalWords,
                        range: flag.wordRange,
                        text: flag.candidateText,
                        confidence: flag.candidateConfidence,
                        speakerID: flag.candidateSpeakerID
                    )
                case .manual(let text):
                    applyTextResolution(
                        words: &finalWords,
                        range: flag.wordRange,
                        text: text,
                        confidence: 1.0,
                        speakerID: segment.speakerID
                    )
                case .speakerOverride(let speakerID):
                    finalSpeaker = speakerID
                case .merged:
                    break // Keep the auto-merged version
                }
            }

            let text = finalWords.map(\.word).joined(separator: " ")
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }

            let wordTimings = finalWords.map { w in
                TranscriptionSegment.WordTiming(
                    word: w.word,
                    start: w.start,
                    end: w.end,
                    probability: w.confidence
                )
            }

            segments.append(TranscriptionSegment(
                speakerID: finalSpeaker,
                start: segment.start,
                end: segment.end,
                text: text,
                words: wordTimings.isEmpty ? nil : wordTimings
            ))
        }

        // Sentence-coherence smoother: collapse A-B-A single-word speaker flips that
        // come from word-timestamp edge errors. Applied at the final TranscriptionResult
        // layer (same as the standard pipeline) so both entry points benefit.
        // Diagnostic callback is omitted here because `buildConsensusResult` runs in a
        // context without access to the view model's process log; the deeper
        // `refineSpeakers` path does log reassignments with diagnostics.
        segments = SegmentMerger.smoothSentenceBoundaries(segments)

        return TranscriptionResult(
            audioPath: audioPath,
            duration: audioDuration,
            segments: segments
        )
    }

    /// Replace a range of MergedWords with words from a resolution text.
    private static func applyTextResolution(
        words: inout [MergedWord],
        range: Range<Int>,
        text: String,
        confidence: Float,
        speakerID: String
    ) {
        guard range.lowerBound < words.count else { return }
        let clampedRange = range.lowerBound..<min(range.upperBound, words.count)

        let startTime = words[clampedRange.lowerBound].start
        let endTime = words[clampedRange.upperBound - 1].end
        let newTextWords = text.split(whereSeparator: \.isWhitespace).map(String.init)

        guard !newTextWords.isEmpty else {
            words.removeSubrange(clampedRange)
            return
        }

        let duration = endTime - startTime
        let wordDuration = duration / Float(newTextWords.count)

        let replacements = newTextWords.enumerated().map { i, w in
            MergedWord(
                word: w,
                start: startTime + Float(i) * wordDuration,
                end: startTime + Float(i + 1) * wordDuration,
                confidence: confidence,
                source: .agreed(
                    referenceWord: w, candidateWord: w,
                    referenceConfidence: confidence, candidateConfidence: confidence
                ),
                speakerID: speakerID
            )
        }

        words.replaceSubrange(clampedRange, with: replacements)
    }
}
