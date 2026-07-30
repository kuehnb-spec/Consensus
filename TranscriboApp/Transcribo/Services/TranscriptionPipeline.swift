import FluidAudio
import Foundation

/// The pipeline state machine driving the UI.
enum PipelineState: Sendable {
    case idle
    case loadingAudio
    case downloadingModel(progress: Double)
    case transcribing(progress: Double, currentText: String?)
    case diarizing
    case mergingResults
    case complete(TranscriptionResult)
    case failed(ConsensusError)
    case cancelled
}

/// Orchestrates the full transcription pipeline:
/// load audio -> download model -> transcribe -> diarize -> merge -> done
@Observable
@MainActor
final class TranscriptionPipeline {
    private(set) var state: PipelineState = .idle
    private var task: Task<TranscriptionResult?, Error>?
    private(set) var lastWarnings: [String] = []

    /// The diarization engine used for the initial transcription pass.
    var diarizationEngine: DiarizationEngine = .speakerKit

    private let transcriptionService = TranscriptionService()
    private let fluidAsrService = FluidAsrTranscriptionService()
    private let vibevoiceService = VibeVoiceTranscriptionService()
    private let diarizationService = DiarizationService()

    /// Optional process log for detailed status updates.
    var processLog: ProcessLog?

    var isRunning: Bool {
        switch state {
        case .loadingAudio, .downloadingModel, .transcribing, .diarizing, .mergingResults:
            return true
        default:
            return false
        }
    }

    /// Run the full pipeline. Wraps work in a cancellable Task.
    func run(
        audioURL: URL,
        model: WhisperModel,
        minSpeakers: Int?,
        maxSpeakers: Int?,
        language: String
    ) async -> TranscriptionResult? {
        await run(
            audioURL: audioURL,
            engine: .whisper(model),
            minSpeakers: minSpeakers,
            maxSpeakers: maxSpeakers,
            language: language
        )
    }

    /// When true, the pipeline skips diarization and returns segments with "UNKNOWN" speaker IDs.
    /// Used for Deep Review's Engine B pass where we only need the text + word timings.
    var skipDiarization: Bool = false

    func run(
        audioURL: URL,
        engine: TranscriptionEngineDescriptor,
        minSpeakers: Int?,
        maxSpeakers: Int?,
        language: String
    ) async -> TranscriptionResult? {
        // Cancel any existing run
        task?.cancel()
        lastWarnings = []

        log("Pipeline started", level: .info)
        log("Engine: \(engine.engineName) / \(engine.modelName)", level: .info)
        log("Diarization: \(diarizationEngine.displayName)", level: .info)

        // Store the task so cancel() can reach it
        let pipelineTask = Task<TranscriptionResult?, Error> { @MainActor [weak self] in
            guard let self else { return nil }
            return try await self.executePipeline(
                audioURL: audioURL,
                engine: engine,
                minSpeakers: minSpeakers,
                maxSpeakers: maxSpeakers,
                language: language
            )
        }
        task = pipelineTask

        do {
            return try await pipelineTask.value
        } catch is CancellationError {
            state = .cancelled
            log("Pipeline cancelled", level: .warning)
            return nil
        } catch {
            return nil
        }
    }

    /// The actual pipeline steps — separated so the Task wrapper can catch cancellation.
    private func executePipeline(
        audioURL: URL,
        engine: TranscriptionEngineDescriptor,
        minSpeakers: Int?,
        maxSpeakers: Int?,
        language: String
    ) async throws -> TranscriptionResult? {
        state = .loadingAudio

        // Step 1: Validate audio
        log("Loading audio file...", level: .progress)
        let audioInfo: AudioFileValidator.AudioInfo
        do {
            audioInfo = try await AudioFileValidator.validate(url: audioURL)
            log("Audio loaded: \(audioInfo.fileName) (\(TimeFormatting.durationDisplay(audioInfo.duration)))", level: .success)
        } catch let error as ConsensusError {
            state = .failed(error)
            log("Audio validation failed: \(error.localizedDescription)", level: .error)
            return nil
        } catch {
            state = .failed(.invalidAudioFile(error.localizedDescription))
            log("Audio validation failed: \(error.localizedDescription)", level: .error)
            return nil
        }

        try Task.checkCancellation()

        // Step 2: Load/download model
        state = .downloadingModel(progress: 0)
        log("Downloading/loading transcription model...", level: .progress)
        do {
            switch engine {
            case .whisper(let model):
                try await transcriptionService.loadModel(
                    variant: model.whisperKitVariant,
                    progressCallback: { [weak self] progress in
                        Task { @MainActor in
                            self?.state = .downloadingModel(progress: progress)
                        }
                    }
                )
            case .fluidAsr(let variant):
                try await fluidAsrService.prepareModel(
                    variant: variant,
                    progressCallback: { [weak self] progress in
                        Task { @MainActor in
                            self?.state = .downloadingModel(progress: progress)
                        }
                    }
                )
            case .vibevoice:
                if let issue = VibeVoiceTranscriptionService.availabilityError() {
                    throw ConsensusError.modelDownloadFailed(issue)
                }
                state = .downloadingModel(progress: 1.0)
            }
            log("Model ready", level: .success)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            state = .failed(.modelDownloadFailed(error.localizedDescription))
            log("Model download failed: \(error.localizedDescription)", level: .error)
            return nil
        }

        try Task.checkCancellation()

        // Step 3: Transcribe
        state = .transcribing(progress: 0, currentText: nil)
        log("Starting transcription...", level: .progress)
        outputLabel("Transcription")
        clearOutput()
        let segments: [TranscriptionSegment]
        do {
            switch engine {
            case .whisper:
                segments = try await transcriptionService.transcribe(
                    audioPath: audioURL.path(percentEncoded: false),
                    language: language,
                    audioDuration: audioInfo.duration,
                    progressCallback: { [weak self] progress, text in
                        Task { @MainActor in
                            self?.state = .transcribing(progress: progress, currentText: text)
                            // Stream transcription text to the output pane
                            if let text {
                                self?.processLog?.setOutput(text)
                            }
                        }
                        return !Task.isCancelled
                    }
                )
            case .fluidAsr(let variant):
                segments = try await fluidAsrService.transcribe(
                    audioURL: audioURL,
                    variant: variant,
                    progressCallback: { [weak self] progress in
                        Task { @MainActor in
                            self?.state = .transcribing(progress: progress, currentText: nil)
                        }
                    }
                )
            case .vibevoice(_, let context):
                segments = try await vibevoiceService.transcribe(
                    audioURL: audioURL,
                    context: context,
                    audioDuration: audioInfo.duration,
                    progressCallback: { [weak self] progress, status, recentText, tokenCount, tokensPerSecond in
                        Task { @MainActor in
                            // Show the rolling transcript snippet in the
                            // pipeline state so the legacy progress card
                            // surfaces the same live text the rewritten UI
                            // does. Status (token count, tps) is logged
                            // separately via processLog.
                            self?.state = .transcribing(progress: progress, currentText: recentText)
                            if let recentText, !recentText.isEmpty {
                                self?.processLog?.setOutput(recentText)
                            }
                            _ = status
                            _ = tokenCount
                            _ = tokensPerSecond
                        }
                    }
                )
            }
            log("Transcription complete: \(segments.count) segments", level: .success)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            if Task.isCancelled { throw CancellationError() }
            state = .failed(.transcriptionFailed(error.localizedDescription))
            log("Transcription failed: \(error.localizedDescription)", level: .error)
            return nil
        }

        try Task.checkCancellation()

        // Step 4: Speaker diarization (skipped for text-only comparison passes
        // AND for engines that emit their own speaker labels — VibeVoice in particular).
        let finalSegments: [TranscriptionSegment]

        if skipDiarization {
            log("Skipping diarization (text-only comparison pass)", level: .info)
            finalSegments = segments
        } else if engine.providesOwnDiarization {
            log("Using engine-provided diarization (\(engine.engineName))", level: .info)
            finalSegments = segments
        } else {
            state = .diarizing
            log("Starting speaker diarization (\(diarizationEngine.displayName))...", level: .progress)

            do {
                let diarizationSegments = try await diarizationService.diarize(
                    audioURL: audioURL,
                    engine: diarizationEngine,
                    minSpeakers: minSpeakers,
                    maxSpeakers: maxSpeakers
                )

                let speakerCount = Set(diarizationSegments.map(\.speakerID)).count
                log("Diarization complete: \(speakerCount) speakers identified, \(diarizationSegments.count) segments", level: .success)

                try Task.checkCancellation()

                // Step 4b: Merge transcription segments with diarization speaker labels
                state = .mergingResults
                log("Merging transcription with speaker labels...", level: .progress)
                finalSegments = SegmentMerger.merge(
                    transcriptionSegments: segments,
                    diarizationSegments: diarizationSegments
                )
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                // If diarization fails, continue with unspeakered segments
                let warning = "Diarization failed. The transcript is still available, but speaker labels may be incomplete. \(error.localizedDescription)"
                print(warning)
                lastWarnings.append(warning)
                log("Diarization failed: \(error.localizedDescription)", level: .warning)
                log("Continuing without speaker labels", level: .info)
                finalSegments = segments
            }
        }

        try Task.checkCancellation()

        // Step 5: Build result
        state = .mergingResults
        let result = TranscriptionResult(
            audioPath: audioURL.path(percentEncoded: false),
            duration: audioInfo.duration,
            segments: finalSegments
        )

        state = .complete(result)
        log("Pipeline complete: \(finalSegments.count) segments ready", level: .success)
        return result
    }

    func cancel() {
        task?.cancel()
        task = nil
        state = .cancelled
    }

    func reset() {
        task?.cancel()
        task = nil
        lastWarnings = []
        state = .idle
    }

    // MARK: - Process Log

    private func log(_ message: String, level: ProcessLogEntry.Level, detail: String? = nil) {
        Task { @MainActor in
            processLog?.log(message, level: level, detail: detail)
        }
    }

    private func outputLabel(_ label: String) {
        Task { @MainActor in
            processLog?.setOutputLabel(label)
        }
    }

    private func clearOutput() {
        Task { @MainActor in
            processLog?.clearOutput()
        }
    }
}
