import SwiftUI

struct ProjectTemplate: Codable, Identifiable, Sendable {
    let id: UUID
    var name: String
    var model: String  // WhisperModel rawValue
    var minSpeakers: Int
    var maxSpeakers: Int
    var language: String

    init(id: UUID = UUID(), name: String, model: String, minSpeakers: Int, maxSpeakers: Int, language: String = "en") {
        self.id = id
        self.name = name
        self.model = model
        self.minSpeakers = minSpeakers
        self.maxSpeakers = maxSpeakers
        self.language = language
    }

    static let defaults: [ProjectTemplate] = [
        ProjectTemplate(name: "Phone Call (2 speakers)", model: WhisperModel.largeV3.rawValue, minSpeakers: 2, maxSpeakers: 2),
        ProjectTemplate(name: "Interview (2-3 speakers)", model: WhisperModel.largeV3.rawValue, minSpeakers: 2, maxSpeakers: 3),
        ProjectTemplate(name: "Meeting (3-8 speakers)", model: WhisperModel.medium.rawValue, minSpeakers: 3, maxSpeakers: 8),
        ProjectTemplate(name: "Quick Draft", model: WhisperModel.small.rawValue, minSpeakers: 0, maxSpeakers: 0),
    ]
}

/// How Deep Transcription combines outputs from multiple engines. The four
/// modes trade off speed, quality, and compute cost.
enum DeepMergeMode: String, CaseIterable, Identifiable, Codable, Sendable {
    /// Engine A flows through unchanged; Engine B runs only as a confidence signal.
    case engineAOnly
    /// Legacy word-level timestamp alignment. Known to produce garbled output on
    /// real audio; kept for A/B experimentation only.
    case confidenceWeighted
    /// Start from Engine A, then ask the LLM to judge ONLY the windows where
    /// Engine A and Engine B substantively disagree. Fast because the LLM reads
    /// only the disagreements, not the whole transcript; accurate because those
    /// disagreements are exactly where Engine A tends to be wrong.
    case llmJudgment
    /// Local LLM reasons over all engines' complete transcripts and produces the
    /// reconciled output end-to-end. Highest quality; adds ~30-60s per 10 minutes.
    case llmReconcile

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .engineAOnly: return "Primary engine only"
        case .confidenceWeighted: return "Confidence-weighted word merge (legacy)"
        case .llmJudgment: return "LLM judgment on disputes (recommended)"
        case .llmReconcile: return "LLM full reconciliation"
        }
    }

    var shortDescription: String {
        switch self {
        case .engineAOnly:
            return "Fastest. Engine A output is used as-is; Engine B only flags low-agreement regions for review."
        case .confidenceWeighted:
            return "Legacy timestamp-aligned merge. Benchmarking showed ~2× worse accuracy than the alternatives. Not recommended."
        case .llmJudgment:
            return "Best balance. Start from Engine A, then ask the local LLM to pick between A and B only where they substantively disagree. Adds ~5-15s per 10 minutes of audio."
        case .llmReconcile:
            return "Slowest but most thorough. Local Qwen reads both engines' full transcripts and writes a single reconciled version. Adds ~30-60s per 10 minutes of audio."
        }
    }
}

final class AppSettings: ObservableObject {
    @AppStorage("preferredModel") var preferredModel: String = WhisperModel.small.rawValue
    @AppStorage("defaultMinSpeakers") var defaultMinSpeakers: Int = 2
    @AppStorage("defaultMaxSpeakers") var defaultMaxSpeakers: Int = 6
    @AppStorage("defaultLanguage") var defaultLanguage: String = "en"
    @AppStorage("hasSeenWelcomeTour") var hasSeenWelcomeTour: Bool = false
    @AppStorage("isSimpleMode") var isSimpleMode: Bool = true

    /// When enabled, Deep Transcription runs a forced-alignment stage
    /// (Qwen3-ForcedAligner via speech-swift) after merging Engine A and
    /// Engine B so that downstream stages — Deep Diarization, subtitle
    /// export, flag ranges — consume audio-grounded word timings rather
    /// than the ASR engines' own (often cross-attention-derived) estimates.
    ///
    /// Default flipped back to OFF on April 23, 2026. Rationale: on real
    /// phone-call audio, Qwen3-ForcedAligner produces 15-26% zero-duration
    /// or non-monotonic word timings, and downstream code that re-sorted
    /// the word stream by start time after FA interleaved words from
    /// different points in the conversation — the "scrambled sentences"
    /// regression in the 2026-04-22 Larsen call. A/B comparison confirmed
    /// FA-off reads cleanly across all 21 segments. FA can be re-enabled
    /// manually for experimentation, but the default is now the safe path:
    /// Engine A's native word timings flow through unmodified.
    /// First invocation downloads ~500 MB of model weights to
    /// `~/Library/Caches/qwen3-speech/`; the progress is logged and failure
    /// is non-fatal (the ASR-produced timings remain in place).
    @AppStorage("enableForcedAlignment") var enableForcedAlignment: Bool = false

    /// Tracks whether the user has been shown the model-download confirmation
    /// when enabling `enableForcedAlignment` for the first time. The first
    /// flip from off → on downloads ~500 MB of Qwen3-ForcedAligner weights
    /// to `~/Library/Caches/qwen3-speech/`; we only warn the user once.
    @AppStorage("hasSeenForcedAlignmentWarning") var hasSeenForcedAlignmentWarning: Bool = false

    /// When enabled, the Deep Review pipeline emits per-change diagnostic entries
    /// into the process log — every smoother reassignment, every LLM boundary
    /// confirmation/rejection, every FA word-move. A "Save Diagnostic Report"
    /// button in the Process Log view writes the full log to a markdown file.
    /// Intended for investigating specific cases where the pipeline produces an
    /// unexpected result; off by default so production runs stay readable.
    @AppStorage("diagnosticModeEnabled") var diagnosticModeEnabled: Bool = false

    /// When enabled, the Deep Transcription step runs the legacy confidence-weighted
    /// word merge between Engine A and Engine B. Benchmarking on April 21, 2026
    /// against a hand-corrected transcript showed that this merge produces a 2-3×
    /// worse cpWER than Engine A alone, because its timestamp-based alignment
    /// interleaves words from both engines when the timestamps disagree even
    /// slightly. Defaulted OFF. When off and `deepMergeMode` is `.engineAOnly`,
    /// Engine A's word stream flows through unmodified. When `deepMergeMode` is
    /// `.llmReconcile`, a local Qwen run reconciles the two transcripts at the
    /// content level — the approach that produced 11.53% cpWER in benchmarks.
    @AppStorage("useConfidenceMerge") var useConfidenceMerge: Bool = false

    /// How Deep Transcription combines Engine A and Engine B.
    ///
    /// - `engineAOnly`: Engine A flows through unchanged; Engine B runs only
    ///    for confidence flagging. Simple, fast. ~17.5% cpWER on the April 21
    ///    benchmark.
    /// - `confidenceWeighted`: the legacy word-aligner merge. Known broken on
    ///    real audio (~37% cpWER). Kept for experimentation only.
    /// - `llmJudgment` (default as of April 23, 2026): start from Engine A,
    ///    then ask the local LLM to pick between A and B only where they
    ///    substantively disagree. Fast and accurate because the LLM reads only
    ///    the disagreements — the specific regions where Engine A tends to err.
    /// - `llmReconcile`: hand both complete transcripts to local Qwen and let
    ///    it write a fully reconciled version. Best quality on benchmarks
    ///    (11.53% cpWER), but ~30-60s of extra compute per 10 minutes of audio.
    @AppStorage("deepMergeMode") var deepMergeModeRaw: String = DeepMergeMode.llmJudgment.rawValue
    var deepMergeMode: DeepMergeMode {
        get { DeepMergeMode(rawValue: deepMergeModeRaw) ?? .llmJudgment }
        set { deepMergeModeRaw = newValue.rawValue }
    }

    var preferredWhisperModel: WhisperModel {
        get { WhisperModel(rawValue: preferredModel) ?? .small }
        set { preferredModel = newValue.rawValue }
    }

    /// Master switch for the Phase 0+ UI rewrite. When `false` (default),
    /// the app continues to render the legacy SwiftUI surface exactly as
    /// shipped in the April 21, 2026 build. When `true`, the rewritten
    /// three-mode surface (Quick Take / Deep Read / Studio) takes over.
    ///
    /// Default flipped to `true` on 2026-04-23: the rewrite is now the
    /// primary UI. The legacy surface remains reachable via the Settings
    /// toggle as a one-project safety net; once the user has verified the
    /// rewrite on a real project (Larsen call), the legacy UI and this
    /// flag will be deleted and the branch merged to main.
    @AppStorage("useRewrittenUI") var useRewrittenUI: Bool = true

    /// Default mode for new projects in the rewritten UI (Quick Take /
    /// Deep Read / Studio). Persists across launches so a user who always
    /// uses Quick Take doesn't have to re-pick every time.
    @AppStorage("rewrittenDefaultMode") var rewrittenDefaultModeRaw: String = "deepRead"

    @AppStorage("projectTemplates") var projectTemplatesData: Data = Data()

    /// Saved project setting templates.
    var projectTemplates: [ProjectTemplate] {
        get {
            (try? JSONDecoder().decode([ProjectTemplate].self, from: projectTemplatesData)) ?? ProjectTemplate.defaults
        }
        set {
            projectTemplatesData = (try? JSONEncoder().encode(newValue)) ?? Data()
        }
    }

    /// Auto-select the best transcription model based on system RAM.
    var autoSelectedModel: WhisperModel {
        let ramGB = ProcessInfo.processInfo.physicalMemory / (1024 * 1024 * 1024)
        if ramGB >= 32 { return .largeV3 }
        if ramGB >= 16 { return .medium }
        if ramGB >= 8 { return .small }
        return .base
    }
}
