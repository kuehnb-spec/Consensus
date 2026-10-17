import Foundation

// `consensus export` — re-render an existing .consensus.json into any of the
// app's export formats, including the court-style legal transcript PDF.
//
// The transcribe path deliberately writes only JSON + Markdown so it stays fast
// and unattended. This subcommand covers the follow-up need: naming speakers and
// producing a deliverable, without re-running the engine.
extension ConsensusCLI {

    struct ExportOptions {
        var inputURL: URL
        var outputDirectory: URL?
        var formats: Set<ExportFormat> = [.md]
        var speakerNames: [String: String] = [:]
        var legalHeader: String = "TRANSCRIPT"
        var quiet = false
    }

    /// Parses `--speaker A=Name` / `--speaker SPEAKER_A=Name` into a mapping.
    static func parseSpeakerAssignment(_ raw: String) throws -> (String, String) {
        guard let equals = raw.firstIndex(of: "=") else {
            throw UsageError("--speaker expects ID=Name, got '\(raw)'")
        }
        var id = String(raw[raw.startIndex..<equals]).trimmingCharacters(in: .whitespaces)
        let name = String(raw[raw.index(after: equals)...]).trimmingCharacters(in: .whitespaces)
        guard !id.isEmpty, !name.isEmpty else {
            throw UsageError("--speaker expects ID=Name, got '\(raw)'")
        }
        // Accept the bare letter as shorthand for the emitted label.
        if id.count == 1, let letter = id.first, letter.isLetter {
            id = "SPEAKER_\(letter.uppercased())"
        }
        return (id, name)
    }

    static func runExport(_ options: ExportOptions) async -> ExitCode {
        // --- Load the transcript ------------------------------------------
        guard let data = try? Data(contentsOf: options.inputURL) else {
            fail("could not read \(options.inputURL.path)")
            return .inputUnreadable
        }
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let rawSegments = root["segments"] as? [[String: Any]] else {
            fail("not a Consensus transcript JSON: \(options.inputURL.lastPathComponent)")
            return .inputUnreadable
        }

        let source = root["source"] as? [String: Any]
        let audioFileName = source?["filename"] as? String
            ?? options.inputURL.deletingPathExtension().lastPathComponent
        let duration = source?["duration_seconds"] as? Double ?? 0

        var segments: [TranscriptionSegment] = []
        segments.reserveCapacity(rawSegments.count)
        for raw in rawSegments {
            guard let start = raw["start"] as? Double,
                  let end = raw["end"] as? Double,
                  let text = raw["text"] as? String else { continue }
            segments.append(TranscriptionSegment(
                speakerID: raw["speaker"] as? String ?? "SPEAKER_A",
                start: start,
                end: end,
                text: text
            ))
        }
        guard !segments.isEmpty else {
            fail("transcript contains no segments")
            return .inputUnreadable
        }

        // audioPath drives the exported base filename, so point it at the
        // original recording rather than the JSON.
        let audioPath = options.inputURL.deletingLastPathComponent()
            .appendingPathComponent(audioFileName).path
        let result = TranscriptionResult(
            audioPath: audioPath,
            duration: duration > 0 ? duration : (segments.last?.end ?? 0),
            segments: segments
        )

        // --- Speaker names -------------------------------------------------
        var mapping = SpeakerMapping()
        for (id, name) in options.speakerNames { mapping.rename(id, to: name) }

        let unknown = options.speakerNames.keys.filter { id in
            !segments.contains { $0.speakerID == id }
        }
        if !unknown.isEmpty {
            // Loud, because a typo here silently produces an unnamed transcript.
            let present = Set(segments.map(\.speakerID)).sorted().joined(separator: ", ")
            fail("no such speaker in transcript: \(unknown.sorted().joined(separator: ", ")) (present: \(present))")
            return .unknownFailure
        }

        // --- Export --------------------------------------------------------
        let directory = options.outputDirectory ?? options.inputURL.deletingLastPathComponent()
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            fail("could not create output directory: \(error.localizedDescription)")
            return .unknownFailure
        }

        var legalOptions = LegalPDFOptions()
        legalOptions.headerText = options.legalHeader
        legalOptions.audioFileName = audioFileName
        legalOptions.audioDuration = result.duration
        legalOptions.speakerNames = options.speakerNames.values.sorted()

        do {
            let written = try ExportService.exportAll(
                result: result,
                speakerMapping: mapping,
                formats: options.formats,
                legalPDFOptions: legalOptions,
                to: directory
            )
            for (format, url) in written.sorted(by: { $0.key.rawValue < $1.key.rawValue }) {
                if !options.quiet {
                    FileHandle.standardError.write(Data("wrote \(url.path)\n".utf8))
                }
                _ = format
            }
        } catch {
            fail("export failed: \(error.localizedDescription)")
            return .unknownFailure
        }
        return .success
    }
}
