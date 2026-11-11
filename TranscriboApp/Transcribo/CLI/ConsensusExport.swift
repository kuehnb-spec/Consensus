import Foundation

// `consensus export` — re-render an existing .consensus.json into any of the
// app's export formats, including the court-style legal transcript PDF.
//
// Ported 2026-11-11 from origin/wip/macbook (34fa537, July base) without the
// rest of that branch. The transcribe path writes only JSON + Markdown so it
// stays fast and unattended; this covers the follow-up need of naming speakers
// and producing a deliverable without re-running the engine. Reads schema 2.0
// and 2.1 alike (it needs only segments[].start/end/speaker/text).
extension ConsensusCLI {

    /// A speaker's identity as the caller asserts it. Consensus makes no
    /// identity claim of its own; this is how sibling tools name justices and
    /// counsel.
    struct RosterEntry: Sendable {
        let name: String
        let role: String?

        /// "Name (role)" for listings such as the legal PDF's appearances.
        var listing: String {
            guard let role, !role.isEmpty else { return name }
            return "\(name) (\(role))"
        }
    }

    struct ExportOptions {
        var inputURL: URL
        var outputDirectory: URL?
        var formats: Set<ExportFormat> = [.md]
        var roster: [String: RosterEntry] = [:]
        var legalHeader: String = "TRANSCRIPT"
        var quiet = false
    }

    /// Accepts a bare letter ("A") as shorthand for the emitted label.
    static func canonicalSpeakerLabel(_ raw: String) -> String {
        let id = raw.trimmingCharacters(in: .whitespaces)
        if id.count == 1, let letter = id.first, letter.isLetter {
            return "SPEAKER_\(letter.uppercased())"
        }
        return id
    }

    /// Parses `--speaker A=Name` / `--speaker SPEAKER_A=Name` into a mapping.
    static func parseSpeakerAssignment(_ raw: String) throws -> (String, String) {
        guard let equals = raw.firstIndex(of: "=") else {
            throw UsageError("--speaker expects ID=Name, got '\(raw)'")
        }
        let id = canonicalSpeakerLabel(String(raw[raw.startIndex..<equals]))
        let name = String(raw[raw.index(after: equals)...]).trimmingCharacters(in: .whitespaces)
        guard !id.isEmpty, !name.isEmpty else {
            throw UsageError("--speaker expects ID=Name, got '\(raw)'")
        }
        return (id, name)
    }

    /// `--roster FILE`: a JSON object mapping speaker label to either a name
    /// string or `{"name": "...", "role": "..."}`.
    ///
    ///     {"SPEAKER_A": {"name": "Chief Justice Roberts", "role": "justice"},
    ///      "B": "Paul Clement"}
    static func loadRoster(_ url: URL) throws -> [String: RosterEntry] {
        guard let data = try? Data(contentsOf: url) else {
            throw UsageError("could not read roster \(url.path)", code: .inputUnreadable)
        }
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw UsageError("roster must be a JSON object of label to name: \(url.lastPathComponent)", code: .inputUnreadable)
        }
        var roster: [String: RosterEntry] = [:]
        for (rawLabel, value) in object {
            let label = canonicalSpeakerLabel(rawLabel)
            if let name = value as? String, !name.isEmpty {
                roster[label] = RosterEntry(name: name, role: nil)
            } else if let entry = value as? [String: Any], let name = entry["name"] as? String, !name.isEmpty {
                roster[label] = RosterEntry(name: name, role: entry["role"] as? String)
            } else {
                throw UsageError("roster entry '\(rawLabel)' needs a name", code: .inputUnreadable)
            }
        }
        return roster
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
            guard let start = (raw["start"] as? NSNumber)?.doubleValue,
                  let end = (raw["end"] as? NSNumber)?.doubleValue,
                  let text = raw["text"] as? String else { continue }
            segments.append(TranscriptionSegment(
                speakerID: raw["speaker"] as? String ?? "SPEAKER_?",
                start: start,
                end: end,
                text: text
            ))
        }
        guard !segments.isEmpty else {
            fail("transcript contains no segments")
            return .inputUnreadable
        }

        // --- Speaker names -------------------------------------------------
        let present = Set(segments.map(\.speakerID))
        let unknown = options.roster.keys.filter { !present.contains($0) }
        if !unknown.isEmpty {
            // Loud, because a typo here silently produces an unnamed transcript.
            fail("no such speaker in transcript: \(unknown.sorted().joined(separator: ", ")) (present: \(present.sorted().joined(separator: ", ")))")
            return .unknownFailure
        }
        var mapping = SpeakerMapping()
        for (id, entry) in options.roster { mapping.rename(id, to: entry.name) }

        // audioPath drives the exported base filename, so point it at the
        // original recording rather than the JSON.
        let audioPath = options.inputURL.deletingLastPathComponent()
            .appendingPathComponent(audioFileName).path
        let result = TranscriptionResult(
            audioPath: audioPath,
            duration: duration > 0 ? duration : (segments.last?.end ?? 0),
            segments: segments
        )

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
        // Appearances in first-speaking order, not alphabetical.
        let order = segments.map(\.speakerID).reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }
        legalOptions.speakerNames = order.compactMap { options.roster[$0]?.listing }

        do {
            let written = try ExportService.exportAll(
                result: result,
                speakerMapping: mapping,
                formats: options.formats,
                legalPDFOptions: legalOptions,
                to: directory
            )
            if !options.quiet {
                for url in written.values.sorted(by: { $0.path < $1.path }) {
                    FileHandle.standardError.write(Data("wrote \(url.path)\n".utf8))
                }
            }
        } catch {
            fail("export failed: \(error.localizedDescription)")
            return .unknownFailure
        }
        return .success
    }
}
