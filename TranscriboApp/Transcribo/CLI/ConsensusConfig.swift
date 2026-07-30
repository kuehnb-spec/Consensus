import Foundation

/// Resolves where the local engine's moving parts live on *this* machine.
///
/// Before this existed the sidecar paths were hardcoded to the author's
/// development checkout, so a build could only ever run on one Mac. Spec
/// §"Configuration and secrets" requires config-file defaults with CLI/env
/// override, which is what this provides.
///
/// Resolution order, highest priority first:
///   1. Environment variables (`CONSENSUS_PYTHON`, `CONSENSUS_SIDECAR`, `CONSENSUS_MODEL`)
///   2. Config file — `$CONSENSUS_CONFIG`, else `~/.consensus/config.toml`
///   3. Conventional install layout under `~/.consensus/`
///   4. Hugging Face cache (model only) — so a plain `hf download` just works
///   5. Repository discovery — walk up from the binary and cwd looking for a
///      source checkout, which covers running straight out of `.build/`
///
/// No secrets are read here; only filesystem paths (spec §Configuration).
public struct ConsensusConfig: Sendable {

    public struct Paths: Sendable {
        public var python: URL?
        public var sidecar: URL?
        public var model: URL?

        /// Where each value came from, for `doctor` output.
        public var pythonSource: String?
        public var sidecarSource: String?
        public var modelSource: String?
    }

    /// Path to the config file that was actually loaded, if any.
    public private(set) var configFileURL: URL?
    public private(set) var paths = Paths()

    // MARK: - Resolution

    public static func resolve() -> ConsensusConfig {
        var config = ConsensusConfig()
        let fileValues = config.loadConfigFile()

        config.paths.python = firstExisting([
            ("CONSENSUS_PYTHON env", environmentPath("CONSENSUS_PYTHON")),
            ("config file", fileValues["python"].map(expand)),
            ("~/.consensus/venv", home.appendingPathComponent(".consensus/venv/bin/python")),
            ("repository checkout", repositoryRoot()?.appendingPathComponent(devVenvSuffix)),
        ], into: &config.paths.pythonSource)

        config.paths.sidecar = firstExisting([
            ("CONSENSUS_SIDECAR env", environmentPath("CONSENSUS_SIDECAR")),
            ("config file", fileValues["sidecar"].map(expand)),
            ("~/.consensus/sidecar", home.appendingPathComponent(".consensus/sidecar/run.py")),
            ("alongside binary", binaryDirectory?.appendingPathComponent("VibeVoiceSidecar/run.py")),
            ("app bundle Resources", bundleResource("VibeVoiceSidecar/run.py")),
            ("repository checkout", repositoryRoot()?.appendingPathComponent(sidecarSuffix)),
        ], into: &config.paths.sidecarSource)

        config.paths.model = firstExisting([
            ("CONSENSUS_MODEL env", environmentPath("CONSENSUS_MODEL")),
            ("config file", fileValues["model"].map(expand)),
            ("~/.consensus/models", home.appendingPathComponent(".consensus/models/vibevoice-asr-4bit")),
            ("Hugging Face cache", huggingFaceSnapshot()),
            ("repository checkout", repositoryRoot()?.appendingPathComponent(devModelSuffix)),
        ], into: &config.paths.modelSource)

        return config
    }

    // MARK: - Candidate helpers

    /// Returns the first candidate that exists on disk, recording its label.
    private static func firstExisting(_ candidates: [(String, URL?)], into source: inout String?) -> URL? {
        for (label, url) in candidates {
            guard let url else { continue }
            if FileManager.default.fileExists(atPath: url.path) {
                source = label
                return url
            }
        }
        return nil
    }

    private static var home: URL {
        URL(fileURLWithPath: NSHomeDirectory())
    }

    private static func environmentPath(_ key: String) -> URL? {
        guard let raw = ProcessInfo.processInfo.environment[key], !raw.isEmpty else { return nil }
        return expand(raw)
    }

    /// Expands a leading `~` and resolves to an absolute URL.
    private static func expand(_ raw: String) -> URL {
        var path = raw.trimmingCharacters(in: .whitespaces)
        if path == "~" {
            path = NSHomeDirectory()
        } else if path.hasPrefix("~/") {
            path = NSHomeDirectory() + String(path.dropFirst(1))
        }
        return URL(fileURLWithPath: (path as NSString).expandingTildeInPath).standardizedFileURL
    }

    // Layout of a source checkout, relative to the repository root.
    private static let sidecarSuffix = "TranscriboApp/Scripts/VibeVoiceSidecar/run.py"
    private static let devVenvSuffix = "Brainstorming/vibevoice-test/venv/bin/python"
    private static let devModelSuffix = "Brainstorming/vibevoice-test/model-4bit"

    private static var binaryDirectory: URL? {
        guard let path = Bundle.main.executableURL?.deletingLastPathComponent() else { return nil }
        return path
    }

    private static func bundleResource(_ relative: String) -> URL? {
        Bundle.main.resourceURL?.appendingPathComponent(relative)
    }

    /// Walks up from the executable (and the working directory) looking for a
    /// source checkout, identified by the sidecar script it must contain.
    private static func repositoryRoot() -> URL? {
        var starts: [URL] = []
        if let binaryDirectory { starts.append(binaryDirectory) }
        starts.append(URL(fileURLWithPath: FileManager.default.currentDirectoryPath))

        for start in starts {
            var candidate = start.standardizedFileURL
            // Bounded walk: deep enough for .build/<triple>/release, cheap enough
            // to run on every launch.
            for _ in 0..<8 {
                let marker = candidate.appendingPathComponent(sidecarSuffix)
                if FileManager.default.fileExists(atPath: marker.path) {
                    return candidate
                }
                let parent = candidate.deletingLastPathComponent()
                if parent.path == candidate.path { break }
                candidate = parent
            }
        }
        return nil
    }

    /// Finds the newest snapshot of the MLX VibeVoice model in the HF cache.
    private static func huggingFaceSnapshot() -> URL? {
        let cache = home.appendingPathComponent(
            ".cache/huggingface/hub/models--mlx-community--VibeVoice-ASR-4bit/snapshots"
        )
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: cache, includingPropertiesForKeys: nil
        ) else { return nil }
        // Snapshot directories are commit hashes; any of them is a valid model.
        return entries.sorted { $0.lastPathComponent < $1.lastPathComponent }.last
    }

    // MARK: - Config file

    /// Reads the `[paths]` table from the config file. Deliberately a tiny
    /// TOML subset — comments, `[section]` headers, and `key = "value"` — which
    /// covers the documented schema without taking on a parser dependency.
    private mutating func loadConfigFile() -> [String: String] {
        let candidate: URL
        if let override = ProcessInfo.processInfo.environment["CONSENSUS_CONFIG"], !override.isEmpty {
            candidate = Self.expand(override)
        } else {
            candidate = Self.home.appendingPathComponent(".consensus/config.toml")
        }
        guard let text = try? String(contentsOf: candidate, encoding: .utf8) else { return [:] }
        configFileURL = candidate

        var values: [String: String] = [:]
        var section = ""
        for rawLine in text.components(separatedBy: .newlines) {
            var line = rawLine.trimmingCharacters(in: .whitespaces)
            if let comment = line.firstIndex(of: "#") { line = String(line[line.startIndex..<comment]) }
            line = line.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }

            if line.hasPrefix("["), line.hasSuffix("]") {
                section = String(line.dropFirst().dropLast()).trimmingCharacters(in: .whitespaces)
                continue
            }
            guard let equals = line.firstIndex(of: "=") else { continue }
            let key = String(line[line.startIndex..<equals]).trimmingCharacters(in: .whitespaces)
            var value = String(line[line.index(after: equals)...]).trimmingCharacters(in: .whitespaces)
            if value.hasPrefix("\""), value.hasSuffix("\""), value.count >= 2 {
                value = String(value.dropFirst().dropLast())
            }
            guard !key.isEmpty, !value.isEmpty else { continue }
            // Accept both `[paths] python = …` and a bare top-level `python = …`.
            values[section.isEmpty || section == "paths" ? key : "\(section).\(key)"] = value
        }
        return values
    }

    // MARK: - Reporting

    public struct Requirement: Sendable {
        public let name: String
        public let path: URL?
        public let source: String?
        public let found: Bool
        public let remedy: String
    }

    /// The dependency list `consensus doctor` prints.
    public var requirements: [Requirement] {
        [
            Requirement(
                name: "Python interpreter",
                path: paths.python,
                source: paths.pythonSource,
                found: paths.python != nil,
                remedy: "Create a venv with mlx-audio installed, then set CONSENSUS_PYTHON "
                    + "or `python` under [paths] in ~/.consensus/config.toml. "
                    + "Default location: ~/.consensus/venv/bin/python"
            ),
            Requirement(
                name: "VibeVoice sidecar",
                path: paths.sidecar,
                source: paths.sidecarSource,
                found: paths.sidecar != nil,
                remedy: "Copy Scripts/VibeVoiceSidecar/run.py to ~/.consensus/sidecar/run.py "
                    + "or set CONSENSUS_SIDECAR."
            ),
            Requirement(
                name: "VibeVoice model (4-bit MLX)",
                path: paths.model,
                source: paths.modelSource,
                found: paths.model != nil,
                remedy: "Download it with `hf download mlx-community/VibeVoice-ASR-4bit` "
                    + "(about 5.3 GB) or set CONSENSUS_MODEL to an existing copy."
            ),
        ]
    }

    public var isComplete: Bool { requirements.allSatisfy(\.found) }

    /// One-line summary of what's missing, for the transcribe path's error.
    public var missingSummary: String {
        let missing = requirements.filter { !$0.found }.map(\.name)
        guard !missing.isEmpty else { return "" }
        return missing.joined(separator: ", ")
            + " — run `consensus doctor` for the exact paths checked and how to fix them."
    }
}
