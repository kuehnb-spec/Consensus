import Foundation

/// Represents a diarization segment (speaker label + time range).
struct DiarizationSegment: Sendable {
    let speakerID: String
    let start: TimeInterval
    let end: TimeInterval
    let qualityScore: Float
}

/// Merges transcription segments with diarization results by time overlap.
/// This replicates the logic of whisperx.assign_word_speakers.
enum SegmentMerger {

    /// Assign speaker IDs to transcription segments based on maximum time overlap
    /// with diarization segments.
    static func merge(
        transcriptionSegments: [TranscriptionSegment],
        diarizationSegments: [DiarizationSegment]
    ) -> [TranscriptionSegment] {
        guard !diarizationSegments.isEmpty else {
            return transcriptionSegments
        }

        return transcriptionSegments.map { segment in
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
    }

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
}

private struct MatchResult: Sendable {
    let speakerID: String
    let qualityScore: Float
    let overlap: TimeInterval
}
