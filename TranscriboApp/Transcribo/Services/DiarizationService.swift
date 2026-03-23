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

    // MARK: - Single-Engine Diarization

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
    /// 1. SpeakerKit (primary, best accuracy) — one pass
    /// 2. FluidAudio with multiple thresholds — provides independent comparison
    /// 3. Majority-vote resolution across all passes
    func diarizeDeep(
        audioURL: URL,
        minSpeakers: Int?,
        maxSpeakers: Int?,
        progressCallback: (@Sendable (String) -> Void)? = nil
    ) async throws -> MultiDiarizationResult {
        var passes: [DiarizationPassResult] = []

        // Pass 1: SpeakerKit (primary, pyannote v4)
        progressCallback?("Running SpeakerKit diarization (pyannote v4)...")
        let speakerKitSegments = try await speakerKitService.diarize(
            audioURL: audioURL,
            numberOfSpeakers: exactSpeakerCount(min: minSpeakers, max: maxSpeakers)
        )
        passes.append(DiarizationPassResult(
            presetName: "Primary",
            engineName: "SpeakerKit",
            segments: speakerKitSegments
        ))

        // Pass 2: FluidAudio balanced threshold
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
        progressCallback?("Resolving speaker assignments across \(passes.count) passes...")
        let (resolved, disagreementCount) = majorityVoteResolve(passes: passes)

        return MultiDiarizationResult(
            passes: passes,
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

        let (resolved, disagreementCount) = majorityVoteResolve(passes: passes)

        return MultiDiarizationResult(
            passes: passes,
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

    // MARK: - Resolution

    /// Majority-vote resolution across multiple diarization passes.
    /// Uses the first pass (typically SpeakerKit) as the reference timeline.
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
        guard let min, let max, min == max, min > 0 else { return nil }
        return min
    }
}
