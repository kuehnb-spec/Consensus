import Foundation

actor ProjectStore {
    static let shared = ProjectStore()

    private let fileManager = FileManager.default
    private let baseDirectoryURL: URL?
    private let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }()

    private let decoder = JSONDecoder()

    init(baseDirectoryURL: URL? = nil) {
        self.baseDirectoryURL = baseDirectoryURL
    }

    private var projectsDirectoryURL: URL {
        let baseURL = baseDirectoryURL ?? fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let newPath = baseURL
            .appendingPathComponent("Consensus", isDirectory: true)
            .appendingPathComponent("Projects", isDirectory: true)
        // Check both old names for backward compatibility
        let legacyPath = baseURL
            .appendingPathComponent("BDK Transcribo", isDirectory: true)
            .appendingPathComponent("Projects", isDirectory: true)

        // Prefer the new path. Fall back to legacy if it exists and the new one doesn't.
        if fileManager.fileExists(atPath: newPath.path) {
            return newPath
        }
        if fileManager.fileExists(atPath: legacyPath.path) {
            return legacyPath
        }
        // Neither exists yet — use the new path (it will be created on first save).
        return newPath
    }

    func loadProjectSummaries() throws -> [TranscriptionProjectSummary] {
        try ensureProjectsDirectoryExists()

        return try projectFileURLs()
            .compactMap { url in
                do {
                    let data = try Data(contentsOf: url)
                    let project = try decoder.decode(TranscriptionProject.self, from: data)
                    return project.summary
                } catch {
                    print("Skipping unreadable project at \(url.path): \(error.localizedDescription)")
                    return nil
                }
            }
            .sorted { $0.updatedAt > $1.updatedAt }
    }

    func loadProject(id: UUID) throws -> TranscriptionProject {
        try ensureProjectsDirectoryExists()
        let url = projectFileURL(for: id)
        let data = try Data(contentsOf: url)
        return try decoder.decode(TranscriptionProject.self, from: data)
    }

    func saveProject(_ project: TranscriptionProject) throws {
        try ensureProjectsDirectoryExists()

        let directoryURL = projectDirectoryURL(for: project.id)
        try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)

        let data = try encoder.encode(project)
        try data.write(to: projectFileURL(for: project.id), options: .atomic)
    }

    private func ensureProjectsDirectoryExists() throws {
        try fileManager.createDirectory(at: projectsDirectoryURL, withIntermediateDirectories: true)
    }

    private func projectDirectoryURL(for id: UUID) -> URL {
        projectsDirectoryURL.appendingPathComponent(id.uuidString, isDirectory: true)
    }

    private func projectFileURL(for id: UUID) -> URL {
        projectDirectoryURL(for: id).appendingPathComponent("project.json")
    }

    private func projectFileURLs() throws -> [URL] {
        let directoryURLs = try fileManager.contentsOfDirectory(
            at: projectsDirectoryURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )

        return directoryURLs.compactMap { directoryURL in
            let values = try? directoryURL.resourceValues(forKeys: [.isDirectoryKey])
            guard values?.isDirectory == true else { return nil }
            let fileURL = directoryURL.appendingPathComponent("project.json")
            return fileManager.fileExists(atPath: fileURL.path) ? fileURL : nil
        }
    }
}
