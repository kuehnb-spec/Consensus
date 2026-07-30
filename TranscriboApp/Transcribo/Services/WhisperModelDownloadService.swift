import Foundation

/// Downloads Whisper model assets directly from Hugging Face with longer request timeouts
/// than the current upstream Hub downloader uses for foreground transfers.
actor WhisperModelDownloadService {
    private struct RepoListingResponse: Decodable {
        let siblings: [Sibling]
    }

    private struct Sibling: Decodable {
        let rfilename: String
    }

    private struct DownloadItem: Sendable {
        let remoteURL: URL
        let localURL: URL
        let expectedSize: Int64
    }

    private enum Constants {
        static let endpoint = URL(string: "https://huggingface.co")!
        static let modelRepo = "argmaxinc/whisperkit-coreml"
        static let tokenizerFiles = ["config.json", "tokenizer.json", "tokenizer_config.json"]
        static let requestTimeout: TimeInterval = 300
        static let resourceTimeout: TimeInterval = 6 * 60 * 60
        static let maxRetries = 3
        static let streamChunkSize = 256 * 1024
    }

    private let fileManager = FileManager.default
    private lazy var session: URLSession = {
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = Constants.requestTimeout
        configuration.timeoutIntervalForResource = Constants.resourceTimeout
        configuration.waitsForConnectivity = true
        configuration.allowsExpensiveNetworkAccess = true
        configuration.allowsConstrainedNetworkAccess = true
        configuration.httpMaximumConnectionsPerHost = 2
        return URLSession(configuration: configuration)
    }()

    func ensureWhisperAssets(
        variant: String,
        progressCallback: @escaping @Sendable (Double) -> Void
    ) async throws -> URL {
        let modelRepoRoot = localRepoRoot(repoID: Constants.modelRepo)
        let tokenizerRepoID = tokenizerRepoID(for: variant)

        let allModelFiles = try await fetchRepoFilenames(repoID: Constants.modelRepo)
        let modelFolderName = try resolveModelFolderName(for: variant, filenames: allModelFiles)
        let modelRelativePaths = allModelFiles
            .filter { $0.hasPrefix("\(modelFolderName)/") }
            .sorted()

        guard !modelRelativePaths.isEmpty else {
            throw ConsensusError.modelDownloadFailed("No files were found for Whisper model '\(variant)'.")
        }

        let modelFolder = modelRepoRoot.appendingPathComponent(modelFolderName, isDirectory: true)
        let tokenizerRepoRoot = localRepoRoot(repoID: tokenizerRepoID)

        let modelItems = try await buildDownloadItems(
            repoID: Constants.modelRepo,
            relativePaths: modelRelativePaths,
            destinationRoot: modelRepoRoot
        )
        let tokenizerItems = try await buildDownloadItems(
            repoID: tokenizerRepoID,
            relativePaths: Constants.tokenizerFiles,
            destinationRoot: tokenizerRepoRoot
        )

        let allItems = modelItems + tokenizerItems
        guard !allItems.isEmpty else {
            progressCallback(1.0)
            return modelFolder
        }

        let totalBytes = max(1, allItems.reduce(Int64(0)) { $0 + max($1.expectedSize, 1) })
        var completedBytes: Int64 = 0

        for item in allItems {
            if try isCompleteLocalFile(item.localURL, expectedSize: item.expectedSize) {
                completedBytes += max(item.expectedSize, 1)
                progressCallback(min(1.0, Double(completedBytes) / Double(totalBytes)))
                continue
            }

            completedBytes = try await download(
                item,
                completedBytes: completedBytes,
                totalBytes: totalBytes,
                progressCallback: progressCallback
            )
        }

        progressCallback(1.0)
        return modelFolder
    }

    // MARK: - Download Planning

    private func fetchRepoFilenames(repoID: String) async throws -> [String] {
        let url = Constants.endpoint
            .appendingPathComponent("api")
            .appendingPathComponent("models")
            .appendingPathComponent(repoID)
            .appendingPathComponent("revision")
            .appendingPathComponent("main")

        var request = URLRequest(url: url)
        request.timeoutInterval = Constants.requestTimeout

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse,
              (200..<300).contains(httpResponse.statusCode) else {
            throw ConsensusError.modelDownloadFailed("Could not list files for repository '\(repoID)'.")
        }

        let listing = try JSONDecoder().decode(RepoListingResponse.self, from: data)
        return listing.siblings.map(\.rfilename)
    }

    private func resolveModelFolderName(
        for requestedVariant: String,
        filenames: [String]
    ) throws -> String {
        let topLevelFolders = Set(filenames.compactMap { $0.split(separator: "/").first.map(String.init) })

        // 1. Exact match — the typical good case (`openai_whisper-large-v3` etc).
        if topLevelFolders.contains(requestedVariant) {
            return requestedVariant
        }

        // 2. Defensive prefix match for callers that pass the human label
        // ("large-v3") rather than the canonical HF folder name. The repo has
        // 13 folders containing the substring "large-v3" (size variants,
        // turbo, dated revisions), so substring matching alone is ambiguous.
        // Trying `openai_whisper-{variant}` picks the canonical OpenAI folder
        // when one exists, which is what the rest of the app means by the
        // human label. Caught the April 29 bug where DeepPassRunner passed
        // `WhisperModel.rawValue` ("large-v3") instead of `whisperKitVariant`.
        let prefixed = "openai_whisper-\(requestedVariant)"
        if topLevelFolders.contains(prefixed) {
            return prefixed
        }

        let matchingFolders = topLevelFolders.filter { $0.contains(requestedVariant) }
        if matchingFolders.count == 1, let folder = matchingFolders.first {
            return folder
        }

        let openAIMatches = matchingFolders.filter { $0.contains("openai") }
        if openAIMatches.count == 1, let folder = openAIMatches.first {
            return folder
        }

        throw ConsensusError.modelDownloadFailed(
            "Could not resolve a unique folder for Whisper model '\(requestedVariant)'."
        )
    }

    private func buildDownloadItems(
        repoID: String,
        relativePaths: [String],
        destinationRoot: URL
    ) async throws -> [DownloadItem] {
        var items: [DownloadItem] = []

        for relativePath in relativePaths {
            let remoteURL = remoteFileURL(repoID: repoID, relativePath: relativePath)
            let localURL = destinationRoot.appendingPathComponent(relativePath)
            let expectedSize = try await fetchRemoteFileSize(remoteURL)
            items.append(DownloadItem(
                remoteURL: remoteURL,
                localURL: localURL,
                expectedSize: expectedSize
            ))
        }

        return items
    }

    private func fetchRemoteFileSize(_ url: URL) async throws -> Int64 {
        var request = URLRequest(url: url)
        request.httpMethod = "HEAD"
        request.timeoutInterval = Constants.requestTimeout

        let (_, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse,
              (200..<400).contains(httpResponse.statusCode) else {
            throw ConsensusError.modelDownloadFailed("Could not inspect download size for \(url.lastPathComponent).")
        }

        if let contentLength = httpResponse.value(forHTTPHeaderField: "Content-Length"),
           let size = Int64(contentLength) {
            return size
        }

        return 0
    }

    // MARK: - Download Execution

    private func download(
        _ item: DownloadItem,
        completedBytes: Int64,
        totalBytes: Int64,
        progressCallback: @escaping @Sendable (Double) -> Void
    ) async throws -> Int64 {
        var lastError: Error?

        for attempt in 1...Constants.maxRetries {
            do {
                return try await streamDownload(
                    item,
                    completedBytes: completedBytes,
                    totalBytes: totalBytes,
                    progressCallback: progressCallback
                )
            } catch {
                lastError = error
                try? cleanupPartialDownload(for: item.localURL)

                if attempt < Constants.maxRetries, shouldRetry(after: error) {
                    let delaySeconds = UInt64(attempt * attempt)
                    try await Task.sleep(nanoseconds: delaySeconds * 1_000_000_000)
                    continue
                }

                throw ConsensusError.modelDownloadFailed(error.localizedDescription)
            }
        }

        throw ConsensusError.modelDownloadFailed(lastError?.localizedDescription ?? "Unknown download failure.")
    }

    private func streamDownload(
        _ item: DownloadItem,
        completedBytes: Int64,
        totalBytes: Int64,
        progressCallback: @escaping @Sendable (Double) -> Void
    ) async throws -> Int64 {
        let tempURL = item.localURL.appendingPathExtension("partial")
        try fileManager.createDirectory(
            at: item.localURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try? fileManager.removeItem(at: tempURL)
        fileManager.createFile(atPath: tempURL.path, contents: nil)

        let fileHandle = try FileHandle(forWritingTo: tempURL)
        defer { try? fileHandle.close() }

        var request = URLRequest(url: item.remoteURL)
        request.timeoutInterval = Constants.requestTimeout

        let (bytes, response) = try await session.bytes(for: request)
        guard let httpResponse = response as? HTTPURLResponse,
              (200..<300).contains(httpResponse.statusCode) else {
            throw ConsensusError.modelDownloadFailed("Download failed for \(item.localURL.lastPathComponent).")
        }

        var buffer = Data()
        var fileBytesDownloaded: Int64 = 0

        for try await byte in bytes {
            buffer.append(byte)

            if buffer.count >= Constants.streamChunkSize {
                try fileHandle.write(contentsOf: buffer)
                fileBytesDownloaded += Int64(buffer.count)
                buffer.removeAll(keepingCapacity: true)
                reportProgress(
                    completedBytes: completedBytes,
                    currentFileBytes: fileBytesDownloaded,
                    totalBytes: totalBytes,
                    progressCallback: progressCallback
                )
            }
        }

        if !buffer.isEmpty {
            try fileHandle.write(contentsOf: buffer)
            fileBytesDownloaded += Int64(buffer.count)
        }

        if item.expectedSize > 0, fileBytesDownloaded != item.expectedSize {
            throw ConsensusError.modelDownloadFailed(
                "Downloaded size mismatch for \(item.localURL.lastPathComponent)."
            )
        }

        try? fileManager.removeItem(at: item.localURL)
        try fileManager.moveItem(at: tempURL, to: item.localURL)

        let finalFileBytes = max(item.expectedSize, fileBytesDownloaded, 1)
        let updatedCompletedBytes = completedBytes + finalFileBytes
        progressCallback(min(1.0, Double(updatedCompletedBytes) / Double(totalBytes)))
        return updatedCompletedBytes
    }

    private func reportProgress(
        completedBytes: Int64,
        currentFileBytes: Int64,
        totalBytes: Int64,
        progressCallback: @escaping @Sendable (Double) -> Void
    ) {
        let totalCompleted = completedBytes + max(currentFileBytes, 1)
        progressCallback(min(1.0, Double(totalCompleted) / Double(totalBytes)))
    }

    private func shouldRetry(after error: Error) -> Bool {
        guard let urlError = error as? URLError else { return false }

        switch urlError.code {
        case .timedOut, .networkConnectionLost, .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed, .notConnectedToInternet:
            return true
        default:
            return false
        }
    }

    private func cleanupPartialDownload(for fileURL: URL) throws {
        let partialURL = fileURL.appendingPathExtension("partial")
        try? fileManager.removeItem(at: partialURL)
    }

    // MARK: - Local Paths

    private func localRepoRoot(repoID: String) -> URL {
        let documentsURL = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Documents", isDirectory: true)

        return repoID.split(separator: "/").reduce(
            documentsURL.appendingPathComponent("huggingface/models", isDirectory: true)
        ) { partialURL, component in
            partialURL.appendingPathComponent(String(component), isDirectory: true)
        }
    }

    private func remoteFileURL(repoID: String, relativePath: String) -> URL {
        repoID.split(separator: "/").reduce(
            Constants.endpoint
        ) { partialURL, component in
            partialURL.appendingPathComponent(String(component), isDirectory: false)
        }
        .appendingPathComponent("resolve", isDirectory: false)
        .appendingPathComponent("main", isDirectory: false)
        .appendingPathComponent(relativePath, isDirectory: false)
    }

    private func tokenizerRepoID(for variant: String) -> String {
        if variant.hasPrefix("openai_") {
            return variant.replacingOccurrences(of: "openai_", with: "openai/")
        }
        return "openai/\(variant.replacingOccurrences(of: "_", with: "-"))"
    }

    private func isCompleteLocalFile(_ fileURL: URL, expectedSize: Int64) throws -> Bool {
        guard fileManager.fileExists(atPath: fileURL.path) else { return false }
        let attributes = try fileManager.attributesOfItem(atPath: fileURL.path)
        let fileSize = (attributes[.size] as? NSNumber)?.int64Value ?? 0

        if expectedSize > 0 {
            return fileSize == expectedSize
        }

        return fileSize > 0
    }
}
