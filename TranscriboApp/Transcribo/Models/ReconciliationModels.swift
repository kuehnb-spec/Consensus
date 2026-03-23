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
