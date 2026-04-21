import Foundation

/// The top-level project model for the rewritten UI. Replaces the prior
/// sprawling `TranscriptionProject`.
///
/// On-disk layout (one directory per project, under
/// `~/Library/Application Support/Consensus/Projects/<UUID>/`):
///
/// ```
/// project.json        – this file, encoded
/// audio.m4a           – soft link to the user's audio (copy fallback)
/// passes/
///   standard.json     – Engine A alone
///   deep.json         – LLM reconciled
///   verified.json     – Studio-tier higher-quality pass (optional)
///   manual.json       – user-edited version (optional)
/// summary.json        – editable summary + todos + user instructions
/// exports/            – history of exported files
/// ```
///
/// Phase 0 defines the shape. The ViewModels that read and write this model
/// arrive in Phase 1.
struct ProjectDocument: Codable, Identifiable, Hashable, Sendable {
    /// Stable project UUID. Also used as the directory name.
    let id: UUID

    /// User-visible name. Defaults to the audio file's name (without extension).
    var title: String

    /// Creation timestamp of the project itself (not the recording).
    let createdAt: Date

    /// Last modification timestamp of anything under the project directory.
    var updatedAt: Date

    /// The audio file backing the project. `url` is the original path; when the
    /// file is inside the project directory it's `audio.<ext>`. `durationSeconds`
    /// is cached from the asset probe.
    var audio: AudioAsset

    /// Speaker roster — the names (auto-detected or user-typed) plus the
    /// `SPEAKER_N` IDs emitted by the diarizer.
    var speakers: [Speaker]

    /// Active mode for this project. Persisted so the user returns to the same
    /// surface they left — switching modes is a UI act, not a pipeline act.
    var mode: ModeState

    /// Project-level pipeline settings. The per-mode UI layers its own
    /// controls on top of these.
    var settings: ProjectSettings

    /// Names, terms, and spellings the user has confirmed. Grows as the user
    /// answers LLM questions in interactive review.
    var lexicon: ProjectLexicon

    /// Which pass the user is currently viewing / exporting. `deep` is the
    /// default produced by LLM reconciliation.
    var activePass: PassKind

    /// Export history — grows via `ExportService`.
    var exports: [ExportEntry]

    init(
        id: UUID = UUID(),
        title: String,
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        audio: AudioAsset,
        speakers: [Speaker] = [],
        mode: ModeState = .default,
        settings: ProjectSettings = ProjectSettings(),
        lexicon: ProjectLexicon = ProjectLexicon(),
        activePass: PassKind = .deep,
        exports: [ExportEntry] = []
    ) {
        self.id = id
        self.title = title
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.audio = audio
        self.speakers = speakers
        self.mode = mode
        self.settings = settings
        self.lexicon = lexicon
        self.activePass = activePass
        self.exports = exports
    }
}

// MARK: - Audio

struct AudioAsset: Codable, Hashable, Sendable {
    /// Original path the user dropped, for display. The project directory may
    /// contain a soft link at `audio.<ext>` pointing here (or a copy fallback).
    var originalURL: URL

    /// Relative filename inside the project directory (e.g. `audio.m4a`).
    /// `nil` until the project is persisted.
    var localFilename: String?

    /// Duration of the recording in seconds.
    var durationSeconds: Double

    /// When the recording began. Derived as
    /// `(audio container creation_time) − durationSeconds` — the metadata's
    /// creation_time represents when the file was finalised (end of recording).
    /// Falls back to the filesystem creation date only if container metadata
    /// is missing. Kept intact from the prior `TranscriptionService`.
    var recordingStartTime: Date?

    /// Content hash (SHA-256) of the raw audio bytes. Used to detect when an
    /// incoming drop is a re-import of something already in the library.
    var contentHash: String?
}

// MARK: - Speakers

struct Speaker: Codable, Hashable, Identifiable, Sendable {
    /// The diarizer-emitted ID: `SPEAKER_0`, `SPEAKER_1`, …
    let id: String

    /// User-facing name. Auto-filled by the "Hi, this is X" scan or by a
    /// voice-library match, then confirmed or corrected on the speaker
    /// naming screen.
    var displayName: String

    /// Cross-reference to the voice library. `nil` if this speaker was not
    /// matched against any stored voiceprint.
    var voiceLibraryID: UUID?

    /// Whether the user has confirmed the name (versus accepting the
    /// auto-suggestion silently).
    var isConfirmed: Bool

    /// Index into `ConsensusTheme.Colors.speakerPalette`. Assigned when the
    /// speaker first appears; sticky for the life of the project.
    var paletteIndex: Int
}

// MARK: - Pipeline passes

/// Which pipeline pass produced a transcript. One project may have several of
/// these on disk at once (for comparison in Studio), but only `activePass` is
/// shown by default.
enum PassKind: String, Codable, CaseIterable, Hashable, Sendable {
    /// Engine A alone. Fastest. The Quick Take floor.
    case standard

    /// Engine A + Engine B reconciled by a local LLM. Default output of Deep
    /// Read; the April 21 benchmark ceiling (~11.5% cpWER).
    case deep

    /// Studio-tier higher quality — adds known-names, domain hint, forced
    /// alignment, potentially additional engines. Projected ~7–8% cpWER.
    case verified

    /// User-edited version produced via the Manual Editor. When present,
    /// overrides the other passes for export.
    case manual

    /// Filename inside `<project>/passes/`.
    var filename: String { "\(rawValue).json" }

    var displayName: String {
        switch self {
        case .standard: return "Standard"
        case .deep:     return "Deep"
        case .verified: return "Verified"
        case .manual:   return "Manual"
        }
    }
}

// MARK: - Settings

struct ProjectSettings: Codable, Hashable, Sendable {
    /// Domain hint fed to the LLM reconciliation prompt. `general` is the
    /// neutral default; `.custom` carries a free-text override.
    var domainHint: DomainHint

    /// Whether the user has opted into the summary pane for this project.
    var includeSummary: Bool

    /// Whether the user has opted into the to-dos pane for this project.
    var includeTodos: Bool

    /// Verbatim (stutter/filler preserved) vs. clean (grammar-smoothed).
    /// Both versions are generated in one LLM pass; this flag records which
    /// one the user last viewed.
    var transcriptStyle: TranscriptStyle

    init(
        domainHint: DomainHint = .general,
        includeSummary: Bool = false,
        includeTodos: Bool = false,
        transcriptStyle: TranscriptStyle = .clean
    ) {
        self.domainHint = domainHint
        self.includeSummary = includeSummary
        self.includeTodos = includeTodos
        self.transcriptStyle = transcriptStyle
    }
}

enum DomainHint: Codable, Hashable, Sendable {
    case general
    case legal
    case medical
    case technical
    case business
    case custom(String)

    /// Short token used in the LLM prompt.
    var promptToken: String {
        switch self {
        case .general:          return "general"
        case .legal:            return "legal"
        case .medical:          return "medical"
        case .technical:        return "technical"
        case .business:         return "business"
        case .custom(let text): return text
        }
    }
}

enum TranscriptStyle: String, Codable, CaseIterable, Hashable, Sendable {
    case verbatim
    case clean

    var displayName: String {
        switch self {
        case .verbatim: return "Verbatim"
        case .clean:    return "Clean"
        }
    }
}

// MARK: - Lexicon

/// Proper nouns, domain terms, and spellings the user has confirmed during
/// interactive review. Fed back into the LLM prompt on subsequent passes and
/// on future projects (via `VoiceLibrary` when the same speaker appears).
struct ProjectLexicon: Codable, Hashable, Sendable {
    /// Preferred spellings, e.g. `["Brant Kuehn", "scienter", "Kirby"]`.
    var terms: [String]

    /// Per-term source: which question prompted the addition. Optional.
    var provenance: [String: String]

    init(terms: [String] = [], provenance: [String: String] = [:]) {
        self.terms = terms
        self.provenance = provenance
    }
}

// MARK: - Exports

struct ExportEntry: Codable, Identifiable, Hashable, Sendable {
    let id: UUID
    let format: String
    let exportedAt: Date
    let destinationPath: String
    let includedSummary: Bool

    init(
        id: UUID = UUID(),
        format: String,
        exportedAt: Date = Date(),
        destinationPath: String,
        includedSummary: Bool = false
    ) {
        self.id = id
        self.format = format
        self.exportedAt = exportedAt
        self.destinationPath = destinationPath
        self.includedSummary = includedSummary
    }
}

// MARK: - On-disk paths

/// Pure path resolver — constructs the canonical paths for a project. Does
/// not touch the filesystem. I/O moves into the ViewModel layer in Phase 1.
struct ProjectPaths: Sendable {
    let root: URL

    /// The default library location:
    /// `~/Library/Application Support/Consensus/Projects/`
    static func libraryRoot() throws -> URL {
        let support = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        return support
            .appendingPathComponent("Consensus", isDirectory: true)
            .appendingPathComponent("Projects", isDirectory: true)
    }

    init(root: URL) {
        self.root = root
    }

    init(projectID: UUID, within root: URL) {
        self.root = root.appendingPathComponent(projectID.uuidString, isDirectory: true)
    }

    var projectJSON: URL    { root.appendingPathComponent("project.json") }
    var summaryJSON: URL    { root.appendingPathComponent("summary.json") }
    var passesDirectory: URL { root.appendingPathComponent("passes", isDirectory: true) }
    var exportsDirectory: URL { root.appendingPathComponent("exports", isDirectory: true) }

    func pass(_ kind: PassKind) -> URL {
        passesDirectory.appendingPathComponent(kind.filename)
    }
}

// MARK: - Summary document

/// The editable summary + to-dos, stored alongside `project.json` as
/// `summary.json`. Survives transcript regeneration: user edits are preserved
/// unless they explicitly accept overwrite.
struct SummaryDocument: Codable, Hashable, Sendable {
    /// Editable summary text. Markdown-rendered in the UI.
    var summary: String

    /// Ordered to-do items. `owner` is the speaker ID the item is attributed
    /// to, resolved at display time against the project's speaker roster.
    var todos: [TodoItem]

    /// User-supplied extra guidance for the LLM ("Focus on financial
    /// commitments", "Write in a casual tone", …). Studio-only UI but stored
    /// for all modes so the value survives mode changes.
    var specialInstructions: String

    /// Chosen summary length. Studio-only UI; default on other modes.
    var length: SummaryLength

    /// Regeneration timestamps, so the UI can show "Regenerated 2m ago".
    var summaryRegeneratedAt: Date?
    var todosRegeneratedAt: Date?

    /// Tracks whether the user has edited each section since the last
    /// regeneration — used to confirm overwrite intent.
    var summaryEditedByUser: Bool
    var todosEditedByUser: Bool

    init(
        summary: String = "",
        todos: [TodoItem] = [],
        specialInstructions: String = "",
        length: SummaryLength = .brief,
        summaryRegeneratedAt: Date? = nil,
        todosRegeneratedAt: Date? = nil,
        summaryEditedByUser: Bool = false,
        todosEditedByUser: Bool = false
    ) {
        self.summary = summary
        self.todos = todos
        self.specialInstructions = specialInstructions
        self.length = length
        self.summaryRegeneratedAt = summaryRegeneratedAt
        self.todosRegeneratedAt = todosRegeneratedAt
        self.summaryEditedByUser = summaryEditedByUser
        self.todosEditedByUser = todosEditedByUser
    }
}

struct TodoItem: Codable, Identifiable, Hashable, Sendable {
    let id: UUID
    var text: String
    var ownerSpeakerID: String?
    var isDone: Bool

    init(id: UUID = UUID(), text: String, ownerSpeakerID: String? = nil, isDone: Bool = false) {
        self.id = id
        self.text = text
        self.ownerSpeakerID = ownerSpeakerID
        self.isDone = isDone
    }
}

enum SummaryLength: String, Codable, CaseIterable, Hashable, Sendable {
    case highLevel
    case brief
    case detailed

    var displayName: String {
        switch self {
        case .highLevel: return "High-level"
        case .brief:     return "Brief"
        case .detailed:  return "Detailed"
        }
    }
}
