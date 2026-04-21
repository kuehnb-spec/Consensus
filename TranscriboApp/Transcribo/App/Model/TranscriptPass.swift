import Foundation

/// One pass's worth of transcript output, stored at
/// `<project>/passes/<kind>.json`. There's at most one file per `PassKind`.
///
/// Reuses the legacy `TranscriptionSegment` type so the pipeline services
/// (FluidAsr, SpeakerKit, SegmentMerger, LLMReconcile, and the Manual
/// Editor codec) can feed and read this without any conversion.
///
/// This is the new-UI equivalent of the legacy `TranscriptionPass`, kept
/// separate so the new code can evolve independently. Migration from the
/// legacy type into this one lives in a future slice.
struct TranscriptPass: Codable, Sendable {
    /// Which pipeline tier produced this pass.
    let kind: PassKind

    /// When the pass completed on disk. Every successful run overwrites the
    /// existing file and refreshes this stamp.
    let createdAt: Date

    /// Segments in time order.
    var segments: [TranscriptionSegment]

    /// Which engines ran. Empty for `.standard` (single-engine); non-empty
    /// for `.deep` / `.verified` (multi-engine reconciliation).
    var engineAttribution: EngineAttribution

    /// Paired verbatim/clean outputs from a single LLM reconciliation pass.
    /// `nil` on passes that didn't involve the LLM (e.g. `.standard`); the
    /// UI renders `segments` as-is in that case.
    var styles: StylePair?

    /// Quality metrics computed at the end of the pass.
    var quality: QualitySummary

    init(
        kind: PassKind,
        createdAt: Date = Date(),
        segments: [TranscriptionSegment],
        engineAttribution: EngineAttribution = EngineAttribution(),
        styles: StylePair? = nil,
        quality: QualitySummary = QualitySummary()
    ) {
        self.kind = kind
        self.createdAt = createdAt
        self.segments = segments
        self.engineAttribution = engineAttribution
        self.styles = styles
        self.quality = quality
    }
}

// MARK: - Engine attribution

struct EngineAttribution: Codable, Hashable, Sendable {
    /// Display name of the engine whose word stream backs this pass' text
    /// (e.g. "Parakeet", "Whisper Large v3").
    var primaryEngine: String

    /// Display names of additional engines whose output fed the LLM
    /// reconciliation, if any.
    var supportingEngines: [String]

    /// Diarizer used ("SpeakerKit-pyannote-v4", "FluidAudio Sortformer", …).
    var diarizer: String?

    /// Language hint passed to the ASR engines (e.g. "en").
    var language: String

    init(
        primaryEngine: String = "",
        supportingEngines: [String] = [],
        diarizer: String? = nil,
        language: String = "en"
    ) {
        self.primaryEngine = primaryEngine
        self.supportingEngines = supportingEngines
        self.diarizer = diarizer
        self.language = language
    }
}

// MARK: - Verbatim / clean

/// Two versions of each turn, produced by a single LLM reconciliation pass
/// per the rewrite plan's "simultaneous generation" design. The user
/// toggles between them in the transcript header; the choice is remembered
/// per-project (on `ProjectSettings.transcriptStyle`).
struct StylePair: Codable, Hashable, Sendable {
    /// Stutters, fillers, "um"s, repetitions preserved.
    var verbatimText: [String]

    /// Grammar-smoothed, fillers removed, readable prose.
    var cleanText: [String]

    /// `true` iff the arrays are the same length as the pass's `segments`
    /// and each index aligns turn-for-turn.
    var isAligned: Bool { verbatimText.count == cleanText.count }
}

// MARK: - Quality summary

struct QualitySummary: Codable, Hashable, Sendable {
    /// Diarization confidence (0–1), averaged across segments. `nil` when
    /// no diarizer ran or when the diarizer didn't emit a quality score.
    var diarizationConfidence: Double?

    /// Count of LLM-flagged uncertain segments in the pass. Used by the
    /// review badge counter ("3 to review").
    var uncertainSegmentCount: Int

    /// Stage timings in seconds, keyed by stage name. Helpful for Studio's
    /// Pipeline Inspector.
    var stageTimings: [String: Double]

    init(
        diarizationConfidence: Double? = nil,
        uncertainSegmentCount: Int = 0,
        stageTimings: [String: Double] = [:]
    ) {
        self.diarizationConfidence = diarizationConfidence
        self.uncertainSegmentCount = uncertainSegmentCount
        self.stageTimings = stageTimings
    }
}
