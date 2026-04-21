import Foundation
import Observation

/// On-disk library of `ProjectDocument`s. Owns the directory at
/// `~/Library/Application Support/Consensus/Projects/` and every child
/// project directory within it. The UI-facing Project Library window reads
/// its rows from here; the Deep Read / Quick Take / Studio flows read and
/// write a single project through the `open(...)` / `save(...)` pair.
///
/// Separate from the legacy `ProjectStore`, which continues to own the
/// current (`TranscriptionProject`) on-disk format. The two co-exist during
/// the rewrite: legacy projects are read-only through the migration path
/// in Phase 1b; new projects only ever touch this library.
@Observable
@MainActor
final class ProjectLibrary {
    /// Cached list of project summaries, newest first. Repopulated after
    /// `reload()`. The full `ProjectDocument` is loaded on demand.
    private(set) var index: [ProjectIndexEntry] = []

    /// Root directory. Defaults to the canonical location but can be
    /// overridden in tests or debug builds.
    let root: URL

    /// One-line summary used by the Project Library window. Loading this for
    /// each project is much cheaper than the full document.
    struct ProjectIndexEntry: Identifiable, Hashable, Sendable {
        let id: UUID
        let title: String
        let createdAt: Date
        let updatedAt: Date
        let durationSeconds: Double
        let speakerNames: [String]
    }

    init(root: URL? = nil) throws {
        self.root = try root ?? ProjectPaths.libraryRoot()
        try FileManager.default.createDirectory(
            at: self.root,
            withIntermediateDirectories: true
        )
    }

    // MARK: - Index

    /// Re-read the root directory and refresh `index`. Safe to call
    /// repeatedly — cheap enough for a pull-to-refresh gesture.
    func reload() async throws {
        let paths = try projectDirectories()
        var entries: [ProjectIndexEntry] = []
        for url in paths {
            guard let id = UUID(uuidString: url.lastPathComponent) else { continue }
            let projectJSON = ProjectPaths(projectID: id, within: root).projectJSON
            guard FileManager.default.fileExists(atPath: projectJSON.path) else { continue }
            do {
                let document: ProjectDocument = try Self.read(at: projectJSON)
                entries.append(ProjectIndexEntry(
                    id: document.id,
                    title: document.title,
                    createdAt: document.createdAt,
                    updatedAt: document.updatedAt,
                    durationSeconds: document.audio.durationSeconds,
                    speakerNames: document.speakers.map(\.displayName)
                ))
            } catch {
                // Skip unreadable entries rather than failing the whole index
                continue
            }
        }
        index = entries.sorted { $0.updatedAt > $1.updatedAt }
    }

    private func projectDirectories() throws -> [URL] {
        let contents = try FileManager.default.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )
        return contents.filter { url in
            (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
        }
    }

    // MARK: - Load / save

    /// Create the project's directory tree and write an empty `project.json`
    /// + `summary.json`. Returns the ready-to-edit document.
    func create(_ document: ProjectDocument) throws -> ProjectDocument {
        let paths = ProjectPaths(projectID: document.id, within: root)
        try FileManager.default.createDirectory(at: paths.root, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: paths.passesDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: paths.exportsDirectory, withIntermediateDirectories: true)
        try Self.write(document, to: paths.projectJSON)
        try Self.write(SummaryDocument(), to: paths.summaryJSON)
        return document
    }

    /// Read a project document by ID.
    func load(_ id: UUID) throws -> ProjectDocument {
        let paths = ProjectPaths(projectID: id, within: root)
        return try Self.read(at: paths.projectJSON)
    }

    /// Write a project document back to disk and refresh its `updatedAt`.
    func save(_ document: ProjectDocument) throws -> ProjectDocument {
        var updated = document
        updated.updatedAt = Date()
        let paths = ProjectPaths(projectID: updated.id, within: root)
        try Self.write(updated, to: paths.projectJSON)
        return updated
    }

    /// Delete the entire project directory. Irreversible.
    func delete(_ id: UUID) throws {
        let paths = ProjectPaths(projectID: id, within: root)
        try FileManager.default.removeItem(at: paths.root)
    }

    // MARK: - Summary

    func loadSummary(_ projectID: UUID) throws -> SummaryDocument {
        let paths = ProjectPaths(projectID: projectID, within: root)
        guard FileManager.default.fileExists(atPath: paths.summaryJSON.path) else {
            return SummaryDocument()
        }
        return try Self.read(at: paths.summaryJSON)
    }

    func saveSummary(_ summary: SummaryDocument, for projectID: UUID) throws {
        let paths = ProjectPaths(projectID: projectID, within: root)
        try Self.write(summary, to: paths.summaryJSON)
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

    private static func write<T: Encodable>(_ value: T, to url: URL) throws {
        let data = try encoder.encode(value)
        try data.write(to: url, options: [.atomic])
    }

    private static func read<T: Decodable>(at url: URL) throws -> T {
        let data = try Data(contentsOf: url)
        return try decoder.decode(T.self, from: data)
    }
}
