import Foundation
import Observation

/// On-disk store for the voice library. Owns the directory at
/// `~/Library/Application Support/Consensus/VoiceLibrary/`, the `library.json`
/// index inside it, and the `samples/` subdirectory holding per-voice WAV
/// clips.
///
/// Phase 0 wires the store; embedding extraction (SpeakerKit) and match-
/// during-transcription are Phase 4 work.
@Observable
@MainActor
final class VoiceLibraryStore {
    /// In-memory snapshot of the library. Reassigned after each persisted
    /// mutation so SwiftUI views observing this store re-render.
    private(set) var library: VoiceLibrary = VoiceLibrary()

    let paths: VoiceLibraryPaths

    init(root: URL? = nil) throws {
        let rootURL = try root ?? VoiceLibraryPaths.libraryRoot()
        self.paths = VoiceLibraryPaths(root: rootURL)
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: paths.samplesDirectory, withIntermediateDirectories: true)
    }

    // MARK: - Load / save

    /// Read the library from disk into memory. Creates an empty library on
    /// first launch.
    func reload() throws {
        guard FileManager.default.fileExists(atPath: paths.indexJSON.path) else {
            library = VoiceLibrary()
            return
        }
        let data = try Data(contentsOf: paths.indexJSON)
        library = try Self.decoder.decode(VoiceLibrary.self, from: data)
    }

    /// Write the in-memory library back to disk, stamping `updatedAt`.
    func save() throws {
        library.updatedAt = Date()
        let data = try Self.encoder.encode(library)
        try data.write(to: paths.indexJSON, options: [.atomic])
    }

    // MARK: - Mutations

    /// Add a new voice to the library and persist. Returns the saved entry.
    @discardableResult
    func add(_ voice: VoiceIdentity) throws -> VoiceIdentity {
        library.voices.append(voice)
        try save()
        return voice
    }

    /// Replace an existing voice in place. No-op if no entry matches `voice.id`.
    func update(_ voice: VoiceIdentity) throws {
        guard let idx = library.voices.firstIndex(where: { $0.id == voice.id }) else { return }
        library.voices[idx] = voice
        try save()
    }

    /// Delete a voice and its associated sample file.
    func remove(id: UUID) throws {
        guard let idx = library.voices.firstIndex(where: { $0.id == id }) else { return }
        let voice = library.voices[idx]
        let sampleURL = paths.sample(for: voice)
        try? FileManager.default.removeItem(at: sampleURL)
        library.voices.remove(at: idx)
        try save()
    }

    /// Record that a voice was observed in a specific project. Appends to
    /// `projectAppearances` and updates `lastSeenAt`.
    func recordAppearance(voiceID: UUID, in projectID: UUID, as speakerID: String) throws {
        guard let idx = library.voices.firstIndex(where: { $0.id == voiceID }) else { return }
        let appearance = ProjectAppearance(
            projectID: projectID,
            speakerID: speakerID,
            seenAt: Date()
        )
        library.voices[idx].projectAppearances.insert(appearance, at: 0)
        library.voices[idx].lastSeenAt = appearance.seenAt
        try save()
    }

    // MARK: - Codec

    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        e.dateEncodingStrategy = .iso8601
        return e
    }()

    private static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()
}
