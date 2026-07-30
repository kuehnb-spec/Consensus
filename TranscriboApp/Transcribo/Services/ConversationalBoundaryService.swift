import Foundation

/// Reason a conversational boundary was proposed, for logging and downstream scoring.
enum ConversationalBoundaryReason: String, Sendable, Hashable {
    /// Short back-channel word ("yeah", "okay", "right") — boundary proposed before the word.
    /// The back-channel itself is typically from a different speaker than the surrounding turn.
    case backchannelBefore
    /// Back-channel word — boundary proposed after the word, where the main speaker resumes.
    case backchannelAfter
    /// Segment ends in a question mark followed by a reply.
    case questionEnd
    /// Direct name address ("So Bob, ..." / "Clayton, what do you think?") — boundary before the name.
    case nameAddress
    /// Self-introduction pattern ("Hi, this is ...").
    case selfIntroduction
    /// Silence gap between consecutive segments exceeds a threshold (1.5s).
    case longPause
}

/// A boundary candidate proposed from lexical / conversational patterns in the transcript.
///
/// These candidates are orthogonal to acoustic diarization: they originate from the text alone
/// and surface speaker-change opportunities that acoustic embedding clustering consistently
/// misses (short back-channels absorbed into the neighboring turn, long pauses the model
/// smoothed over, explicit name addresses that close a turn).
struct ConversationalBoundaryCandidate: Sendable, Hashable {
    /// Absolute time of the proposed boundary, in seconds.
    let time: TimeInterval
    /// Pattern that triggered the proposal.
    let reason: ConversationalBoundaryReason
    /// Soft score in [0, 1]; higher means stronger textual evidence.
    let strength: Double
}

/// Lexical boundary proposer.
///
/// Scans a finalized transcript (ideally the merged/verified text with word-level timings)
/// and emits candidate speaker-change times based on conversational-structure patterns that
/// acoustic diarizers miss. Results are meant to be pooled with acoustic boundary candidates
/// and passed through the existing LLM confirmation + acoustic verification path — this
/// service does NOT attribute speakers or alter segments directly.
///
/// All heuristics are conservative: a candidate being proposed here means "worth asking
/// the LLM about," not "definitely a speaker change."
enum ConversationalBoundaryService {

    // MARK: - Tunables

    /// Back-channel tokens that are almost always from a different speaker than the
    /// surrounding turn. Kept intentionally small to avoid false positives on filler words
    /// that a single speaker uses ("um", "uh", "like" — these are typically same-speaker).
    private static let backchannelTokens: Set<String> = [
        "yeah", "yep", "yup",
        "okay", "ok",
        "right",
        "correct",
        "mmhmm", "mm-hmm", "mhmm", "mhm",
        "uh-huh", "uhhuh",
        "gotcha",
        "exactly",
        "sure",
        "understood",
        "true",
        "good"
    ]

    /// Additional back-channel patterns that only qualify when the segment is *short*.
    /// "No" and "yes" are ambiguous in longer contexts ("No, I disagree with...") so we
    /// only treat them as back-channels when they stand mostly alone.
    private static let shortOnlyBackchannelTokens: Set<String> = [
        "yes", "no", "nope"
    ]

    /// Maximum duration (seconds) for a segment/word to be considered a standalone back-channel.
    private static let backchannelMaxDuration: TimeInterval = 0.8

    /// Maximum word count for a segment to be considered a standalone back-channel turn.
    private static let backchannelMaxWordCount = 3

    /// Silence gap (seconds) between adjacent segments above which we propose a boundary.
    private static let longPauseThreshold: TimeInterval = 1.5

    /// Deduplication window (seconds). Two candidates from different reasons within this
    /// distance collapse into the stronger one.
    private static let dedupeWindow: TimeInterval = 0.35

    // MARK: - Entry point

    /// Propose candidate boundaries from a finalized transcript.
    ///
    /// - Parameter segments: speaker-attributed segments with optional word-level timings.
    ///     Word timings improve precision on back-channel detection; when absent, the
    ///     segment-level start/end is used.
    /// - Returns: candidates sorted by time, deduplicated within `dedupeWindow`.
    static func proposeBoundaries(
        from segments: [TranscriptionSegment]
    ) -> [ConversationalBoundaryCandidate] {
        guard !segments.isEmpty else { return [] }

        var candidates: [ConversationalBoundaryCandidate] = []

        candidates.append(contentsOf: backchannelCandidates(in: segments))
        candidates.append(contentsOf: longPauseCandidates(in: segments))
        candidates.append(contentsOf: nameAddressAndQuestionCandidates(in: segments))
        candidates.append(contentsOf: selfIntroductionCandidates(in: segments))

        return deduplicate(candidates)
    }

    // MARK: - Back-channel detection

    /// Detect short back-channel segments ("yeah", "okay", ...) and propose boundaries
    /// both before and after them — the back-channel is typically from a different speaker
    /// than the surrounding turn, which implies two speaker changes around it.
    private static func backchannelCandidates(
        in segments: [TranscriptionSegment]
    ) -> [ConversationalBoundaryCandidate] {
        var result: [ConversationalBoundaryCandidate] = []

        // (1) Segment-level detection: whole short segments whose text is a back-channel.
        for segment in segments {
            guard isBackchannelSegment(segment) else { continue }
            // Boundary BEFORE: prior speaker ends, back-channel starts.
            result.append(.init(time: segment.start, reason: .backchannelBefore, strength: 0.75))
            // Boundary AFTER: back-channel ends, prior speaker resumes.
            result.append(.init(time: segment.end, reason: .backchannelAfter, strength: 0.70))
        }

        // (2) Word-level detection: a back-channel word embedded inside a longer segment.
        // These are the cases acoustic diarization is most likely to miss — the embedding
        // window that would prove a speaker change is too short to detect.
        for segment in segments {
            guard let words = segment.words, words.count >= 3 else { continue }
            // Skip if the whole segment already triggered segment-level detection.
            if isBackchannelSegment(segment) { continue }

            for (index, word) in words.enumerated() {
                let cleaned = normalize(word.word)
                guard !cleaned.isEmpty else { continue }
                guard backchannelTokens.contains(cleaned) else { continue }

                let duration = TimeInterval(word.end - word.start)
                guard duration <= backchannelMaxDuration else { continue }

                // Guard rails: skip if the adjacent words look like a continuation
                // ("Yeah, I think..." from the same speaker). A back-channel is typically
                // flanked by silence or followed by another turn starting.
                if hasLongGapAround(index: index, in: words, minGap: 0.15) {
                    result.append(.init(
                        time: TimeInterval(word.start),
                        reason: .backchannelBefore,
                        strength: 0.60
                    ))
                    result.append(.init(
                        time: TimeInterval(word.end),
                        reason: .backchannelAfter,
                        strength: 0.55
                    ))
                }
            }
        }

        return result
    }

    private static func isBackchannelSegment(_ segment: TranscriptionSegment) -> Bool {
        let duration = segment.end - segment.start
        guard duration <= backchannelMaxDuration * 3 else { return false }

        let tokens = tokenize(segment.text)
        guard !tokens.isEmpty, tokens.count <= backchannelMaxWordCount else { return false }

        // All tokens must be back-channels. Use the relaxed "short-only" set for segments
        // that are clearly standalone (low word count, short duration).
        let allowedTokens = backchannelTokens.union(shortOnlyBackchannelTokens)
        return tokens.allSatisfy { allowedTokens.contains($0) }
    }

    /// A back-channel word should be surrounded by small inter-word gaps (suggesting an
    /// interjection from elsewhere) rather than sitting tightly in a continuous phrase.
    private static func hasLongGapAround(
        index: Int,
        in words: [TranscriptionSegment.WordTiming],
        minGap: TimeInterval
    ) -> Bool {
        let before: TimeInterval = {
            guard index > 0 else { return .infinity }
            return TimeInterval(words[index].start - words[index - 1].end)
        }()
        let after: TimeInterval = {
            guard index < words.count - 1 else { return .infinity }
            return TimeInterval(words[index + 1].start - words[index].end)
        }()
        return max(before, after) >= minGap
    }

    // MARK: - Long-pause detection

    /// Inter-segment silence longer than `longPauseThreshold` is a natural turn boundary
    /// the acoustic diarizer may have smoothed over if the two turns sounded similar.
    private static func longPauseCandidates(
        in segments: [TranscriptionSegment]
    ) -> [ConversationalBoundaryCandidate] {
        guard segments.count >= 2 else { return [] }
        var result: [ConversationalBoundaryCandidate] = []

        let sorted = segments.sorted { $0.start < $1.start }
        for (previous, current) in zip(sorted, sorted.dropFirst()) {
            let gap = current.start - previous.end
            guard gap >= longPauseThreshold else { continue }
            // Propose the boundary in the middle of the silence — acoustic verification
            // will pull the boundary toward wherever the real speaker change happens.
            let midpoint = previous.end + gap / 2
            // Stronger evidence with longer pauses, capped.
            let strength = min(0.85, 0.45 + (gap - longPauseThreshold) * 0.1)
            result.append(.init(time: midpoint, reason: .longPause, strength: strength))
        }

        return result
    }

    // MARK: - Name-address and question patterns

    private static let directAddressPattern: NSRegularExpression? = try? NSRegularExpression(
        pattern: #"(?i)\b(so|and|well|okay|hey)\s+([A-Z][a-z]{1,15})\s*[,.?]"#,
        options: []
    )

    /// Propose boundaries at points where:
    ///  - a sentence ends in "?", suggesting the other speaker's answer begins next, AND
    ///  - the text directly addresses someone by name near the start of a segment.
    ///
    /// Question marks alone are weak evidence (self-answered questions exist), but in the
    /// candidate pool the LLM + acoustic verifier will filter the noise.
    private static func nameAddressAndQuestionCandidates(
        in segments: [TranscriptionSegment]
    ) -> [ConversationalBoundaryCandidate] {
        var result: [ConversationalBoundaryCandidate] = []

        for segment in segments {
            let text = segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }

            // Question at segment end → boundary right after segment end.
            if text.hasSuffix("?") {
                result.append(.init(
                    time: segment.end,
                    reason: .questionEnd,
                    strength: 0.45
                ))
            }

            // Direct name address near segment start → boundary at segment start
            // (the prior speaker's turn just ended and this one is opening by naming them).
            if let regex = directAddressPattern {
                let range = NSRange(text.startIndex..<text.endIndex, in: text)
                if let match = regex.firstMatch(in: text, options: [], range: range),
                   match.range.location < 40 {
                    result.append(.init(
                        time: segment.start,
                        reason: .nameAddress,
                        strength: 0.55
                    ))
                }
            }
        }

        return result
    }

    // MARK: - Self-introduction patterns

    private static let selfIntroductionPatterns: [NSRegularExpression] = [
        #"(?i)\b(hi|hello|hey)[, ]+this is\b"#,
        #"(?i)\bthis is\s+[A-Z][a-z]+\b"#,
        #"(?i)\b(hi|hello|hey)\s+[A-Z][a-z]+[, ]+this is\b"#,
        #"(?i)^speaking$"#
    ].compactMap { try? NSRegularExpression(pattern: $0, options: []) }

    /// Self-introduction openings usually sit right at a turn boundary.
    private static func selfIntroductionCandidates(
        in segments: [TranscriptionSegment]
    ) -> [ConversationalBoundaryCandidate] {
        var result: [ConversationalBoundaryCandidate] = []

        for segment in segments {
            let text = segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            let range = NSRange(text.startIndex..<text.endIndex, in: text)

            for regex in selfIntroductionPatterns {
                if let match = regex.firstMatch(in: text, options: [], range: range),
                   match.range.location < 25 {
                    result.append(.init(
                        time: segment.start,
                        reason: .selfIntroduction,
                        strength: 0.70
                    ))
                    break
                }
            }
        }

        return result
    }

    // MARK: - Helpers

    private static func normalize(_ word: String) -> String {
        word
            .lowercased()
            .trimmingCharacters(in: CharacterSet.punctuationCharacters)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func tokenize(_ text: String) -> [String] {
        text
            .lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
    }

    /// Collapse near-duplicate candidates within `dedupeWindow`, keeping the strongest.
    private static func deduplicate(
        _ candidates: [ConversationalBoundaryCandidate]
    ) -> [ConversationalBoundaryCandidate] {
        let sorted = candidates.sorted { $0.time < $1.time }
        var result: [ConversationalBoundaryCandidate] = []
        result.reserveCapacity(sorted.count)

        for candidate in sorted {
            if let last = result.last, abs(candidate.time - last.time) < dedupeWindow {
                if candidate.strength > last.strength {
                    result[result.count - 1] = candidate
                }
                continue
            }
            result.append(candidate)
        }

        return result
    }
}
