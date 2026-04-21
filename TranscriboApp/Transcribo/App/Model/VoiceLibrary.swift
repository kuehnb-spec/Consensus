import Foundation

/// A persistent roster of known voices. Each entry pairs a speaker embedding
/// with a display name, a short sample clip, and the list of projects where
/// the voice has appeared. During transcription the diarizer's embeddings
/// are compared against this library to pre-fill the speaker naming screen.
///
/// On-disk layout (under `~/Library/Application Support/Consensus/VoiceLibrary/`):
///
/// ```
/// library.json        – index of all entries (this type, Codable)
/// samples/
///   <voice-uuid>.wav  – 2–5s audio sample per voice
/// ```
///
/// Phase 0 defines the data model and disk layout. Embedding extraction
/// (SpeakerKit) and matching (cosine similarity) arrive in Phase 4.
struct VoiceLibrary: Codable, Sendable {
    /// Schema version — lets us migrate the format later without breaking
    /// existing installs.
    var schemaVersion: Int

    /// All known voices.
    var voices: [VoiceIdentity]

    /// Last modification timestamp.
    var updatedAt: Date

    init(
        schemaVersion: Int = VoiceLibrary.currentSchemaVersion,
        voices: [VoiceIdentity] = [],
        updatedAt: Date = Date()
    ) {
        self.schemaVersion = schemaVersion
        self.voices = voices
        self.updatedAt = updatedAt
    }

    static let currentSchemaVersion: Int = 1
}

// MARK: - Voice identity

struct VoiceIdentity: Codable, Identifiable, Hashable, Sendable {
    let id: UUID

    /// The name shown on the speaker naming screen when this voice matches.
    var displayName: String

    /// Relative path to the sample clip under `VoiceLibrary/samples/`. The
    /// convention is `<id>.wav`, but the field is explicit so the library
    /// survives a move to a different audio format.
    var sampleRelativePath: String

    /// 256-float speaker embedding produced by SpeakerKit. Extracted from
    /// the highest-confidence contiguous region in the source project.
    var embedding: [Float]

    /// Projects the voice has appeared in, newest first. Powers the "Speakers
    /// → projects" filter in the Project Library window.
    var projectAppearances: [ProjectAppearance]

    /// User-applied tags. `.myVoice` is special: it gets the highest match
    /// priority during transcription so the library owner is always identified.
    var tags: Set<VoiceTag>

    /// How confident the auto-suggestion was when this voice was created. A
    /// value between 0 and 1. Lower confidences prompt an extra review step.
    var initialConfidence: Double

    /// Entry creation and last-match timestamps.
    let createdAt: Date
    var lastSeenAt: Date

    init(
        id: UUID = UUID(),
        displayName: String,
        sampleRelativePath: String,
        embedding: [Float],
        projectAppearances: [ProjectAppearance] = [],
        tags: Set<VoiceTag> = [],
        initialConfidence: Double = 1.0,
        createdAt: Date = Date(),
        lastSeenAt: Date = Date()
    ) {
        self.id = id
        self.displayName = displayName
        self.sampleRelativePath = sampleRelativePath
        self.embedding = embedding
        self.projectAppearances = projectAppearances
        self.tags = tags
        self.initialConfidence = initialConfidence
        self.createdAt = createdAt
        self.lastSeenAt = lastSeenAt
    }
}

struct ProjectAppearance: Codable, Hashable, Sendable {
    /// Matching `ProjectDocument.id`.
    let projectID: UUID

    /// The speaker slot the voice occupied in that project, e.g. `SPEAKER_0`.
    let speakerID: String

    /// When the voice was last observed in that project.
    let seenAt: Date
}

/// Predefined tags that carry meaning to the matcher. Free-form user tags
/// can live alongside these via `.custom`.
enum VoiceTag: Codable, Hashable, Sendable {
    /// The library owner's own voice. Highest match priority.
    case myVoice
    case frequentCaller
    case client
    case colleague
    case family
    case custom(String)

    var displayName: String {
        switch self {
        case .myVoice:          return "My voice"
        case .frequentCaller:   return "Frequent caller"
        case .client:           return "Client"
        case .colleague:        return "Colleague"
        case .family:           return "Family"
        case .custom(let text): return text
        }
    }
}

// MARK: - On-disk paths

/// Pure path resolver for the voice library. Filesystem I/O lives in the
/// Phase 4 service wrapper — this type only tells you where things live.
struct VoiceLibraryPaths: Sendable {
    let root: URL

    /// `~/Library/Application Support/Consensus/VoiceLibrary/`
    static func libraryRoot() throws -> URL {
        let support = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        return support
            .appendingPathComponent("Consensus", isDirectory: true)
            .appendingPathComponent("VoiceLibrary", isDirectory: true)
    }

    init(root: URL) {
        self.root = root
    }

    var indexJSON: URL { root.appendingPathComponent("library.json") }
    var samplesDirectory: URL { root.appendingPathComponent("samples", isDirectory: true) }

    func sample(for voice: VoiceIdentity) -> URL {
        samplesDirectory.appendingPathComponent(voice.sampleRelativePath)
    }
}

// MARK: - Matching

/// Result of comparing a new embedding against the library. Emitted by the
/// Phase 4 matcher so the speaker naming screen can pre-fill names and show
/// a confidence indicator.
struct VoiceMatch: Sendable {
    let voiceID: UUID
    let displayName: String
    /// Cosine similarity, in `[-1, 1]`. Higher is closer.
    let similarity: Double
    /// Whether the `myVoice` tag boosted this match's priority.
    let boostedByMyVoice: Bool
}

extension VoiceLibrary {
    /// Computes cosine similarity of `embedding` against every stored voice.
    /// Returns matches sorted descending by similarity. `.myVoice`-tagged
    /// entries get a small additive boost so the library owner wins ties.
    ///
    /// Callers apply their own acceptance threshold. A reasonable starting
    /// point based on SpeakerKit embeddings is `similarity >= 0.65`.
    func matches(for embedding: [Float], myVoiceBoost: Double = 0.05) -> [VoiceMatch] {
        guard !embedding.isEmpty else { return [] }
        return voices.compactMap { voice -> VoiceMatch? in
            guard voice.embedding.count == embedding.count else { return nil }
            let sim = Self.cosineSimilarity(embedding, voice.embedding)
            let boost = voice.tags.contains(.myVoice) ? myVoiceBoost : 0
            return VoiceMatch(
                voiceID: voice.id,
                displayName: voice.displayName,
                similarity: sim + boost,
                boostedByMyVoice: voice.tags.contains(.myVoice)
            )
        }
        .sorted { $0.similarity > $1.similarity }
    }

    static func cosineSimilarity(_ a: [Float], _ b: [Float]) -> Double {
        precondition(a.count == b.count, "cosine similarity requires equal-length vectors")
        var dot: Double = 0
        var normA: Double = 0
        var normB: Double = 0
        for i in 0..<a.count {
            let x = Double(a[i])
            let y = Double(b[i])
            dot += x * y
            normA += x * x
            normB += y * y
        }
        let denom = (normA.squareRoot()) * (normB.squareRoot())
        guard denom > 0 else { return 0 }
        return dot / denom
    }
}
