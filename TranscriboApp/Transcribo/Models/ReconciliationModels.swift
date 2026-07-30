import Foundation

enum ReconciliationSourceChoice: String, CaseIterable, Sendable {
    case reference
    case candidate
    case manual

    var displayName: String {
        switch self {
        case .reference:
            return "Reference"
        case .candidate:
            return "Candidate"
        case .manual:
            return "Manual"
        }
    }
}

enum ReconciliationDifferenceKind: String, CaseIterable, Sendable {
    case aligned
    case punctuation
    case speaker
    case text
    case textAndSpeaker
    case missing

    var displayName: String {
        switch self {
        case .aligned:
            return "Aligned"
        case .punctuation:
            return "Punctuation"
        case .speaker:
            return "Speaker"
        case .text:
            return "Text"
        case .textAndSpeaker:
            return "Text + Speaker"
        case .missing:
            return "Missing"
        }
    }

    var isSoftDifference: Bool {
        self == .punctuation
    }

    var hasDifference: Bool {
        self != .aligned
    }
}

struct ReconciliationRow: Identifiable, Sendable {
    let id: UUID
    let start: TimeInterval
    let end: TimeInterval
    let referenceSegments: [TranscriptionSegment]
    let candidateSegments: [TranscriptionSegment]
    var differenceKind: ReconciliationDifferenceKind
    var selectedSource: ReconciliationSourceChoice
    var draftText: String
    var resolvedSpeakerID: String
    var needsReview: Bool

    /// Sentence-level text for this row (may differ from full segment text).
    /// When sentence-level chunking is used, these contain just the specific
    /// sentence that differs, not the full segment block.
    var referenceSentence: String?
    var candidateSentence: String?

    init(
        id: UUID = UUID(),
        start: TimeInterval,
        end: TimeInterval,
        referenceSegments: [TranscriptionSegment],
        candidateSegments: [TranscriptionSegment],
        differenceKind: ReconciliationDifferenceKind,
        selectedSource: ReconciliationSourceChoice,
        draftText: String,
        resolvedSpeakerID: String,
        needsReview: Bool,
        referenceSentence: String? = nil,
        candidateSentence: String? = nil
    ) {
        self.id = id
        self.start = start
        self.end = end
        self.referenceSegments = referenceSegments
        self.candidateSegments = candidateSegments
        self.differenceKind = differenceKind
        self.selectedSource = selectedSource
        self.draftText = draftText
        self.resolvedSpeakerID = resolvedSpeakerID
        self.needsReview = needsReview
        self.referenceSentence = referenceSentence
        self.candidateSentence = candidateSentence
    }

    /// The sentence-level text for display. Falls back to full segment text if not set.
    var referenceText: String {
        referenceSentence ?? ReconciliationSegmentSummary.joinedText(referenceSegments)
    }

    var candidateText: String {
        candidateSentence ?? ReconciliationSegmentSummary.joinedText(candidateSegments)
    }

    var referenceSpeakerID: String {
        ReconciliationSegmentSummary.primarySpeakerID(referenceSegments)
    }

    var candidateSpeakerID: String {
        ReconciliationSegmentSummary.primarySpeakerID(candidateSegments)
    }

    var referenceAverageConfidence: Float? {
        ReconciliationSegmentSummary.averageWordConfidence(referenceSegments)
    }

    var candidateAverageConfidence: Float? {
        ReconciliationSegmentSummary.averageWordConfidence(candidateSegments)
    }

    var referenceSegmentCount: Int {
        referenceSegments.count
    }

    var candidateSegmentCount: Int {
        candidateSegments.count
    }
}

struct ReconciliationDraft: Identifiable, Sendable {
    let id: UUID
    let referencePassID: UUID
    let candidatePassID: UUID
    var consensusPassID: UUID?
    let referenceLabel: String
    let candidateLabel: String
    var rows: [ReconciliationRow]
    var updatedAt: Date

    init(
        id: UUID = UUID(),
        referencePassID: UUID,
        candidatePassID: UUID,
        consensusPassID: UUID? = nil,
        referenceLabel: String,
        candidateLabel: String,
        rows: [ReconciliationRow],
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.referencePassID = referencePassID
        self.candidatePassID = candidatePassID
        self.consensusPassID = consensusPassID
        self.referenceLabel = referenceLabel
        self.candidateLabel = candidateLabel
        self.rows = rows
        self.updatedAt = updatedAt
    }
}

enum ReconciliationSegmentSummary {
    static func joinedText(_ segments: [TranscriptionSegment]) -> String {
        segments
            .map { $0.text.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    static func primarySpeakerID(_ segments: [TranscriptionSegment]) -> String {
        let nonUnknown = segments.filter { $0.speakerID != "UNKNOWN" }
        let candidates = nonUnknown.isEmpty ? segments : nonUnknown

        guard !candidates.isEmpty else {
            return "UNKNOWN"
        }

        let durations = candidates.reduce(into: [String: TimeInterval]()) { partialResult, segment in
            let duration = max(0.01, segment.end - segment.start)
            partialResult[segment.speakerID, default: 0] += duration
        }

        return durations.max(by: { $0.value < $1.value })?.key ?? candidates[0].speakerID
    }

    static func averageWordConfidence(_ segments: [TranscriptionSegment]) -> Float? {
        let confidences = segments.compactMap(\.averageWordConfidence)
        guard !confidences.isEmpty else { return nil }
        let total = confidences.reduce(Float.zero, +)
        return total / Float(confidences.count)
    }

    static func averageDiarizationQuality(_ segments: [TranscriptionSegment]) -> Float? {
        let qualities = segments.compactMap(\.diarizationQuality)
        guard !qualities.isEmpty else { return nil }
        let total = qualities.reduce(Float.zero, +)
        return total / Float(qualities.count)
    }

    static func aggregateWords(_ segments: [TranscriptionSegment]) -> [TranscriptionSegment.WordTiming]? {
        guard segments.allSatisfy({ $0.words != nil }) else { return nil }

        let words = segments.compactMap(\.words).flatMap { $0 }
        return words.isEmpty ? nil : words
    }
}

// MARK: - Confidence-Weighted Merge Models

/// A single word in the merged transcript, carrying provenance from both engines.
struct MergedWord: Identifiable, Sendable {
    let id: UUID
    let word: String
    let start: Float
    let end: Float
    let confidence: Float
    let source: MergedWordSource
    let speakerID: String

    init(
        id: UUID = UUID(),
        word: String,
        start: Float,
        end: Float,
        confidence: Float,
        source: MergedWordSource,
        speakerID: String
    ) {
        self.id = id
        self.word = word
        self.start = start
        self.end = end
        self.confidence = confidence
        self.source = source
        self.speakerID = speakerID
    }
}

enum MergedWordSource: Sendable {
    /// Both engines agreed (within tolerance); picked highest confidence.
    case agreed(referenceWord: String, candidateWord: String, referenceConfidence: Float, candidateConfidence: Float)
    /// Only the reference engine produced this word.
    case referenceOnly(confidence: Float)
    /// Only the candidate engine produced this word.
    case candidateOnly(confidence: Float)
    /// Engines disagreed on the word text; picked highest confidence.
    case disagreed(referenceWord: String, candidateWord: String, referenceConfidence: Float, candidateConfidence: Float)
}

/// Categorizes why a region of the merged transcript was flagged for human review.
enum MergeFlagKind: String, Sendable {
    /// Both engines have low confidence for this region.
    case lowConfidence
    /// Engines disagree on the words and neither is high-confidence.
    case ambiguousText
    /// Diarization passes disagree on who is speaking.
    case speakerDispute
    /// One engine heard a phrase the other missed entirely.
    case missingPhrase
    /// Engines disagree on a named entity (proper noun, number, date).
    case namedEntityDispute

    var displayName: String {
        switch self {
        case .lowConfidence: return "Low Confidence"
        case .ambiguousText: return "Ambiguous Text"
        case .speakerDispute: return "Speaker Dispute"
        case .missingPhrase: return "Missing Phrase"
        case .namedEntityDispute: return "Named Entity"
        }
    }

    var systemImage: String {
        switch self {
        case .lowConfidence: return "waveform.badge.exclamationmark"
        case .ambiguousText: return "text.badge.questionmark"
        case .speakerDispute: return "person.2.wave.2"
        case .missingPhrase: return "text.line.last.and.arrowtriangle.forward"
        case .namedEntityDispute: return "textformat.abc.dottedunderline"
        }
    }
}

/// A flagged region in the merged transcript that needs human review.
struct MergeFlag: Identifiable, Sendable {
    let id: UUID
    let kind: MergeFlagKind
    /// Index range within MergedTranscript.segments[n].words covering this flag.
    let segmentIndex: Int
    let wordRange: Range<Int>
    let start: TimeInterval
    let end: TimeInterval
    /// The text the merge engine chose (best guess).
    var mergedText: String
    /// What Engine A (reference) heard for this region.
    let referenceText: String
    /// What Engine B (candidate) heard for this region.
    let candidateText: String
    let referenceSpeakerID: String
    let candidateSpeakerID: String
    let referenceConfidence: Float
    let candidateConfidence: Float
    /// Whether the user has reviewed and resolved this flag.
    var isResolved: Bool
    /// User's chosen resolution.
    var resolution: MergeFlagResolution

    init(
        id: UUID = UUID(),
        kind: MergeFlagKind,
        segmentIndex: Int,
        wordRange: Range<Int>,
        start: TimeInterval,
        end: TimeInterval,
        mergedText: String,
        referenceText: String,
        candidateText: String,
        referenceSpeakerID: String,
        candidateSpeakerID: String,
        referenceConfidence: Float,
        candidateConfidence: Float,
        isResolved: Bool = false,
        resolution: MergeFlagResolution = .merged
    ) {
        self.id = id
        self.kind = kind
        self.segmentIndex = segmentIndex
        self.wordRange = wordRange
        self.start = start
        self.end = end
        self.mergedText = mergedText
        self.referenceText = referenceText
        self.candidateText = candidateText
        self.referenceSpeakerID = referenceSpeakerID
        self.candidateSpeakerID = candidateSpeakerID
        self.referenceConfidence = referenceConfidence
        self.candidateConfidence = candidateConfidence
        self.isResolved = isResolved
        self.resolution = resolution
    }
}

/// How a flagged region was resolved.
enum MergeFlagResolution: Sendable {
    /// Keep the auto-merged text (default).
    case merged
    /// Use the reference engine's text.
    case useReference
    /// Use the candidate engine's text.
    case useCandidate
    /// User typed a manual override.
    case manual(text: String)
    /// User chose a specific speaker for a speaker dispute.
    case speakerOverride(speakerID: String)

    var resolvedText: String? {
        switch self {
        case .manual(let text): return text
        default: return nil
        }
    }
}

/// A segment in the merged transcript — one speaker's continuous speech block.
struct MergedSegment: Identifiable, Sendable {
    let id: UUID
    var speakerID: String
    let start: TimeInterval
    let end: TimeInterval
    var words: [MergedWord]
    /// Indices of flags that overlap this segment.
    var flagIndices: [Int]

    init(
        id: UUID = UUID(),
        speakerID: String,
        start: TimeInterval,
        end: TimeInterval,
        words: [MergedWord],
        flagIndices: [Int] = []
    ) {
        self.id = id
        self.speakerID = speakerID
        self.start = start
        self.end = end
        self.words = words
        self.flagIndices = flagIndices
    }

    var text: String {
        words.map(\.word).joined(separator: " ")
    }
}

/// The complete result of a confidence-weighted merge between two passes.
struct MergedTranscript: Sendable {
    let referencePassID: UUID
    let candidatePassID: UUID
    let referenceLabel: String
    let candidateLabel: String
    var segments: [MergedSegment]
    var flags: [MergeFlag]
    var updatedAt: Date
    /// Set to `true` after a forced-alignment pass has rebuilt the per-word
    /// timings from the audio against the chosen text. Used by the UI to
    /// surface a "refined timings" badge and to avoid re-running alignment.
    var wordTimingsRefined: Bool
    /// Human-readable label for the aligner that produced the refined timings
    /// (e.g. "Qwen3-ForcedAligner"). `nil` when timings come from the source
    /// ASR engines.
    var wordTimingsAlignerLabel: String?

    init(
        referencePassID: UUID,
        candidatePassID: UUID,
        referenceLabel: String,
        candidateLabel: String,
        segments: [MergedSegment],
        flags: [MergeFlag],
        updatedAt: Date = Date(),
        wordTimingsRefined: Bool = false,
        wordTimingsAlignerLabel: String? = nil
    ) {
        self.referencePassID = referencePassID
        self.candidatePassID = candidatePassID
        self.referenceLabel = referenceLabel
        self.candidateLabel = candidateLabel
        self.segments = segments
        self.flags = flags
        self.updatedAt = updatedAt
        self.wordTimingsRefined = wordTimingsRefined
        self.wordTimingsAlignerLabel = wordTimingsAlignerLabel
    }

    var unresolvedFlagCount: Int {
        flags.filter { !$0.isResolved }.count
    }

    var totalFlagCount: Int {
        flags.count
    }
}
