import CryptoKit
import Foundation

// Argument parsing and input validation for the headless CLI.
// Spec: 10-consensus-spec.md §CLI contract, §Input handling.

extension ConsensusCLI {

    struct UsageError: Error {
        let message: String
        let code: ExitCode

        init(_ message: String, code: ExitCode = .unknownFailure) {
            self.message = message
            self.code = code
        }
    }

    struct TranscribeOptions {
        var inputURL: URL
        var outputDirectory: URL?
        var speakers: Int?
        var language: String = "en"
        var engine: String = "local"
        var hints: String?
        var force = false
        var jsonOnly = false
        var quiet = false
    }

    enum Command {
        case transcribe(TranscribeOptions)
        case version
        case help

        static func parse(_ arguments: [String]) throws -> Command {
            guard let first = arguments.first else { return .help }

            switch first {
            case "--version", "-v": return .version
            case "--help", "-h": return .help
            case "transcribe": break
            default:
                throw UsageError("unknown command '\(first)'")
            }

            var rest = Array(arguments.dropFirst())
            var input: String?
            var options: TranscribeOptions?

            func requireValue(_ flag: String, _ queue: inout [String]) throws -> String {
                guard let value = queue.first, !value.hasPrefix("--") else {
                    throw UsageError("\(flag) requires a value")
                }
                queue.removeFirst()
                return value
            }

            var outputDirectory: URL?
            var speakers: Int?
            var language = "en"
            var engine = "local"
            var hints: String?
            var force = false
            var jsonOnly = false
            var quiet = false

            while !rest.isEmpty {
                let argument = rest.removeFirst()
                switch argument {
                case "--output-dir":
                    outputDirectory = URL(fileURLWithPath: try requireValue("--output-dir", &rest))
                        .standardizedFileURL
                case "--speakers":
                    let raw = try requireValue("--speakers", &rest)
                    guard let value = Int(raw), value > 0 else {
                        throw UsageError("--speakers expects a positive integer, got '\(raw)'")
                    }
                    speakers = value
                case "--language":
                    language = try requireValue("--language", &rest)
                case "--engine":
                    engine = try requireValue("--engine", &rest)
                    // Only the local pipeline exists today. Fail clearly rather
                    // than silently transcribing with something the caller did
                    // not ask for — provenance matters downstream.
                    guard engine == "local" else {
                        throw UsageError("engine '\(engine)' is not available in this build; only 'local' is supported")
                    }
                case "--stt-hints":
                    hints = try requireValue("--stt-hints", &rest)
                case "--force": force = true
                case "--json-only": jsonOnly = true
                case "--quiet": quiet = true
                case "--help", "-h": return .help
                default:
                    if argument.hasPrefix("-") {
                        throw UsageError("unknown option '\(argument)'")
                    }
                    guard input == nil else {
                        throw UsageError("transcribe accepts exactly one input file")
                    }
                    input = argument
                }
            }

            guard let inputPath = input else {
                throw UsageError("transcribe requires an input audio file", code: .inputUnreadable)
            }

            options = TranscribeOptions(
                inputURL: URL(fileURLWithPath: inputPath).standardizedFileURL,
                outputDirectory: outputDirectory,
                speakers: speakers,
                language: language,
                engine: engine,
                hints: hints,
                force: force,
                jsonOnly: jsonOnly,
                quiet: quiet
            )
            return .transcribe(options!)
        }
    }

    /// Validates the input file and gathers the facts the provenance block
    /// needs. Rejects unreadable, empty, unsupported, or still-syncing files
    /// before any model is loaded.
    struct AudioProbe {
        let url: URL
        let sha256: String
        let duration: TimeInterval
        let createdAt: Date?
        let byteCount: Int

        static let supportedExtensions: Set<String> = [
            "m4a", "mp3", "wav", "aac", "caf", "flac", "aiff", "aif", "mp4", "mov",
        ]

        static func inspect(_ url: URL) async throws -> AudioProbe {
            let fileManager = FileManager.default
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory), !isDirectory.boolValue else {
                throw UsageError("no such file: \(url.path)", code: .inputUnreadable)
            }
            guard fileManager.isReadableFile(atPath: url.path) else {
                throw UsageError("file is not readable: \(url.path)", code: .inputUnreadable)
            }

            let ext = url.pathExtension.lowercased()
            guard supportedExtensions.contains(ext) else {
                throw UsageError(
                    "unsupported file type '.\(ext)' (supported: \(supportedExtensions.sorted().joined(separator: ", ")))",
                    code: .inputUnreadable
                )
            }

            let attributes = try? fileManager.attributesOfItem(atPath: url.path)
            let size = (attributes?[.size] as? NSNumber)?.intValue ?? 0
            guard size > 0 else {
                throw UsageError("file is empty: \(url.path)", code: .inputUnreadable)
            }

            // Defense in depth against iCloud partial syncs: if the size moves
            // while we look at it, the file is still arriving (spec §Input).
            try? await Task.sleep(nanoseconds: 350_000_000)
            let recheck = (try? fileManager.attributesOfItem(atPath: url.path))?[.size] as? NSNumber
            if let recheck, recheck.intValue != size {
                throw UsageError("file is still being written (size changed during check): \(url.path)", code: .inputUnreadable)
            }

            let duration: TimeInterval
            do {
                duration = try await AudioFileValidator.validate(url: url).duration
            } catch {
                throw UsageError("could not decode audio (file may be corrupt): \(error.localizedDescription)", code: .inputUnreadable)
            }

            return AudioProbe(
                url: url,
                sha256: try sha256Digest(of: url),
                duration: duration,
                createdAt: attributes?[.creationDate] as? Date,
                byteCount: size
            )
        }

        /// Streams the file so a 2-hour recording doesn't get read into memory.
        private static func sha256Digest(of url: URL) throws -> String {
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            var hasher = SHA256()
            while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty {
                hasher.update(data: chunk)
            }
            return hasher.finalize().map { String(format: "%02x", $0) }.joined()
        }
    }
}
