import Foundation

enum QualityAnalysisService {
    static let lowWordConfidenceThreshold: Float = 0.5
    static let lowSegmentConfidenceThreshold: Float = 0.72
    static let lowDiarizationQualityThreshold: Float = 0.45

    static func analyze(result: TranscriptionResult) -> TranscriptQualitySummary {
        let segments = result.segments
        let words = result.allWords

        let wordConfidences = words.map(\.probability)
        let segmentConfidences = segments.compactMap(\.averageWordConfidence)
        let diarizationQualities = segments.compactMap(\.diarizationQuality)
        let averageLogProbs = segments.compactMap(\.averageLogProb)
        let compressionRatios = segments.compactMap(\.compressionRatio)
        let noSpeechProbabilities = segments.compactMap(\.noSpeechProb)

        var riskySegments: [QualityFlag] = []
        var lowConfidenceSegmentCount = 0
        var lowDiarizationSegmentCount = 0
        var unknownSpeakerSegmentCount = 0

        for segment in segments {
            let snippet = abbreviated(segment.text)

            if segment.speakerID == "UNKNOWN" {
                unknownSpeakerSegmentCount += 1
                riskySegments.append(
                    QualityFlag(
                        segmentID: segment.id,
                        kind: .unknownSpeaker,
                        severity: .medium,
                        speakerID: segment.speakerID,
                        start: segment.start,
                        end: segment.end,
                        snippet: snippet,
                        message: "Speaker attribution was unavailable for this segment."
                    )
                )
            }

            if let segmentConfidence = segment.averageWordConfidence,
               segmentConfidence < lowSegmentConfidenceThreshold {
                lowConfidenceSegmentCount += 1
                riskySegments.append(
                    QualityFlag(
                        segmentID: segment.id,
                        kind: .lowSegmentConfidence,
                        severity: segmentConfidence < 0.55 ? .high : .medium,
                        speakerID: segment.speakerID,
                        start: segment.start,
                        end: segment.end,
                        snippet: snippet,
                        observedValue: segmentConfidence,
                        thresholdValue: lowSegmentConfidenceThreshold,
                        message: "The average word confidence for this segment is below the review threshold."
                    )
                )
            }

            if let minWordConfidence = segment.minimumWordConfidence,
               minWordConfidence < lowWordConfidenceThreshold {
                riskySegments.append(
                    QualityFlag(
                        segmentID: segment.id,
                        kind: .lowWordConfidence,
                        severity: minWordConfidence < 0.3 ? .high : .low,
                        speakerID: segment.speakerID,
                        start: segment.start,
                        end: segment.end,
                        snippet: snippet,
                        observedValue: minWordConfidence,
                        thresholdValue: lowWordConfidenceThreshold,
                        message: "At least one recognized word in this segment had weak confidence."
                    )
                )
            }

            if let diarizationQuality = segment.diarizationQuality,
               diarizationQuality < lowDiarizationQualityThreshold {
                lowDiarizationSegmentCount += 1
                riskySegments.append(
                    QualityFlag(
                        segmentID: segment.id,
                        kind: .lowDiarizationQuality,
                        severity: diarizationQuality < 0.25 ? .high : .medium,
                        speakerID: segment.speakerID,
                        start: segment.start,
                        end: segment.end,
                        snippet: snippet,
                        observedValue: diarizationQuality,
                        thresholdValue: lowDiarizationQualityThreshold,
                        message: "Speaker attribution quality was weak for this segment."
                    )
                )
            }
        }

        riskySegments.sort {
            if $0.severity.sortRank != $1.severity.sortRank {
                return $0.severity.sortRank < $1.severity.sortRank
            }
            return $0.start < $1.start
        }

        return TranscriptQualitySummary(
            averageWordConfidence: average(of: wordConfidences),
            averageSegmentConfidence: average(of: segmentConfidences),
            averageDiarizationQuality: average(of: diarizationQualities),
            averageLogProb: average(of: averageLogProbs),
            averageCompressionRatio: average(of: compressionRatios),
            averageNoSpeechProbability: average(of: noSpeechProbabilities),
            lowConfidenceWordCount: wordConfidences.filter { $0 < lowWordConfidenceThreshold }.count,
            lowConfidenceSegmentCount: lowConfidenceSegmentCount,
            lowDiarizationSegmentCount: lowDiarizationSegmentCount,
            unknownSpeakerSegmentCount: unknownSpeakerSegmentCount,
            riskySegments: Array(riskySegments.prefix(25))
        )
    }

    private static func average(of values: [Float]) -> Float? {
        guard !values.isEmpty else { return nil }
        let total = values.reduce(Float.zero, +)
        return total / Float(values.count)
    }

    private static func abbreviated(_ text: String, maxLength: Int = 120) -> String {
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard clean.count > maxLength else { return clean }
        return String(clean.prefix(maxLength)) + "..."
    }
}
