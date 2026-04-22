import Foundation

/// Scans the opening of a transcript for self-introduction patterns and
/// proposes display names for the diarizer's anonymous speaker IDs.
///
/// Phase 1c.2 uses a simple regex-driven scan that covers the most common
/// English patterns ("Hi, this is X", "My name is X", "X speaking", etc.).
/// It runs against Engine A's segments — no network, no LLM, no model load.
/// If Phase 4's voice library has already matched a speaker, the intro
/// scan defers to it; this service only fills slots the library left blank.
///
/// Future Phase 4.2 may replace the regex scan with a lightweight LLM pass
/// for better recall on unusual intros ("Hey, it's your girl Marie").
enum IntroScanner {

    /// Match on anything in the first 90 seconds. Most self-intros happen
    /// in the first 10–30 seconds; 90 gives slack for call-setup chatter.
    static let defaultScanWindowSeconds: TimeInterval = 90

    struct Suggestion: Equatable, Sendable {
        /// The diarizer's speaker ID (`SPEAKER_0`, `SPEAKER_1`, …).
        let speakerID: String
        /// Name the scanner thinks belongs to that speaker.
        let proposedName: String
        /// Self-reported confidence, 0–1. Higher means a stronger match
        /// (more explicit intro, longer name, earlier in the call).
        let confidence: Double
        /// The segment's start time, for audit/debug.
        let startSeconds: TimeInterval
    }

    /// Scan `segments` for self-intros. Returns one suggestion per speaker
    /// the scanner is confident about; speakers with no intro hit are
    /// omitted (the caller falls back to the default "Speaker N" label).
    static func scan(
        segments: [TranscriptionSegment],
        windowSeconds: TimeInterval = defaultScanWindowSeconds
    ) -> [Suggestion] {
        var best: [String: Suggestion] = [:]

        for segment in segments {
            guard segment.start <= windowSeconds else { break }
            guard let match = firstMatch(in: segment.text) else { continue }
            let confidence = confidenceScore(
                pattern: match.pattern,
                name: match.name,
                startSeconds: segment.start
            )
            let suggestion = Suggestion(
                speakerID: segment.speakerID,
                proposedName: match.name,
                confidence: confidence,
                startSeconds: segment.start
            )
            // Keep the highest-confidence suggestion per speaker
            if let current = best[segment.speakerID],
               current.confidence >= confidence {
                continue
            }
            best[segment.speakerID] = suggestion
        }

        return best.values.sorted { $0.startSeconds < $1.startSeconds }
    }

    // MARK: - Pattern matching

    /// Patterns tried in order. The first hit wins for a given segment.
    /// Each pattern captures the speaker's name in its first group.
    ///
    /// We intentionally bias toward short, high-precision patterns.
    /// Recall-leaning matches that fire on almost-anything are worse than
    /// silence: a wrong auto-fill is annoying; an empty default ("Speaker 1")
    /// is clearly a placeholder the user expects to edit.
    private static let patterns: [(pattern: String, label: String)] = [
        // "Hi, this is Brant Kuehn"
        (#"(?i)\b(?:hi|hello|hey)(?:\s*,?\s*)?(?:it(?:'?s| is)|this is)\s+([A-Z][a-zA-Z'\-]+(?:\s+[A-Z][a-zA-Z'\-]+){0,2})\b"#, "greeting-this-is"),
        // "This is Brant Kuehn"
        (#"(?i)\bthis is\s+([A-Z][a-zA-Z'\-]+(?:\s+[A-Z][a-zA-Z'\-]+){0,2})\b"#, "this-is"),
        // "My name is Brant"
        (#"(?i)\bmy name(?:'?s| is)\s+([A-Z][a-zA-Z'\-]+(?:\s+[A-Z][a-zA-Z'\-]+){0,2})\b"#, "my-name-is"),
        // "Brant speaking"
        (#"(?i)\b([A-Z][a-zA-Z'\-]+(?:\s+[A-Z][a-zA-Z'\-]+){0,1})\s+speaking\b"#, "x-speaking"),
        // "I'm Brant"
        (#"(?i)\bI(?:'?m| am)\s+([A-Z][a-zA-Z'\-]+(?:\s+[A-Z][a-zA-Z'\-]+){0,1})\b"#, "im-x"),
    ]

    /// Returns the first pattern that hits in `text`, with the captured name.
    private static func firstMatch(in text: String) -> (pattern: String, name: String)? {
        for (pattern, label) in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            let nsText = text as NSString
            let range = NSRange(location: 0, length: nsText.length)
            let match = regex.firstMatch(in: text, range: range)
            guard let m = match, m.numberOfRanges > 1 else { continue }
            let captured = nsText.substring(with: m.range(at: 1))
            let cleaned = captured.trimmingCharacters(in: .whitespacesAndNewlines)
            guard isPlausibleName(cleaned) else { continue }
            return (label, cleaned)
        }
        return nil
    }

    /// Filters out matches that captured a word that looks like a greeting
    /// or sentence fragment rather than a name. The regex requires a capital
    /// letter, so "my" and "the" are already filtered — but first-of-sentence
    /// capitalisation can slip words like "Hello" or "Yeah" into the capture.
    private static func isPlausibleName(_ candidate: String) -> Bool {
        let trimmed = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= 40 else { return false }

        let firstWord = trimmed.split(separator: " ").first.map(String.init) ?? ""
        let stopWords: Set<String> = [
            "Hello", "Hi", "Hey", "Yeah", "Yes", "No", "Okay", "Well",
            "So", "And", "But", "Now", "Just", "Actually", "Like",
            "Basically", "Right", "Great", "Thanks", "Sorry",
            "Who", "What", "When", "Where", "Why", "How",
        ]
        if stopWords.contains(firstWord) { return false }

        // Names should be mostly letters; allow apostrophes and hyphens.
        let allowed = CharacterSet.letters
            .union(.whitespaces)
            .union(CharacterSet(charactersIn: "'-"))
        return trimmed.unicodeScalars.allSatisfy { allowed.contains($0) }
    }

    /// Confidence is a simple tier function: more specific patterns and
    /// two-word names rank higher; earlier appearances break ties.
    private static func confidenceScore(
        pattern: String,
        name: String,
        startSeconds: TimeInterval
    ) -> Double {
        var score: Double
        switch pattern {
        case "greeting-this-is": score = 0.95
        case "this-is":          score = 0.85
        case "my-name-is":       score = 0.90
        case "x-speaking":       score = 0.70
        case "im-x":             score = 0.60
        default:                 score = 0.50
        }

        // Two-word names (first + last) are more likely to be real names
        let wordCount = name.split(separator: " ").count
        if wordCount >= 2 { score = min(1.0, score + 0.05) }

        // Earlier hits are more trustworthy — the opening 30s is when
        // introductions actually happen.
        if startSeconds <= 30 { score = min(1.0, score + 0.03) }

        return score
    }
}
