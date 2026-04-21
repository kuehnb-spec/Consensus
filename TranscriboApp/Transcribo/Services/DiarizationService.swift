import FluidAudio
import Foundation

/// Which diarization engine to use.
enum DiarizationEngine: String, CaseIterable, Identifiable, Codable, Sendable {
    case speakerKit = "SpeakerKit"
    case fluidAudio = "FluidAudio"
    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .speakerKit: return "SpeakerKit (pyannote v4)"
        case .fluidAudio: return "FluidAudio (pyannote v1)"
        }
    }

    var shortName: String { rawValue }
}

/// Clustering parameter preset for multi-threshold diarization.
struct DiarizationPreset: Sendable {
    let name: String
    let threshold: Double
    let warmStartFa: Double
    let warmStartFb: Double

    static let aggressive = DiarizationPreset(
        name: "Aggressive",
        threshold: 0.45,
        warmStartFa: 0.05,
        warmStartFb: 0.7
    )

    static let balanced = DiarizationPreset(
        name: "Balanced",
        threshold: 0.60,
        warmStartFa: 0.07,
        warmStartFb: 0.8
    )

    static let conservative = DiarizationPreset(
        name: "Conservative",
        threshold: 0.75,
        warmStartFa: 0.10,
        warmStartFb: 0.9
    )

    static let deepReviewPresets: [DiarizationPreset] = [.aggressive, .balanced, .conservative]
}

/// Result of a single diarization pass with its configuration label.
struct DiarizationPassResult: Sendable {
    let presetName: String
    let engineName: String
    let segments: [DiarizationSegment]
}

/// Result of multi-engine/multi-threshold diarization with all passes and the resolved consensus.
struct MultiDiarizationResult: Sendable {
    let passes: [DiarizationPassResult]
    let resolved: [DiarizationSegment]
    let disagreementCount: Int
}

/// Coordinates diarization across multiple engines (SpeakerKit + FluidAudio).
/// SpeakerKit is the primary engine; FluidAudio serves as a secondary for cross-engine comparison.
actor DiarizationService {
    private let speakerKitService = SpeakerKitDiarizationService()
    private var fluidDiarizer: OfflineDiarizerManager?
    private let speakerKitDeepReviewPasses: [(presetName: String, threshold: Float?)] = [
        ("Primary", nil),
        ("Aggressive", 0.45),
        ("Conservative", 0.70)
    ]

    // MARK: - Single-Engine Diarization

    /// Run focused diarization on a specific time range to verify a speaker boundary.
    /// Returns true if the diarization model detects a different speaker at `candidateTime`
    /// compared to the surrounding audio.
    func verifyBoundary(
        audioURL: URL,
        candidateTime: TimeInterval,
        contextWindow: TimeInterval = 30,
        numberOfSpeakers: Int? = nil
    ) async throws -> Bool {
        let clipStart = max(0, candidateTime - contextWindow)
        let clipEnd = candidateTime + contextWindow

        let segments = try await speakerKitService.diarizeFocused(
            audioURL: audioURL,
            clipStart: clipStart,
            clipEnd: clipEnd,
            numberOfSpeakers: numberOfSpeakers
        )

        // Check if there's a speaker change within 1 second of the candidate time
        let cleaned = SegmentMerger.postProcessDiarization(segments)
        for i in 1..<cleaned.count {
            let boundaryTime = cleaned[i].start
            if abs(boundaryTime - candidateTime) < 1.0 &&
               cleaned[i].speakerID != cleaned[i - 1].speakerID {
                return true  // Acoustic evidence confirms a speaker change
            }
        }

        return false  // No speaker change detected near the candidate time
    }

    /// Run primary diarization using the specified engine.
    func diarize(
        audioURL: URL,
        engine: DiarizationEngine = .speakerKit,
        minSpeakers: Int?,
        maxSpeakers: Int?
    ) async throws -> [DiarizationSegment] {
        switch engine {
        case .speakerKit:
            return try await speakerKitService.diarize(
                audioURL: audioURL,
                numberOfSpeakers: exactSpeakerCount(min: minSpeakers, max: maxSpeakers)
            )
        case .fluidAudio:
            return try await fluidAudioDiarize(
                audioURL: audioURL,
                minSpeakers: minSpeakers,
                maxSpeakers: maxSpeakers
            )
        }
    }

    // MARK: - Multi-Engine Deep Diarization

    /// Run diarization with multiple engines and/or thresholds for deep review.
    /// Returns individual pass results plus a majority-vote resolved consensus.
    ///
    /// Strategy:
    /// 1. SpeakerKit default pass (primary reference)
    /// 2. Alternate SpeakerKit thresholds to surface missed boundaries
    /// 3. FluidAudio comparison passes for cross-engine disagreement detection
    /// 4. Majority-vote resolution across all aligned passes
    func diarizeDeep(
        audioURL: URL,
        minSpeakers: Int?,
        maxSpeakers: Int?,
        progressCallback: (@Sendable (String) -> Void)? = nil
    ) async throws -> MultiDiarizationResult {
        var passes: [DiarizationPassResult] = []

        // SpeakerKit passes: default + alternate thresholds
        for pass in speakerKitDeepReviewPasses {
            let statusLabel: String
            if let threshold = pass.threshold {
                statusLabel = "Running SpeakerKit diarization (\(pass.presetName.lowercased()), threshold \(String(format: "%.2f", threshold)))..."
            } else {
                statusLabel = "Running SpeakerKit diarization (default pyannote v4)..."
            }

            progressCallback?(statusLabel)

            do {
                let speakerKitSegments = try await speakerKitService.diarize(
                    audioURL: audioURL,
                    numberOfSpeakers: exactSpeakerCount(min: minSpeakers, max: maxSpeakers),
                    clusterDistanceThreshold: pass.threshold
                )
                passes.append(DiarizationPassResult(
                    presetName: pass.presetName,
                    engineName: "SpeakerKit",
                    segments: speakerKitSegments
                ))
            } catch {
                if pass.threshold == nil {
                    throw error
                }
                progressCallback?("SpeakerKit \(pass.presetName.lowercased()) pass failed, continuing...")
            }
        }

        // FluidAudio passes provide a second clustering family for comparison.
        progressCallback?("Running FluidAudio diarization (balanced)...")
        do {
            let balancedSegments = try await fluidAudioDiarize(
                audioURL: audioURL,
                minSpeakers: minSpeakers,
                maxSpeakers: maxSpeakers,
                threshold: DiarizationPreset.balanced.threshold,
                warmStartFa: DiarizationPreset.balanced.warmStartFa,
                warmStartFb: DiarizationPreset.balanced.warmStartFb
            )
            passes.append(DiarizationPassResult(
                presetName: "Balanced",
                engineName: "FluidAudio",
                segments: balancedSegments
            ))
        } catch {
            progressCallback?("FluidAudio balanced pass failed, continuing...")
        }

        // Pass 3: FluidAudio aggressive threshold
        progressCallback?("Running FluidAudio diarization (aggressive)...")
        do {
            let aggressiveSegments = try await fluidAudioDiarize(
                audioURL: audioURL,
                minSpeakers: minSpeakers,
                maxSpeakers: maxSpeakers,
                threshold: DiarizationPreset.aggressive.threshold,
                warmStartFa: DiarizationPreset.aggressive.warmStartFa,
                warmStartFb: DiarizationPreset.aggressive.warmStartFb
            )
            passes.append(DiarizationPassResult(
                presetName: "Aggressive",
                engineName: "FluidAudio",
                segments: aggressiveSegments
            ))
        } catch {
            progressCallback?("FluidAudio aggressive pass failed, continuing...")
        }

        // Majority-vote resolution
        let alignedPasses = alignPassesToReference(passes)
        progressCallback?("Resolving speaker assignments across \(alignedPasses.count) aligned passes...")
        let (resolved, disagreementCount) = majorityVoteResolve(passes: alignedPasses)

        return MultiDiarizationResult(
            passes: alignedPasses,
            resolved: resolved,
            disagreementCount: disagreementCount
        )
    }

    // MARK: - Legacy Multi-Threshold (FluidAudio only)

    /// Run multiple diarization passes with different clustering thresholds.
    /// Returns all individual pass results plus a majority-vote resolved result.
    func diarizeMultiple(
        audioURL: URL,
        minSpeakers: Int?,
        maxSpeakers: Int?,
        presets: [DiarizationPreset] = DiarizationPreset.deepReviewPresets,
        progressCallback: (@Sendable (Int, Int) -> Void)? = nil
    ) async throws -> MultiDiarizationResult {
        var passes: [DiarizationPassResult] = []

        for (index, preset) in presets.enumerated() {
            progressCallback?(index + 1, presets.count)

            let segments = try await fluidAudioDiarize(
                audioURL: audioURL,
                minSpeakers: minSpeakers,
                maxSpeakers: maxSpeakers,
                threshold: preset.threshold,
                warmStartFa: preset.warmStartFa,
                warmStartFb: preset.warmStartFb
            )

            passes.append(DiarizationPassResult(
                presetName: preset.name,
                engineName: "FluidAudio",
                segments: segments
            ))
        }

        let alignedPasses = alignPassesToReference(passes)
        let (resolved, disagreementCount) = majorityVoteResolve(passes: alignedPasses)

        return MultiDiarizationResult(
            passes: alignedPasses,
            resolved: resolved,
            disagreementCount: disagreementCount
        )
    }

    // MARK: - FluidAudio Helpers

    private func fluidAudioDiarize(
        audioURL: URL,
        minSpeakers: Int?,
        maxSpeakers: Int?,
        threshold: Double? = nil,
        warmStartFa: Double? = nil,
        warmStartFb: Double? = nil
    ) async throws -> [DiarizationSegment] {
        var config = OfflineDiarizerConfig.default
        if let min = minSpeakers { config.clustering.minSpeakers = min }
        if let max = maxSpeakers { config.clustering.maxSpeakers = max }
        if let t = threshold { config.clustering.threshold = t }
        if let fa = warmStartFa { config.clustering.warmStartFa = fa }
        if let fb = warmStartFb { config.clustering.warmStartFb = fb }

        let manager = OfflineDiarizerManager(config: config)
        try await manager.prepareModels()
        let result = try await manager.process(audioURL)

        return result.segments.map { segment in
            DiarizationSegment(
                speakerID: segment.speakerId,
                start: TimeInterval(segment.startTimeSeconds),
                end: TimeInterval(segment.endTimeSeconds),
                qualityScore: segment.qualityScore
            )
        }
    }

    private func alignPassesToReference(
        _ passes: [DiarizationPassResult]
    ) -> [DiarizationPassResult] {
        guard let referencePass = passes.first else { return [] }

        var alignedPasses: [DiarizationPassResult] = [referencePass]
        var reservedSpeakerIDs = Set(orderedSpeakerIDs(in: referencePass.segments))
        var nextSpeakerIndex = nextCanonicalSpeakerIndex(from: reservedSpeakerIDs)

        for pass in passes.dropFirst() {
            let mapping = speakerAlignment(
                referenceSegments: referencePass.segments,
                candidateSegments: pass.segments,
                reservedSpeakerIDs: &reservedSpeakerIDs,
                nextSpeakerIndex: &nextSpeakerIndex
            )

            let alignedSegments = pass.segments.map { segment in
                DiarizationSegment(
                    speakerID: mapping[segment.speakerID] ?? segment.speakerID,
                    start: segment.start,
                    end: segment.end,
                    qualityScore: segment.qualityScore
                )
            }

            alignedPasses.append(DiarizationPassResult(
                presetName: pass.presetName,
                engineName: pass.engineName,
                segments: alignedSegments
            ))
        }

        return alignedPasses
    }

    private func speakerAlignment(
        referenceSegments: [DiarizationSegment],
        candidateSegments: [DiarizationSegment],
        reservedSpeakerIDs: inout Set<String>,
        nextSpeakerIndex: inout Int
    ) -> [String: String] {
        let referenceSpeakers = orderedSpeakerIDs(in: referenceSegments)
        let candidateSpeakers = orderedSpeakerIDs(in: candidateSegments)
        var overlapScores: [(candidate: String, reference: String, overlap: TimeInterval)] = []

        for candidateSpeaker in candidateSpeakers {
            let candidateSpeakerSegments = candidateSegments.filter { $0.speakerID == candidateSpeaker }

            for referenceSpeaker in referenceSpeakers {
                let referenceSpeakerSegments = referenceSegments.filter { $0.speakerID == referenceSpeaker }
                let overlap = totalOverlap(
                    lhs: candidateSpeakerSegments,
                    rhs: referenceSpeakerSegments
                )

                if overlap > 0 {
                    overlapScores.append((
                        candidate: candidateSpeaker,
                        reference: referenceSpeaker,
                        overlap: overlap
                    ))
                }
            }
        }

        overlapScores.sort { lhs, rhs in
            if lhs.overlap != rhs.overlap {
                return lhs.overlap > rhs.overlap
            }

            if lhs.reference != rhs.reference {
                return lhs.reference < rhs.reference
            }

            return lhs.candidate < rhs.candidate
        }

        var mapping: [String: String] = [:]
        var usedCandidates = Set<String>()
        var usedReferences = Set<String>()

        for score in overlapScores {
            guard !usedCandidates.contains(score.candidate),
                  !usedReferences.contains(score.reference) else {
                continue
            }

            mapping[score.candidate] = score.reference
            usedCandidates.insert(score.candidate)
            usedReferences.insert(score.reference)
            reservedSpeakerIDs.insert(score.reference)
        }

        for candidateSpeaker in candidateSpeakers where mapping[candidateSpeaker] == nil {
            let canonicalSpeakerID = nextCanonicalSpeakerID(
                reservedSpeakerIDs: &reservedSpeakerIDs,
                nextSpeakerIndex: &nextSpeakerIndex
            )
            mapping[candidateSpeaker] = canonicalSpeakerID
        }

        return mapping
    }

    private func totalOverlap(
        lhs: [DiarizationSegment],
        rhs: [DiarizationSegment]
    ) -> TimeInterval {
        lhs.reduce(into: TimeInterval.zero) { total, lhsSegment in
            total += rhs.reduce(into: TimeInterval.zero) { partial, rhsSegment in
                partial += max(
                    0,
                    min(lhsSegment.end, rhsSegment.end) - max(lhsSegment.start, rhsSegment.start)
                )
            }
        }
    }

    private func orderedSpeakerIDs(in segments: [DiarizationSegment]) -> [String] {
        var orderedSpeakerIDs: [String] = []
        var seenSpeakerIDs = Set<String>()

        for segment in segments where seenSpeakerIDs.insert(segment.speakerID).inserted {
            orderedSpeakerIDs.append(segment.speakerID)
        }

        return orderedSpeakerIDs
    }

    private func nextCanonicalSpeakerIndex(from speakerIDs: Set<String>) -> Int {
        var nextIndex = 0

        while speakerIDs.contains("SPEAKER_\(nextIndex)") {
            nextIndex += 1
        }

        return nextIndex
    }

    private func nextCanonicalSpeakerID(
        reservedSpeakerIDs: inout Set<String>,
        nextSpeakerIndex: inout Int
    ) -> String {
        while reservedSpeakerIDs.contains("SPEAKER_\(nextSpeakerIndex)") {
            nextSpeakerIndex += 1
        }

        let speakerID = "SPEAKER_\(nextSpeakerIndex)"
        reservedSpeakerIDs.insert(speakerID)
        nextSpeakerIndex += 1
        return speakerID
    }

    // MARK: - Resolution

    /// Majority-vote resolution across multiple diarization passes.
    /// Uses the first pass (typically SpeakerKit) as the reference timeline.
    /// Passes are expected to be aligned into a shared speaker-ID space first.
    private func majorityVoteResolve(
        passes: [DiarizationPassResult]
    ) -> (resolved: [DiarizationSegment], disagreementCount: Int) {
        guard !passes.isEmpty else { return ([], 0) }

        // Use the first pass (SpeakerKit primary) as the reference timeline
        let referenceSegments = passes[0].segments

        var resolved: [DiarizationSegment] = []
        var disagreementCount = 0

        for refSeg in referenceSegments {
            var votes: [String: Int] = [:]
            // Give SpeakerKit (first pass) extra weight since it uses newer models
            votes[refSeg.speakerID, default: 0] += 2

            // For each other pass, find the segment with most overlap and vote
            for pass in passes.dropFirst() {
                if let bestMatch = findBestOverlap(target: refSeg, candidates: pass.segments) {
                    votes[bestMatch.speakerID, default: 0] += 1
                }
            }

            // Pick the speaker with the most votes
            let winner = votes.max(by: { $0.value < $1.value })?.key ?? refSeg.speakerID
            let allAgree = Set(votes.keys).count <= 1

            if !allAgree {
                disagreementCount += 1
            }

            resolved.append(DiarizationSegment(
                speakerID: winner,
                start: refSeg.start,
                end: refSeg.end,
                qualityScore: allAgree ? refSeg.qualityScore : refSeg.qualityScore * 0.7
            ))
        }

        return (resolved, disagreementCount)
    }

    /// Find the candidate segment with the most temporal overlap.
    private func findBestOverlap(
        target: DiarizationSegment,
        candidates: [DiarizationSegment]
    ) -> DiarizationSegment? {
        var bestOverlap: TimeInterval = 0
        var bestCandidate: DiarizationSegment?

        for candidate in candidates {
            let overlap = max(0, min(target.end, candidate.end) - max(target.start, candidate.start))
            if overlap > bestOverlap {
                bestOverlap = overlap
                bestCandidate = candidate
            }
        }

        return bestCandidate
    }

    // MARK: - Utility

    /// If min == max, use that exact count for engines that accept a single speaker count.
    private func exactSpeakerCount(min: Int?, max: Int?) -> Int? {
        // If min equals max, use exact count (strongest constraint)
        if let min, let max, min == max, min > 0 { return min }
        // If the range is very narrow (e.g., 2-3), use the minimum as a hint
        // SpeakerKit generally performs better with an exact count than with auto-detection
        if let min, let max, max - min <= 1, min > 0 { return min }
        return nil
    }
}
