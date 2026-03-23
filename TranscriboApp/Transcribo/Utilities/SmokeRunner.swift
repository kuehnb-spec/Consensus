import Foundation
import Darwin

enum SmokeRunner {
    enum LaunchMode {
        case none
        case configuration(Configuration)
        case error(String)
    }

    struct Configuration {
        let audioURL: URL
        let engine: TranscriptionEngineDescriptor
        let whisperModel: WhisperModel
        let language: String
        let minSpeakers: Int?
        let maxSpeakers: Int?
        let outputDirectoryURL: URL?
    }

    static let launchMode: LaunchMode = parse(arguments: ProcessInfo.processInfo.arguments)

    @MainActor
    static func runFromLaunchMode() async {
        switch launchMode {
        case .none:
            return
        case .error(let message):
            reportError(message)
            exit(2)
        case .configuration(let configuration):
            let code = await run(configuration: configuration)
            exit(code)
        }
    }

    @MainActor
    static func runAndReport(configuration: Configuration) async -> Int32 {
        await run(configuration: configuration)
    }

    @MainActor
    private static func run(configuration: Configuration) async -> Int32 {
        do {
            let workspaceURL = try makeWorkspaceDirectory(baseURL: configuration.outputDirectoryURL)
            let appSupportURL = workspaceURL.appendingPathComponent("AppSupport", isDirectory: true)
            let exportURL = workspaceURL.appendingPathComponent("Exports", isDirectory: true)
            let projectStore = ProjectStore(baseDirectoryURL: appSupportURL)
            let pipeline = TranscriptionPipeline()

            try FileManager.default.createDirectory(at: exportURL, withIntermediateDirectories: true)

            printLine("Running smoke transcription")
            printLine("Audio: \(configuration.audioURL.path(percentEncoded: false))")
            printLine("Engine: \(configuration.engine.engineName)")
            printLine("Model: \(configuration.engine.modelName)")
            printLine("Language: \(configuration.language)")

            if let minSpeakers = configuration.minSpeakers, let maxSpeakers = configuration.maxSpeakers {
                printLine("Speaker range: \(minSpeakers)-\(maxSpeakers)")
            } else {
                printLine("Speaker range: auto")
            }

            let result = await pipeline.run(
                audioURL: configuration.audioURL,
                engine: configuration.engine,
                minSpeakers: configuration.minSpeakers,
                maxSpeakers: configuration.maxSpeakers,
                language: configuration.language
            )

            guard let result else {
                if case .failed(let error) = pipeline.state {
                    reportError("Transcription failed: \(error.localizedDescription)")
                } else if case .cancelled = pipeline.state {
                    reportError("Transcription was cancelled.")
                } else {
                    reportError("Transcription finished without producing a result.")
                }
                return 1
            }

            let qualitySummary = QualityAnalysisService.analyze(result: result)
            let pass = TranscriptionPass(
                kind: .standard,
                engineName: configuration.engine.engineName,
                modelName: configuration.engine.modelName,
                diarizationEngineName: "FluidAudio",
                language: configuration.language,
                minSpeakers: configuration.minSpeakers,
                maxSpeakers: configuration.maxSpeakers,
                warnings: pipeline.lastWarnings,
                result: result,
                qualitySummary: qualitySummary
            )

            var project = TranscriptionProject(
                id: UUID(),
                name: configuration.audioURL.deletingPathExtension().lastPathComponent,
                createdAt: Date(),
                updatedAt: Date(),
                lastOpenedAt: Date(),
                audioFileName: result.audioFileName,
                audioDuration: result.duration,
                sourceAudioPath: configuration.audioURL.path(percentEncoded: false),
                sourceAudioBookmark: nil,
                transcriptionSettings: ProjectTranscriptionSettings(
                    model: configuration.whisperModel,
                    minSpeakers: configuration.minSpeakers ?? 0,
                    maxSpeakers: configuration.maxSpeakers ?? 0,
                    language: configuration.language
                ),
                exportPreferences: ProjectExportPreferences(
                    selectedFormats: [.txt, .json],
                    showElapsedTime: true,
                    showClockTime: false,
                    recordingStartTime: nil,
                    legalPDFHeader: "TRANSCRIPT"
                ),
                speakerMapping: SpeakerMapping(),
                passes: [],
                activePassID: nil,
                exportHistory: []
            )

            project.appendPass(pass)
            try await projectStore.saveProject(project)

            let exportedFiles = try ExportService.exportAll(
                result: result,
                speakerMapping: project.speakerMapping,
                formats: [.txt, .json],
                to: exportURL
            )

            project.exportHistory = exportedFiles.map { format, url in
                ExportRecord(format: format, destinationPath: url.path(percentEncoded: false))
            }
            project.updatedAt = Date()
            try await projectStore.saveProject(project)

            let summaries = try await projectStore.loadProjectSummaries()
            let reloadedProject = try await projectStore.loadProject(id: project.id)

            printSummary(
                result: result,
                qualitySummary: qualitySummary,
                warnings: pipeline.lastWarnings,
                workspaceURL: workspaceURL,
                project: reloadedProject,
                projectCount: summaries.count,
                exportedFiles: exportedFiles
            )

            return 0
        } catch {
            reportError("Smoke run failed: \(error.localizedDescription)")
            return 1
        }
    }

    private static func parse(arguments: [String]) -> LaunchMode {
        guard arguments.count > 1 else { return .none }

        var index = 1
        var smokePath: String?
        var model: WhisperModel = .tiny
        var engine: DeepReviewEngineChoice = .whisper
        var language = "en"
        var minSpeakers: Int?
        var maxSpeakers: Int?
        var outputDirectoryURL: URL?
        var didRequestSmoke = false

        while index < arguments.count {
            let argument = arguments[index]

            switch argument {
            case "--smoke":
                didRequestSmoke = true
                index += 1
                guard index < arguments.count else {
                    return .error(usageText("Missing audio path after --smoke."))
                }
                smokePath = arguments[index]
            case "--model":
                index += 1
                guard index < arguments.count else {
                    return .error(usageText("Missing model name after --model."))
                }
                guard let parsedModel = WhisperModel(rawValue: arguments[index]) else {
                    return .error(usageText("Unsupported model '\(arguments[index])'."))
                }
                model = parsedModel
            case "--engine":
                index += 1
                guard index < arguments.count else {
                    return .error(usageText("Missing engine name after --engine."))
                }
                switch arguments[index] {
                case "whisper":
                    engine = .whisper
                case "parakeet-v3":
                    engine = .parakeetV3
                case "parakeet-v2":
                    engine = .parakeetV2
                default:
                    return .error(usageText("Unsupported engine '\(arguments[index])'."))
                }
            case "--language":
                index += 1
                guard index < arguments.count else {
                    return .error(usageText("Missing language code after --language."))
                }
                language = arguments[index]
            case "--min-speakers":
                index += 1
                guard index < arguments.count, let value = Int(arguments[index]) else {
                    return .error(usageText("Missing integer after --min-speakers."))
                }
                minSpeakers = value
            case "--max-speakers":
                index += 1
                guard index < arguments.count, let value = Int(arguments[index]) else {
                    return .error(usageText("Missing integer after --max-speakers."))
                }
                maxSpeakers = value
            case "--output-dir":
                index += 1
                guard index < arguments.count else {
                    return .error(usageText("Missing directory path after --output-dir."))
                }
                outputDirectoryURL = URL(fileURLWithPath: arguments[index], isDirectory: true)
            default:
                break
            }

            index += 1
        }

        guard didRequestSmoke else { return .none }
        guard let smokePath else {
            return .error(usageText("Smoke mode requires an audio path."))
        }

        let audioURL = URL(fileURLWithPath: smokePath)
        guard FileManager.default.fileExists(atPath: audioURL.path) else {
            return .error(usageText("Audio file does not exist at \(smokePath)."))
        }

        if let minSpeakers, let maxSpeakers, minSpeakers > maxSpeakers {
            return .error(usageText("Minimum speakers cannot exceed maximum speakers."))
        }

        let resolvedEngine: TranscriptionEngineDescriptor
        switch engine {
        case .whisper:
            resolvedEngine = .whisper(model)
        case .parakeetV3:
            resolvedEngine = .fluidAsr(.parakeetV3)
        case .parakeetV2:
            resolvedEngine = .fluidAsr(.parakeetV2)
        }

        return .configuration(
            Configuration(
                audioURL: audioURL,
                engine: resolvedEngine,
                whisperModel: model,
                language: language,
                minSpeakers: minSpeakers,
                maxSpeakers: maxSpeakers,
                outputDirectoryURL: outputDirectoryURL
            )
        )
    }

    private static func makeWorkspaceDirectory(baseURL: URL?) throws -> URL {
        let directory = baseURL ?? FileManager.default.temporaryDirectory
            .appendingPathComponent("ConsensusSmoke-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private static func usageText(_ message: String) -> String {
        """
        \(message)
        Usage: swift run Consensus -- --smoke /path/to/audio.m4a [--engine whisper|parakeet-v3|parakeet-v2] [--model tiny|base|small|medium|large-v3] [--language en] [--min-speakers N] [--max-speakers N] [--output-dir /path/to/output]
        """
    }

    private static func printSummary(
        result: TranscriptionResult,
        qualitySummary: TranscriptQualitySummary,
        warnings: [String],
        workspaceURL: URL,
        project: TranscriptionProject,
        projectCount: Int,
        exportedFiles: [ExportFormat: URL]
    ) {
        printLine("")
        printLine("Smoke run complete")
        printLine("Workspace: \(workspaceURL.path(percentEncoded: false))")
        printLine("Saved projects in workspace: \(projectCount)")
        printLine("Project id: \(project.id.uuidString)")
        printLine("Duration: \(TimeFormatting.durationDisplay(result.duration))")
        printLine("Segments: \(result.segments.count)")
        printLine("Detected speakers: \(result.speakerCount)")
        printLine("Average word confidence: \(percentage(qualitySummary.averageWordConfidence))")
        printLine("Average diarization quality: \(percentage(qualitySummary.averageDiarizationQuality))")
        printLine("Low-confidence words: \(qualitySummary.lowConfidenceWordCount)")
        printLine("Flagged segments: \(qualitySummary.riskySegments.count)")

        if warnings.isEmpty {
            printLine("Warnings: none")
        } else {
            printLine("Warnings:")
            for warning in warnings {
                printLine("  - \(warning)")
            }
        }

        printLine("Exports:")
        for format in exportedFiles.keys.sorted(by: { $0.rawValue < $1.rawValue }) {
            if let url = exportedFiles[format] {
                printLine("  - \(format.rawValue): \(url.path(percentEncoded: false))")
            }
        }

        let previewSegments = result.segments.prefix(3)
        if !previewSegments.isEmpty {
            printLine("Preview:")
            for segment in previewSegments {
                let snippet = segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
                printLine("  [\(TimeFormatting.timestamp(segment.start))] \(segment.speakerID): \(snippet)")
            }
        }
    }

    private static func percentage(_ value: Float?) -> String {
        guard let value else { return "n/a" }
        return "\(Int((Double(value) * 100).rounded()))%"
    }

    private static func printLine(_ text: String) {
        print(text)
        fflush(stdout)
    }

    private static func reportError(_ text: String) {
        fputs(text + "\n", stderr)
        fflush(stderr)
    }
}
