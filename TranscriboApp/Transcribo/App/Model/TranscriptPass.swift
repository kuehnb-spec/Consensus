import Foundation

/// One pass's worth of transcript output, stored at
/// `<project>/passes/<kind>.json`. There's at most one file per `PassKind`.
///
/// Reuses the legacy `TranscriptionSegment` type so the pipeline services
/// (FluidAsr, SpeakerKit, SegmentMerger, Patch Review, and the Manual
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

    /// Indices into `segments` that need user attention in the review view.
    /// In the current patch-centered Deep Review architecture, these are
    /// applied patch segments worth inspecting or reverting. Older archived
    /// LLM-reconcile passes used this for uncertainty flags.
    var uncertainSegmentIndices: Set<Int>

    /// Alternative text sources per uncertain segment, keyed by index into
    /// `segments`. The Phase 1d.3 review popover renders these as
    /// click-to-apply options so the user can revert a patch or compare
    /// exact alternatives. Empty for passes without review items.
    var alternativesByIndex: [Int: [TurnAlternative]]

    /// Patch-review audit notes keyed by index into `segments`. In the
    /// patch-centered Deep Review architecture, a "review" item means the
    /// tool-constrained editor changed this turn and the user may inspect
    /// or revert it. Older LLM-reconcile passes leave this empty.
    var patchReviewNotesByIndex: [Int: [PatchReviewNote]]

    /// Which engines/tools ran. Empty for `.standard` (single-engine);
    /// non-empty for `.deep` / `.verified` (patch-centered review).
    var engineAttribution: EngineAttribution

    /// Paired canonical/patched outputs. `nil` on passes that did not produce
    /// an alternate view (e.g. `.standard`); the UI renders `segments` as-is
    /// in that case.
    var styles: StylePair?

    /// Quality metrics computed at the end of the pass.
    var quality: QualitySummary

    init(
        kind: PassKind,
        createdAt: Date = Date(),
        segments: [TranscriptionSegment],
        uncertainSegmentIndices: Set<Int> = [],
        alternativesByIndex: [Int: [TurnAlternative]] = [:],
        patchReviewNotesByIndex: [Int: [PatchReviewNote]] = [:],
        engineAttribution: EngineAttribution = EngineAttribution(),
        styles: StylePair? = nil,
        quality: QualitySummary = QualitySummary()
    ) {
        self.kind = kind
        self.createdAt = createdAt
        self.segments = segments
        self.uncertainSegmentIndices = uncertainSegmentIndices
        self.alternativesByIndex = alternativesByIndex
        self.patchReviewNotesByIndex = patchReviewNotesByIndex
        self.engineAttribution = engineAttribution
        self.styles = styles
        self.quality = quality
    }

    enum CodingKeys: String, CodingKey {
        case kind
        case createdAt
        case segments
        case uncertainSegmentIndices
        case alternativesByIndex
        case patchReviewNotesByIndex
        case engineAttribution
        case styles
        case quality
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.kind = try c.decode(PassKind.self, forKey: .kind)
        self.createdAt = try c.decode(Date.self, forKey: .createdAt)
        self.segments = try c.decode([TranscriptionSegment].self, forKey: .segments)
        self.uncertainSegmentIndices = try c.decodeIfPresent(Set<Int>.self, forKey: .uncertainSegmentIndices) ?? []
        self.alternativesByIndex = try c.decodeIfPresent([Int: [TurnAlternative]].self, forKey: .alternativesByIndex) ?? [:]
        self.patchReviewNotesByIndex = try c.decodeIfPresent([Int: [PatchReviewNote]].self, forKey: .patchReviewNotesByIndex) ?? [:]
        self.engineAttribution = try c.decodeIfPresent(EngineAttribution.self, forKey: .engineAttribution) ?? EngineAttribution()
        self.styles = try c.decodeIfPresent(StylePair.self, forKey: .styles)
        self.quality = try c.decodeIfPresent(QualitySummary.self, forKey: .quality) ?? QualitySummary()
    }
}

/// One click-to-apply option in the uncertainty popover. Phase 1d.3 sources
/// these from exact patch-review events. Archived LLM-reconcile passes may
/// still carry Engine A / Engine B alternatives.
struct TurnAlternative: Codable, Hashable, Sendable {
    /// Where the text came from ("Engine A (Parakeet)", "Engine B
    /// (Whisper Large v3)", "Original VibeVoice", …). Displayed as a
    /// small label in the popover.
    let source: String

    /// The candidate text the user can accept.
    let text: String
}

/// One tool-constrained edit that changed a Deep Review pass. These notes are
/// intentionally patch-shaped rather than transcript-shaped so the UI can show
/// exactly what was changed and why.
struct PatchReviewNote: Codable, Hashable, Sendable {
    /// `v6_local_relisten`, `v8_masked_cloze`, or another future tool stage.
    let stage: String

    /// Human-readable source label for the tool that made the change.
    let source: String

    /// Exact phrase found in the prior segment text.
    let find: String

    /// Exact phrase inserted by the patch editor.
    let replace: String

    /// Optional verifier confidence. Local re-listen patches may not have one.
    let confidence: Double?

    /// Short audit reason emitted by the verifier.
    let reason: String?
}

// MARK: - Engine attribution

struct EngineAttribution: Codable, Hashable, Sendable {
    /// Display name of the engine whose word stream backs this pass' text
    /// (e.g. "Parakeet", "Whisper Large v3").
    var primaryEngine: String

    /// Display names of additional engines/tools whose output fed the review,
    /// if any.
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

/// Two versions of each turn. In Patch Review, `verbatimText` is the
/// original canonical transcript and `cleanText` is the patched result. The
/// user toggles between them in the transcript header; the choice is
/// remembered per-project (on `ProjectSettings.transcriptStyle`).
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

    /// Count of patch-review segments in the pass. Used by the review badge
    /// counter.
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
