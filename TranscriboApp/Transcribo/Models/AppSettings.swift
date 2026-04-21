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

/// How Deep Transcription combines outputs from multiple engines. The three
/// modes trade off speed, quality, and compute cost.
enum DeepMergeMode: String, CaseIterable, Identifiable, Codable, Sendable {
    /// Engine A flows through unchanged; Engine B runs only as a confidence signal.
    case engineAOnly
    /// Legacy word-level timestamp alignment. Known to produce garbled output on
    /// real audio; kept for A/B experimentation only.
    case confidenceWeighted
    /// Local LLM reasons over all engines' text and produces the reconciled
    /// transcript. Highest quality; adds ~30-60s per 10 minutes of audio.
    case llmReconcile

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .engineAOnly: return "Primary engine only"
        case .confidenceWeighted: return "Confidence-weighted word merge (legacy)"
        case .llmReconcile: return "LLM reconciliation (recommended)"
        }
    }

    var shortDescription: String {
        switch self {
        case .engineAOnly:
            return "Fastest. Engine A output is used as-is; Engine B only flags low-agreement regions for review."
        case .confidenceWeighted:
            return "Legacy timestamp-aligned merge. Benchmarking showed ~2× worse accuracy than the alternatives. Not recommended."
        case .llmReconcile:
            return "Highest accuracy. Local Qwen reads both engines' transcripts and produces the most accurate version. Adds ~30-60s per 10 minutes of audio."
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
    /// Default flipped to ON on April 20, 2026. Rationale: FA is the root fix
    /// for cross-speaker sentences, which are caused by ASR word-timestamp
    /// error landing on the wrong side of a diarization boundary. With
    /// Engine-A-pinned timestamps and the sentence-coherence smoother also
    /// in place, FA completes the timing-quality story for Deep Review.
    /// First invocation downloads ~500 MB of model weights to
    /// `~/Library/Caches/qwen3-speech/`; the progress is logged and failure
    /// is non-fatal (the ASR-produced timings remain in place).
    @AppStorage("enableForcedAlignment") var enableForcedAlignment: Bool = true

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
    /// - `engineAOnly` (default): Engine A flows through unchanged; Engine B runs
    ///    only for confidence flagging. Simple, fast, and measurably the best of
    ///    the non-LLM options. ~17.5% cpWER on the April 21 benchmark.
    /// - `confidenceWeighted`: the legacy word-aligner merge. Known broken on
    ///    real audio (~37% cpWER). Kept for experimentation only.
    /// - `llmReconcile`: hand the two transcripts to local Qwen and let it
    ///    reason over them. Best quality (11.53% cpWER on benchmark), costs
    ///    ~30-60s of additional compute per 10 minutes of audio.
    @AppStorage("deepMergeMode") var deepMergeModeRaw: String = DeepMergeMode.engineAOnly.rawValue
    var deepMergeMode: DeepMergeMode {
        get { DeepMergeMode(rawValue: deepMergeModeRaw) ?? .engineAOnly }
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
    /// Kept as a runtime flag — not a compile flag — so a single binary can
    /// ship both UIs during the rewrite and users (or the developer) can
    /// flip between them without rebuilding. Once the rewrite is user-
    /// verified and merged to main, the legacy UI will be deleted and this
    /// flag removed.
    @AppStorage("useRewrittenUI") var useRewrittenUI: Bool = false

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
