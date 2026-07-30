import Foundation

// Reads a Consensus `project.json` and emits a flat JSON ground-truth file
// for benchmark tooling (e.g. comparing Qwen3-ForcedAligner output against
// the human-verified word-level timings stored in the consensus pass).
//
// Ground-truth JSON schema (output):
//
//   {
//     "sourceProject": "<path>",
//     "projectName": "<name>",
//     "passKind": "deepReviewConsensus",
//     "passModel": "Consensus",
//     "audioPath": "<path>",             // from project's media metadata if available
//     "durationSec": 1139.0,
//     "speakerNames": { "SPEAKER_0": "Clayton Everett", ... },
//     "segments": [
//       {
//         "start": 0.24, "end": 11.52,
//         "speakerID": "SPEAKER_1",
//         "speakerName": "Mark Horoupian",
//         "text": "Um, so I guess...",
//         "words": [
//           { "word": "Um", "start": 0.24, "end": 1.84, "probability": 0.98 },
//           ...
//         ]
//       },
//       ...
//     ]
//   }
//
// Usage:
//   swift run GroundTruthExporter <project.json> [--pass-kind <kind>] [--out <file.json>]
//
// If --pass-kind is omitted, the last pass in the passes array is used.
// Typical kinds in the Consensus model: standard, deepReviewConsensus,
// deepReviewPrimary, deepReviewComparison.

@main
struct GroundTruthExporter {
    // MARK: - Input project.json schema (partial — only fields we read)

    struct InputProject: Codable {
        let name: String?
        let audioPath: String?
        let audioFileName: String?
        let audioDuration: Double?
        let speakerMapping: SpeakerMapping?
        let passes: [InputPass]?
    }

    struct SpeakerMapping: Codable {
        let names: [String: String]?
    }

    struct InputPass: Codable {
        let kind: String?
        let modelName: String?
        let createdAt: Double?
        let result: InputPassResult?
    }

    struct InputPassResult: Codable {
        let audioPath: String?
        let duration: Double?
        let segments: [InputSegment]?
    }

    struct InputSegment: Codable {
        let id: String?
        let start: Double
        let end: Double
        let speakerID: String?
        let text: String
        let words: [InputWord]?
    }

    struct InputWord: Codable {
        let word: String
        let start: Double
        let end: Double
        let probability: Double?
    }

    // MARK: - Output schema

    struct GroundTruth: Codable {
        let sourceProject: String
        let projectName: String?
        let passKind: String
        let passModel: String?
        let audioPath: String?
        let durationSec: Double?
        let speakerNames: [String: String]?
        let segments: [GTSegment]
    }

    struct GTSegment: Codable {
        let start: Double
        let end: Double
        let speakerID: String?
        let speakerName: String?
        let text: String
        let words: [GTWord]
    }

    struct GTWord: Codable {
        let word: String
        let start: Double
        let end: Double
        let probability: Double?
    }

    // MARK: - Main

    static func main() {
        let args = CommandLine.arguments
        guard args.count >= 2 else {
            FileHandle.standardError.write(Data("""
            usage: swift run GroundTruthExporter <project.json> [--pass-kind <kind>] [--out <file.json>]

              --pass-kind  One of: standard, deepReviewConsensus, deepReviewPrimary,
                           deepReviewComparison. Defaults to the last pass.
              --out        Output JSON path. Defaults to <project>.groundtruth.json
                           next to the input file.

            """.utf8))
            exit(2)
        }

        let projectPath = args[1]
        var passKindFilter: String?
        var outPath: String?
        var i = 2
        while i < args.count {
            switch args[i] {
            case "--pass-kind":
                if i + 1 < args.count { passKindFilter = args[i + 1]; i += 2 } else { i += 1 }
            case "--out":
                if i + 1 < args.count { outPath = args[i + 1]; i += 2 } else { i += 1 }
            default:
                i += 1
            }
        }

        // Load project.
        let url = URL(fileURLWithPath: projectPath)
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            FileHandle.standardError.write(Data("error: could not read \(projectPath): \(error)\n".utf8))
            exit(1)
        }
        let project: InputProject
        do {
            project = try JSONDecoder().decode(InputProject.self, from: data)
        } catch {
            FileHandle.standardError.write(Data("error: could not decode project.json: \(error)\n".utf8))
            exit(1)
        }

        // Pick the target pass.
        let passes = project.passes ?? []
        guard !passes.isEmpty else {
            FileHandle.standardError.write(Data("error: project has no passes\n".utf8))
            exit(1)
        }
        let selected: InputPass
        if let kind = passKindFilter {
            guard let match = passes.last(where: { $0.kind == kind }) else {
                let available = passes.compactMap({ $0.kind }).joined(separator: ", ")
                FileHandle.standardError.write(Data("error: no pass with kind '\(kind)' in project. Available: \(available)\n".utf8))
                exit(1)
            }
            selected = match
        } else {
            selected = passes.last!
        }

        let segmentsIn = selected.result?.segments ?? []
        guard !segmentsIn.isEmpty else {
            FileHandle.standardError.write(Data("error: selected pass has no segments\n".utf8))
            exit(1)
        }

        // Speaker name lookup.
        let nameByID = project.speakerMapping?.names ?? [:]

        // Build segments.
        let segmentsOut: [GTSegment] = segmentsIn.map { s in
            GTSegment(
                start: s.start,
                end: s.end,
                speakerID: s.speakerID,
                speakerName: s.speakerID.flatMap { nameByID[$0] },
                text: s.text,
                words: (s.words ?? []).map {
                    GTWord(word: $0.word, start: $0.start, end: $0.end, probability: $0.probability)
                }
            )
        }

        let audioPath = selected.result?.audioPath ?? project.audioPath
        let duration = selected.result?.duration ?? project.audioDuration

        let out = GroundTruth(
            sourceProject: projectPath,
            projectName: project.name,
            passKind: selected.kind ?? "unknown",
            passModel: selected.modelName,
            audioPath: audioPath,
            durationSec: duration,
            speakerNames: nameByID.isEmpty ? nil : nameByID,
            segments: segmentsOut
        )

        // Write.
        let defaultOut: String = {
            let stem = (projectPath as NSString).deletingPathExtension
            return stem + ".groundtruth.json"
        }()
        let finalOut = outPath ?? defaultOut

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        do {
            let encoded = try encoder.encode(out)
            try encoded.write(to: URL(fileURLWithPath: finalOut))
        } catch {
            FileHandle.standardError.write(Data("error: could not write JSON: \(error)\n".utf8))
            exit(1)
        }

        // Console summary.
        let totalWords = segmentsOut.reduce(0) { $0 + $1.words.count }
        let speakers = Set(segmentsOut.compactMap(\.speakerID)).sorted()
        print("Project:     \(project.name ?? "(unnamed)")")
        print("Pass:        \(out.passKind) · \(out.passModel ?? "?")")
        if let d = duration { print(String(format: "Duration:    %.0fs (%.1fm)", d, d / 60.0)) }
        print("Segments:    \(segmentsOut.count)")
        print("Total words: \(totalWords)")
        print("Speakers:    \(speakers.joined(separator: ", "))")
        if let names = out.speakerNames {
            for id in speakers {
                if let name = names[id] {
                    print("  \(id) → \(name)")
                }
            }
        }
        print("Audio:       \(audioPath ?? "(unset)")")
        print("")
        print("First 3 segments:")
        for s in segmentsOut.prefix(3) {
            let snippet = s.text.count > 70 ? String(s.text.prefix(67)) + "…" : s.text
            let spk = s.speakerName ?? s.speakerID ?? "?"
            print(String(format: "  [%6.2f-%6.2fs] %@: %@", s.start, s.end, spk, snippet))
        }
        print("")
        print("JSON → \(finalOut)")
    }
}
