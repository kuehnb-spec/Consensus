import Foundation

/// The headless `consensus` command. Implemented here in ConsensusCore rather
/// than in the executable target so it can reach the pipeline's internal API
/// without widening it to `public`; the executable is a one-line launcher.
///
/// Contract, exit codes, and output schema are specified in
/// `10-consensus-spec.md` at the repository root. This runs with no AppKit
/// lifecycle and no window server, so it is safe from launchd/cron.
public enum ConsensusCLI {

    // MARK: - Exit codes (spec §CLI contract)

    enum ExitCode: Int32 {
        case success = 0
        case unknownFailure = 1
        case inputUnreadable = 2
        case transcriptionFailed = 3
        case outputExists = 4
    }

    public static let appVersion = "2.0.0"
    static let schemaVersion = "2.0"

    // MARK: - Entry point

    /// Parses arguments, runs the requested command, and returns a process
    /// exit code. Never traps: every failure path maps to a spec'd code.
    public static func main(arguments: [String] = Array(CommandLine.arguments.dropFirst())) async -> Int32 {
        do {
            let command = try Command.parse(arguments)
            switch command {
            case .version:
                printVersion()
                return ExitCode.success.rawValue
            case .help:
                FileHandle.standardOutput.write(Data(usage.utf8))
                return ExitCode.success.rawValue
            case .doctor:
                return runDoctor().rawValue
            case .export(let options):
                return await runExport(options).rawValue
            case .transcribe(let options):
                return await runTranscribe(options).rawValue
            }
        } catch let error as UsageError {
            fail(error.message)
            FileHandle.standardError.write(Data(usage.utf8))
            return error.code.rawValue
        } catch {
            fail(error.localizedDescription)
            return ExitCode.unknownFailure.rawValue
        }
    }

    // MARK: - doctor

    /// Reports whether this machine can actually run a transcription, and where
    /// each dependency was found. Exists because the engine needs a Python
    /// sidecar and a 5.3 GB model that no binary can carry with it — without
    /// this, a fresh install fails at inference time with nothing actionable.
    private static func runDoctor() -> ExitCode {
        let config = ConsensusConfig.resolve()
        var lines = ["consensus \(appVersion) — environment check", ""]

        if let configFile = config.configFileURL {
            lines.append("config file: \(configFile.path)")
        } else {
            lines.append("config file: none (looked for ~/.consensus/config.toml)")
        }
        lines.append("")

        for requirement in config.requirements {
            let mark = requirement.found ? "OK  " : "MISS"
            lines.append("[\(mark)] \(requirement.name)")
            if requirement.found, let path = requirement.path {
                lines.append("       \(path.path)")
                if let source = requirement.source {
                    lines.append("       via \(source)")
                }
            } else {
                lines.append("       \(requirement.remedy)")
            }
            lines.append("")
        }

        lines.append(config.isComplete
            ? "Ready — `consensus transcribe <file>` should work on this machine."
            : "Not ready. Resolve the items marked MISS above.")
        lines.append("")
        lines.append("Overrides: CONSENSUS_PYTHON, CONSENSUS_SIDECAR, CONSENSUS_MODEL, CONSENSUS_CONFIG")

        FileHandle.standardOutput.write(Data((lines.joined(separator: "\n") + "\n").utf8))
        return config.isComplete ? .success : .transcriptionFailed
    }

    // MARK: - transcribe

    private static func runTranscribe(_ options: TranscribeOptions) async -> ExitCode {
        let startedAt = Date()

        // --- Environment preflight (exit 3) --------------------------------
        // Check before hashing the input or loading anything: on a machine
        // without the sidecar or model this is the failure the caller will hit,
        // and it should be legible in a launchd log.
        let config = ConsensusConfig.resolve()
        guard config.isComplete else {
            fail("Local engine unavailable — missing: \(config.missingSummary)")
            return .transcriptionFailed
        }

        // --- Input validation (exit 2) -------------------------------------
        let input = options.inputURL
        let probe: AudioProbe
        do {
            probe = try await AudioProbe.inspect(input)
        } catch let error as UsageError {
            fail(error.message)
            return error.code
        } catch {
            fail("Could not read input: \(error.localizedDescription)")
            return .inputUnreadable
        }

        let outputDirectory = options.outputDirectory ?? input.deletingLastPathComponent()
        let stem = input.deletingPathExtension().lastPathComponent
        let jsonURL = outputDirectory.appendingPathComponent("\(stem).consensus.json")
        let markdownURL = outputDirectory.appendingPathComponent("\(stem).consensus.md")

        // --- Idempotency (exit 4) ------------------------------------------
        // Match on name *and* source hash so a re-recorded file under the same
        // name is correctly treated as new work rather than skipped.
        if !options.force, FileManager.default.fileExists(atPath: jsonURL.path) {
            if let existing = try? Data(contentsOf: jsonURL),
               let decoded = try? JSONSerialization.jsonObject(with: existing) as? [String: Any],
               let source = decoded["source"] as? [String: Any],
               let recordedHash = source["sha256"] as? String,
               recordedHash == probe.sha256 {
                log("Output already exists for this input; use --force to reprocess.", options: options)
                return .outputExists
            }
        }

        do {
            try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        } catch {
            fail("Could not create output directory: \(error.localizedDescription)")
            return .unknownFailure
        }

        // --- Transcription (exit 3) ----------------------------------------
        log("Transcribing \(input.lastPathComponent) (\(String(format: "%.1f", probe.duration))s)", options: options)

        let runner = await MainActor.run { StandardPassRunner() }
        var runnerOptions = StandardPassRunner.Options()
        runnerOptions.language = options.language
        runnerOptions.requestedSpeakerCount = options.speakers
        runnerOptions.audioDurationSeconds = probe.duration
        runnerOptions.vibeVoiceContext = options.hints

        let pass: TranscriptPass
        do {
            pass = try await runner.run(audioURL: input, options: runnerOptions) { progress in
                guard !options.quiet else { return }
                // One machine-parsable line per event; never transcript text.
                let percent = Int((progress.fraction * 100).rounded())
                FileHandle.standardError.write(Data("progress \(percent) \(progress.label)\n".utf8))
            }
        } catch {
            fail("Transcription failed: \(error.localizedDescription)")
            return .transcriptionFailed
        }

        guard !pass.segments.isEmpty else {
            // A zero-segment parse is the June 2026 empty-pass failure mode.
            // Fail loud rather than writing a valid-looking empty transcript.
            fail("Transcription produced no segments — refusing to write an empty transcript.")
            return .transcriptionFailed
        }

        // --- Output (atomic) -----------------------------------------------
        let document = TranscriptDocument(
            probe: probe,
            pass: pass,
            options: options,
            processingSeconds: Date().timeIntervalSince(startedAt)
        )

        do {
            try writeAtomically(document.jsonData(), to: jsonURL)
            if !options.jsonOnly {
                try writeAtomically(Data(document.markdown().utf8), to: markdownURL)
            }
        } catch {
            fail("Could not write output: \(error.localizedDescription)")
            return .unknownFailure
        }

        log("Wrote \(jsonURL.lastPathComponent)\(options.jsonOnly ? "" : " and \(markdownURL.lastPathComponent)")", options: options)
        return .success
    }

    // MARK: - Atomic write

    /// Writes to a sibling temp file and renames into place, so a watcher
    /// never observes a partially written artifact and a killed run leaves
    /// nothing behind (spec §Robustness).
    private static func writeAtomically(_ data: Data, to url: URL) throws {
        let tempURL = url.deletingLastPathComponent()
            .appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString).partial")
        do {
            try data.write(to: tempURL, options: .atomic)
            if FileManager.default.fileExists(atPath: url.path) {
                _ = try FileManager.default.replaceItemAt(url, withItemAt: tempURL)
            } else {
                try FileManager.default.moveItem(at: tempURL, to: url)
            }
        } catch {
            try? FileManager.default.removeItem(at: tempURL)
            throw error
        }
    }

    // MARK: - Output helpers

    private static func printVersion() {
        let engine = "VibeVoice ASR (MLX 4-bit)"
        let lines = [
            "consensus \(appVersion)",
            "schema \(schemaVersion)",
            "engine \(engine)",
            "diarization FluidAudio",
        ]
        FileHandle.standardOutput.write(Data((lines.joined(separator: "\n") + "\n").utf8))
    }

    private static func log(_ message: String, options: TranscribeOptions) {
        guard !options.quiet else { return }
        FileHandle.standardError.write(Data("\(message)\n".utf8))
    }

    static func fail(_ message: String) {
        FileHandle.standardError.write(Data("error: \(message)\n".utf8))
    }

    static let usage = """
    consensus \(appVersion) — headless transcription and diarization

    USAGE:
      consensus transcribe <input-audio> [options]
      consensus doctor
      consensus --version

    OPTIONS:
      --output-dir DIR     Where outputs go (default: alongside the input)
      --speakers N         Expected speaker count hint (default: auto-detect)
      --language CODE      Language code (default: en)
      --engine NAME        Engine adapter to use (default: local)
      --stt-hints "A, B"   Proper-noun hints to bias recognition
      --force              Reprocess even if output already exists
      --json-only          Skip the Markdown rendering
      --quiet              Suppress progress; errors still go to stderr
      --version            Print app, model, and engine versions
      --help               Show this message

    EXIT CODES:
      0 success   2 input unreadable   3 transcription failed
      4 output exists (use --force)    1 other failure

    ENVIRONMENT:
      CONSENSUS_CONFIG     Config file path (default: ~/.consensus/config.toml)
      CONSENSUS_PYTHON     Python interpreter with mlx-audio installed
      CONSENSUS_SIDECAR    Path to the VibeVoice sidecar run.py
      CONSENSUS_MODEL      Path to the 4-bit MLX VibeVoice model directory

    Run `consensus doctor` to see what this machine has and what it is missing.

    """
}
