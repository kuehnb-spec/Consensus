import Foundation

struct PassComparisonSummary: Sendable {
    let referencePassID: UUID
    let candidatePassID: UUID
    let referenceLabel: String
    let candidateLabel: String
    let comparedSegmentCount: Int
    let disputedSegmentCount: Int
    let textAgreementRate: Float?
    let speakerAgreementRate: Float?
    let confidenceDelta: Float?
    let diarizationQualityDelta: Float?
    let disagreements: [PassDisagreement]
}

struct PassDisagreement: Identifiable, Sendable {
    enum Kind: String, Sendable {
        case text
        case speaker
        case textAndSpeaker
        case missingSegment

        var displayName: String {
            switch self {
            case .text:
                return "Text Mismatch"
            case .speaker:
                return "Speaker Mismatch"
            case .textAndSpeaker:
                return "Text + Speaker Mismatch"
            case .missingSegment:
                return "Missing Segment"
            }
        }
    }

    let id: UUID
    let kind: Kind
    let start: TimeInterval
    let end: TimeInterval
    let referenceSpeakerID: String?
    let candidateSpeakerID: String?
    let referenceText: String?
    let candidateText: String?
}

enum PassComparisonService {
    static func compare(reference: TranscriptionPass, candidate: TranscriptionPass) -> PassComparisonSummary {
        let pairs = buildPairs(reference: reference.result.segments, candidate: candidate.result.segments)

        let comparablePairs = pairs.filter { $0.reference != nil || $0.candidate != nil }
        let comparedCount = comparablePairs.count

        var textMatches = 0
        var speakerMatches = 0
        var disagreements: [PassDisagreement] = []

        for pair in comparablePairs {
            let referenceSegment = pair.reference
            let candidateSegment = pair.candidate

            let textMatched = textAgreement(reference: referenceSegment?.text, candidate: candidateSegment?.text)
            let speakerMatched = speakerAgreement(reference: referenceSegment?.speakerID, candidate: candidateSegment?.speakerID)

            if textMatched {
                textMatches += 1
            }

            if speakerMatched {
                speakerMatches += 1
            }

            if let disagreement = disagreement(for: pair, textMatched: textMatched, speakerMatched: speakerMatched) {
                disagreements.append(disagreement)
            }
        }

        disagreements.sort { lhs, rhs in
            if lhs.start != rhs.start {
                return lhs.start < rhs.start
            }
            return lhs.end < rhs.end
        }

        return PassComparisonSummary(
            referencePassID: reference.id,
            candidatePassID: candidate.id,
            referenceLabel: "\(reference.kind.displayName) • \(reference.modelName)",
            candidateLabel: "\(candidate.kind.displayName) • \(candidate.modelName)",
            comparedSegmentCount: comparedCount,
            disputedSegmentCount: disagreements.count,
            textAgreementRate: comparedCount == 0 ? nil : Float(textMatches) / Float(comparedCount),
            speakerAgreementRate: comparedCount == 0 ? nil : Float(speakerMatches) / Float(comparedCount),
            confidenceDelta: delta(candidate.qualitySummary.averageWordConfidence, reference.qualitySummary.averageWordConfidence),
            diarizationQualityDelta: delta(candidate.qualitySummary.averageDiarizationQuality, reference.qualitySummary.averageDiarizationQuality),
            disagreements: Array(disagreements.prefix(12))
        )
    }

    private static func buildPairs(
        reference: [TranscriptionSegment],
        candidate: [TranscriptionSegment]
    ) -> [SegmentPair] {
        var pairs: [SegmentPair] = []
        var usedCandidateIDs: Set<UUID> = []

        for referenceSegment in reference {
            let match = candidate
                .filter { !usedCandidateIDs.contains($0.id) }
                .max { overlapDuration(referenceSegment, $0) < overlapDuration(referenceSegment, $1) }

            if let match, overlapDuration(referenceSegment, match) > 0 {
                usedCandidateIDs.insert(match.id)
                pairs.append(SegmentPair(reference: referenceSegment, candidate: match))
            } else {
                pairs.append(SegmentPair(reference: referenceSegment, candidate: nil))
            }
        }

        for candidateSegment in candidate where !usedCandidateIDs.contains(candidateSegment.id) {
            pairs.append(SegmentPair(reference: nil, candidate: candidateSegment))
        }

        return pairs
    }

    private static func overlapDuration(_ lhs: TranscriptionSegment, _ rhs: TranscriptionSegment) -> TimeInterval {
        let overlapStart = max(lhs.start, rhs.start)
        let overlapEnd = min(lhs.end, rhs.end)
        return max(0, overlapEnd - overlapStart)
    }

    private static func textAgreement(reference: String?, candidate: String?) -> Bool {
        let normalizedReference = normalize(reference)
        let normalizedCandidate = normalize(candidate)

        if normalizedReference.isEmpty && normalizedCandidate.isEmpty {
            return true
        }

        if normalizedReference == normalizedCandidate {
            return true
        }

        let referenceTokens = Set(normalizedReference.split(separator: " ").map(String.init))
        let candidateTokens = Set(normalizedCandidate.split(separator: " ").map(String.init))
        let union = referenceTokens.union(candidateTokens)

        guard !union.isEmpty else { return false }

        let similarity = Double(referenceTokens.intersection(candidateTokens).count) / Double(union.count)
        return similarity >= 0.8
    }

    private static func speakerAgreement(reference: String?, candidate: String?) -> Bool {
        switch (reference, candidate) {
        case (nil, nil):
            return true
        case let (lhs?, rhs?):
            return lhs == rhs
        default:
            return false
        }
    }

    private static func disagreement(
        for pair: SegmentPair,
        textMatched: Bool,
        speakerMatched: Bool
    ) -> PassDisagreement? {
        guard !textMatched || !speakerMatched else { return nil }

        let start = min(pair.reference?.start ?? pair.candidate?.start ?? 0, pair.candidate?.start ?? pair.reference?.start ?? 0)
        let end = max(pair.reference?.end ?? pair.candidate?.end ?? 0, pair.candidate?.end ?? pair.reference?.end ?? 0)

        let kind: PassDisagreement.Kind
        switch (pair.reference, pair.candidate, textMatched, speakerMatched) {
        case (.none, _, _, _), (_, .none, _, _):
            kind = .missingSegment
        case (_, _, false, false):
            kind = .textAndSpeaker
        case (_, _, false, true):
            kind = .text
        case (_, _, true, false):
            kind = .speaker
        case (_, _, true, true):
            return nil
        }

        return PassDisagreement(
            id: UUID(),
            kind: kind,
            start: start,
            end: end,
            referenceSpeakerID: pair.reference?.speakerID,
            candidateSpeakerID: pair.candidate?.speakerID,
            referenceText: pair.reference?.text,
            candidateText: pair.candidate?.text
        )
    }

    private static func normalize(_ text: String?) -> String {
        guard let text else { return "" }

        return text
            .lowercased()
            .replacingOccurrences(of: "[^a-z0-9\\s]", with: "", options: .regularExpression)
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func delta(_ lhs: Float?, _ rhs: Float?) -> Float? {
        guard let lhs, let rhs else { return nil }
        return lhs - rhs
    }
}

private struct SegmentPair: Sendable {
    let reference: TranscriptionSegment?
    let candidate: TranscriptionSegment?
}
