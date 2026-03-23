import SwiftUI
import UniformTypeIdentifiers

@Observable
@MainActor
final class TranscriptionViewModel {
    // Phase 1: Setup
    var audioFileURL: URL?
    var audioDuration: TimeInterval = 0
    var audioFileName: String = ""
    var selectedModel: WhisperModel
    var deepReviewEngine: DeepReviewEngineChoice
    var deepReviewModel: WhisperModel
    var deepReviewTranscription: Bool = true
    var deepReviewDiarization: Bool = true
    var minSpeakers: Int
    var maxSpeakers: Int
    var language: String
    var showFilePicker: Bool = false

    // Project library
    var projects: [TranscriptionProjectSummary] = []
    var currentProject: TranscriptionProject?

    // Pipeline
    let pipeline = TranscriptionPipeline()
    private let projectStore: ProjectStore
    private let settings: AppSettings
    private let audioContextPlayer = AudioContextPlayer()

    // Current transcript
    var result: TranscriptionResult?
    var speakerMapping = SpeakerMapping()
    var speakerSamples: [String: String] = [:]
    var reconciliationDraft: ReconciliationDraft?
    var reconciliationSelectedRowID: UUID?
    var reconciliationPlayingRowID: UUID?
    var reconciliationStatusMessage: String?

    // Export
    var selectedFormats: Set<ExportFormat> = [.legalPDF]
    var isExporting = false
    var exportError: String?
    var lastExportDirectory: URL?

    // Legal PDF options
    var showElapsedTime: Bool = true
    var showClockTime: Bool = false
    var recordingStartTime: Date?
    var legalPDFHeader: String = ""
    var showWelcomeTour: Bool = false

    // Quick Transcribe
    var quickModel: WhisperModel = .base

    // Diarization engine selection
    var diarizationEngine: DiarizationEngine = .speakerKit

    // LLM Cleanup / Polish
    var selectedCleanupModel: CleanupModel = CleanupModel.recommended()
    var cleanupTask: TranscriptCleanupService.CleanupTask = .cleanupAndSummarize
    var isCleanupRunning: Bool = false
    var cleanupProgress: String = ""
    var cleanupResult: String?
    var cleanupError: String?
    private let cleanupService = TranscriptCleanupService()

    // Process Log
    let processLog = ProcessLog()

    // Navigation
    enum Phase: Hashable {
        case setup
        case help
        case review
        case quality
        case reconcile
        case export
        case summary
    }
    var currentPhase: Phase = .setup

    // Error
    var errorMessage: String?
    var showError: Bool = false

    init(
        projectStore: ProjectStore = .shared,
        settings: AppSettings = AppSettings()
    ) {
        self.projectStore = projectStore
        self.settings = settings
        self.selectedModel = settings.preferredWhisperModel
        self.deepReviewEngine = .defaultChoice
        self.deepReviewModel = settings.preferredWhisperModel.recommendedDeepReviewModel
        self.minSpeakers = settings.defaultMinSpeakers
        self.maxSpeakers = settings.defaultMaxSpeakers
        self.language = settings.defaultLanguage
        self.showWelcomeTour = !settings.hasSeenWelcomeTour

        // Wire process log into pipeline
        pipeline.processLog = processLog

        Task {
            await refreshProjectLibrary()
        }
    }

    // MARK: - Computed

    var hasAudio: Bool { audioFileURL != nil }
    var hasResult: Bool { result != nil }
    var hasSavedProject: Bool { currentProject != nil }
    var canRunDeepReview: Bool { currentProject?.hasTranscript == true && currentAudioURL != nil }
    var canOpenReconciliation: Bool { reconciliationReferencePass != nil && reconciliationCandidatePass != nil }
    var canPlayCurrentAudio: Bool { currentAudioURL != nil }

    // Workflow step indicators
    var hasSpeakerRenames: Bool { !speakerMapping.isEmpty }
    var hasMultiplePasses: Bool { (currentProject?.passes.count ?? 0) > 1 }
    var hasConsensusPass: Bool { currentProject?.passes.contains(where: { $0.kind == .deepReviewConsensus }) ?? false }
    var activePass: TranscriptionPass? { currentProject?.activePass }
    var passHistory: [TranscriptionPass] {
        (currentProject?.passes ?? []).sorted { $0.createdAt > $1.createdAt }
    }
    var qualitySummary: TranscriptQualitySummary? { activePass?.qualitySummary }
    var qualityFlags: [QualityFlag] { qualitySummary?.riskySegments ?? [] }
    var currentWarnings: [String] { activePass?.warnings ?? [] }
    var currentAudioURL: URL? { audioFileURL ?? currentProject.flatMap(resolveAudioURL(for:)) }
    var comparisonReferencePass: TranscriptionPass? {
        guard let activePass, let project = currentProject else { return nil }

        if activePass.kind == .standard {
            return project.passes.last(where: { $0.id != activePass.id && $0.kind != .standard })
                ?? project.passes.last(where: { $0.id != activePass.id })
        }

        return project.passes.last(where: { $0.id != activePass.id && $0.kind == .standard })
            ?? project.passes.last(where: { $0.id != activePass.id })
    }
    var passComparisonSummary: PassComparisonSummary? {
        guard let activePass, let reference = comparisonReferencePass else { return nil }
        return PassComparisonService.compare(reference: reference, candidate: activePass)
    }
    var reconciliationReferencePass: TranscriptionPass? {
        currentProject?.passes.last(where: { $0.kind == .standard })
    }
    var reconciliationCandidatePass: TranscriptionPass? {
        currentProject?.passes.last(where: { $0.kind == .deepReviewComparison || $0.kind == .deepReviewPrimary })
    }
    var latestConsensusPass: TranscriptionPass? {
        currentProject?.passes.last(where: { $0.kind == .deepReviewConsensus })
    }
    var reconciliationRows: [ReconciliationRow] {
        reconciliationDraft?.rows ?? []
    }
    var reconciliationSelectedRow: ReconciliationRow? {
        guard let reconciliationSelectedRowID else { return nil }
        return reconciliationDraft?.rows.first(where: { $0.id == reconciliationSelectedRowID })
    }

    /// Whether any background processing is active (pipeline, cleanup, deep diarization).
    var isAnyProcessRunning: Bool {
        pipeline.isRunning || isCleanupRunning || isSummaryRunning
    }

    /// Global progress (0-1) combining pipeline and cleanup progress.
    var globalProgress: Double {
        if pipeline.isRunning {
            return pipelineProgress
        } else if isCleanupRunning || isSummaryRunning {
            return 0.5
        }
        return 0
    }

    /// Global status text for the floating status bar.
    var globalStatusText: String {
        if pipeline.isRunning {
            return statusMessage
        } else if isCleanupRunning {
            return cleanupProgress.isEmpty ? "Processing..." : cleanupProgress
        } else if isSummaryRunning {
            return summaryProgress.isEmpty ? "Generating summary..." : summaryProgress
        }
        return ""
    }

    var pipelineProgress: Double {
        switch pipeline.state {
        case .downloadingModel(let p): return p * 0.2
        case .transcribing(let p, _): return 0.2 + p * 0.6
        case .diarizing: return 0.85
        case .mergingResults: return 0.95
        case .complete: return 1.0
        default: return 0
        }
    }

    var statusMessage: String {
        switch pipeline.state {
        case .idle: return "Ready"
        case .loadingAudio: return "Loading audio..."
        case .downloadingModel(let p):
            return p >= 1.0 ? "Compiling model (this may take a minute)..." : "Downloading model... \(Int(p * 100))%"
        case .transcribing(let p, _): return "Transcribing... \(Int(p * 100))%"
        case .diarizing: return "Identifying speakers..."
        case .mergingResults: return "Preparing results..."
        case .complete: return "Complete"
        case .failed(let err): return "Error: \(err.localizedDescription)"
        case .cancelled: return "Cancelled"
        }
    }

    // MARK: - Actions

    func refreshProjectLibrary() async {
        do {
            projects = try await projectStore.loadProjectSummaries()
        } catch {
            presentError(error)
        }
    }

    func importAudio(url: URL) async {
        let accessing = url.startAccessingSecurityScopedResource()
        defer {
            if accessing {
                url.stopAccessingSecurityScopedResource()
            }
        }

        do {
            let info = try await AudioFileValidator.validate(url: url)
            let creationDate = Self.creationDate(for: url)

            configureImportedAudio(info: info, url: url, creationDate: creationDate)
            deepReviewEngine = .defaultChoice
            deepReviewModel = selectedModel.recommendedDeepReviewModel

            currentProject = TranscriptionProject(
                id: UUID(),
                name: info.fileName,
                createdAt: Date(),
                updatedAt: Date(),
                lastOpenedAt: Date(),
                audioFileName: info.fileName,
                audioDuration: info.duration,
                sourceAudioPath: url.path(percentEncoded: false),
                sourceAudioBookmark: bookmarkData(for: url),
                transcriptionSettings: currentTranscriptionSettings(),
                exportPreferences: currentExportPreferences(),
                speakerMapping: SpeakerMapping(),
                passes: [],
                activePassID: nil,
                exportHistory: []
            )

            await persistCurrentProject()
        } catch {
            presentError(error)
        }
    }

    func openProject(id: UUID) async {
        do {
            var project = try await projectStore.loadProject(id: id)
            project.lastOpenedAt = Date()
            currentProject = project
            loadProjectState(project)
            await persistCurrentProject()
        } catch {
            presentError(error)
        }
    }

    func closeProject() {
        pipeline.reset()
        currentProject = nil
        result = nil
        speakerMapping = SpeakerMapping()
        speakerSamples = [:]
        reconciliationDraft = nil
        reconciliationSelectedRowID = nil
        reconciliationPlayingRowID = nil
        reconciliationStatusMessage = nil
        audioFileURL = nil
        audioDuration = 0
        audioFileName = ""
        selectedModel = settings.preferredWhisperModel
        deepReviewEngine = .defaultChoice
        deepReviewModel = settings.preferredWhisperModel.recommendedDeepReviewModel
        minSpeakers = settings.defaultMinSpeakers
        maxSpeakers = settings.defaultMaxSpeakers
        language = settings.defaultLanguage
        selectedFormats = [.legalPDF]
        showElapsedTime = true
        showClockTime = false
        recordingStartTime = nil
        legalPDFHeader = ""
        currentPhase = .setup
    }

    func openHelpCenter() {
        currentPhase = .help
    }

    func presentWelcomeTour() {
        showWelcomeTour = true
    }

    func completeWelcomeTour() {
        settings.hasSeenWelcomeTour = true
        showWelcomeTour = false
    }

    func openAudioPickerFromWelcomeTour() {
        completeWelcomeTour()
        currentPhase = .setup
        showFilePicker = true
    }

    func loadDemoProject() async {
        completeWelcomeTour()
        pipeline.reset()

        let demoProject = DemoProjectFactory.makeProject()
        currentProject = demoProject
        loadProjectState(demoProject)

        do {
            try await projectStore.saveProject(demoProject)
            projects = try await projectStore.loadProjectSummaries()
        } catch {
            presentError(error)
        }
    }

    func startTranscription() async {
        result = nil
        speakerMapping = SpeakerMapping()
        speakerSamples = [:]
        pipeline.diarizationEngine = diarizationEngine
        processLog.isVisible = true
        processLog.clear()
        await runPipelinePass(kind: .standard, engine: .whisper(selectedModel), resetSpeakerMapping: true)
    }

    /// Toggle process log visibility.
    func toggleProcessLog() {
        processLog.isVisible.toggle()
    }

    /// Quick Transcribe: one-click fast transcription with auto-export to legal PDF.
    func quickTranscribe() async {
        guard hasAudio else { return }

        // Use the quick model (defaults to .base for speed)
        result = nil
        speakerMapping = SpeakerMapping()
        speakerSamples = [:]

        await runPipelinePass(kind: .standard, engine: .whisper(quickModel), resetSpeakerMapping: true)

        // Auto-export to legal PDF if transcription succeeded
        guard let result else { return }

        let panel = NSSavePanel()
        panel.title = "Save Quick Transcript"
        panel.nameFieldLabel = "Save As:"
        panel.nameFieldStringValue = "\(result.audioFileName)_quick_transcript.pdf"
        panel.allowedContentTypes = [.pdf]
        panel.isExtensionHidden = false
        panel.canCreateDirectories = true
        panel.message = "Save your quick legal transcript PDF."

        let response = panel.runModal()
        guard response == .OK, let url = panel.url else { return }

        do {
            let pdfOptions = LegalPDFOptions(
                showElapsedTime: showElapsedTime,
                showClockTime: showClockTime,
                recordingStartTime: recordingStartTime,
                headerText: legalPDFHeader
            )
            try ExportService.export(
                format: .legalPDF,
                result: result,
                speakerMapping: speakerMapping,
                legalPDFOptions: pdfOptions,
                to: url
            )
            recordExport(format: .legalPDF, destinationURL: url)
            await persistCurrentProject()
            NSWorkspace.shared.selectFile(url.path, inFileViewerRootedAtPath: url.deletingLastPathComponent().path)
        } catch {
            exportError = error.localizedDescription
        }
    }

    func startDeepReview() async {
        guard currentProject?.hasTranscript == true else {
            presentError(TranscriboError.transcriptionFailed("Run a standard transcription before starting Deep Review."))
            return
        }

        currentPhase = .quality

        // Deep Transcription: run a second engine pass
        if deepReviewTranscription {
            let engine: TranscriptionEngineDescriptor
            switch deepReviewEngine {
            case .whisper:
                engine = .whisper(deepReviewModel)
            case .parakeetV3:
                engine = .fluidAsr(.parakeetV3)
            case .parakeetV2:
                engine = .fluidAsr(.parakeetV2)
            }

            await runPipelinePass(kind: .deepReviewComparison, engine: engine, resetSpeakerMapping: false)
        }

        // Deep Diarization: multi-threshold + LLM resolution
        if deepReviewDiarization {
            await runDeepDiarization()
        }
    }

    /// Run multi-engine diarization with LLM-assisted speaker resolution.
    /// Uses SpeakerKit (pyannote v4) as primary + FluidAudio passes for cross-engine comparison.
    private func runDeepDiarization() async {
        guard let url = currentAudioURL, let currentResult = result else { return }

        let accessing = url.startAccessingSecurityScopedResource()
        defer {
            if accessing {
                url.stopAccessingSecurityScopedResource()
            }
        }

        isCleanupRunning = true
        cleanupProgress = "Starting deep diarization..."
        cleanupError = nil
        processLog.isVisible = true

        do {
            let diarizationService = DiarizationService()

            processLog.log("Starting multi-engine deep diarization", level: .progress)
            processLog.log("Primary: SpeakerKit (pyannote v4 on CoreML)", level: .info)
            processLog.log("Secondary: FluidAudio (multiple thresholds)", level: .info)

            // Run multi-engine diarization (SpeakerKit + FluidAudio passes)
            let multiResult = try await diarizationService.diarizeDeep(
                audioURL: url,
                minSpeakers: minSpeakers > 0 ? minSpeakers : nil,
                maxSpeakers: maxSpeakers > 0 ? maxSpeakers : nil,
                progressCallback: { [weak self] status in
                    Task { @MainActor in
                        self?.cleanupProgress = status
                        self?.processLog.log(status, level: .progress)
                    }
                }
            )

            let passSummary = multiResult.passes.map { "\($0.engineName) (\($0.presetName))" }.joined(separator: ", ")
            processLog.log("Completed \(multiResult.passes.count) passes: \(passSummary)", level: .success)
            processLog.log("\(multiResult.disagreementCount) speaker disagreements detected", level: multiResult.disagreementCount > 0 ? .warning : .success)

            cleanupProgress = "Resolving speaker disagreements with AI (\(multiResult.disagreementCount) disagreements)..."

            // Use LLM to resolve disagreements if there are any
            let resolvedSegments: [DiarizationSegment]
            if multiResult.disagreementCount > 0 {
                processLog.log("Loading AI model for disagreement resolution...", level: .aiThinking)

                // Load cleanup model if not already loaded
                try await cleanupService.loadModel(selectedCleanupModel) { [weak self] progress in
                    Task { @MainActor in
                        if progress < 1.0 {
                            self?.cleanupProgress = "Loading AI model... \(Int(progress * 100))%"
                        }
                    }
                }

                cleanupProgress = "AI resolving \(multiResult.disagreementCount) speaker disagreements..."
                processLog.setOutputLabel("AI Speaker Resolution")
                processLog.clearOutput()
                processLog.log("AI analyzing \(multiResult.disagreementCount) disagreements using conversational context...", level: .aiThinking)

                resolvedSegments = try await cleanupService.resolveDiarizationDisagreements(
                    transcriptionSegments: currentResult.segments,
                    multiResult: multiResult,
                    speakerMapping: speakerMapping
                )

                processLog.log("AI resolved all \(multiResult.disagreementCount) speaker disagreements", level: .success)
            } else {
                resolvedSegments = multiResult.resolved
                processLog.log("All passes agree on speaker assignments", level: .success)
            }

            // Merge resolved diarization with existing transcription segments
            cleanupProgress = "Applying resolved speaker labels..."
            processLog.log("Merging resolved speaker labels into transcript...", level: .progress)
            let updatedSegments = SegmentMerger.merge(
                transcriptionSegments: currentResult.segments,
                diarizationSegments: resolvedSegments
            )

            // Update the current result with improved speaker assignments
            let updatedResult = TranscriptionResult(
                audioPath: currentResult.audioPath,
                duration: currentResult.duration,
                segments: updatedSegments
            )

            result = updatedResult
            speakerSamples = extractSpeakerSamples(from: updatedResult)

            // Save as a deep review pass
            if var project = currentProject {
                let pass = TranscriptionPass(
                    kind: .deepReviewPrimary,
                    engineName: "Multi-Engine Diarization",
                    modelName: "\(selectedCleanupModel.displayName) + SpeakerKit + FluidAudio",
                    diarizationEngineName: "SpeakerKit + FluidAudio (Deep)",
                    language: language,
                    minSpeakers: minSpeakers > 0 ? minSpeakers : nil,
                    maxSpeakers: maxSpeakers > 0 ? maxSpeakers : nil,
                    warnings: multiResult.disagreementCount > 0
                        ? ["Resolved \(multiResult.disagreementCount) speaker disagreements via AI analysis across \(multiResult.passes.count) engine passes."]
                        : [],
                    result: updatedResult,
                    qualitySummary: QualityAnalysisService.analyze(result: updatedResult)
                )

                project.appendPass(pass)
                currentProject = project
                synchronizeFromActivePass()
                await persistCurrentProject()
            }

            let summary = "Deep diarization complete. \(multiResult.passes.count) passes, \(multiResult.disagreementCount) disagreements resolved."
            cleanupProgress = summary
            processLog.log(summary, level: .success)
            isCleanupRunning = false

        } catch {
            cleanupError = "Deep diarization failed: \(error.localizedDescription)"
            cleanupProgress = ""
            processLog.log("Deep diarization failed: \(error.localizedDescription)", level: .error)
            isCleanupRunning = false
        }
    }

    func openReconciliation() {
        guard let referencePass = reconciliationReferencePass,
              let candidatePass = reconciliationCandidatePass else {
            presentError(TranscriboError.transcriptionFailed("Run a standard pass and a Deep Review comparison pass before opening reconciliation."))
            return
        }

        reconciliationDraft = ReconciliationService.buildDraft(
            referencePass: referencePass,
            candidatePass: candidatePass,
            existingConsensusPass: latestConsensusPass
        )
        reconciliationSelectedRowID = reconciliationDraft?.rows.first(where: { $0.differenceKind.hasDifference })?.id
            ?? reconciliationDraft?.rows.first?.id
        reconciliationStatusMessage = nil
        currentPhase = .reconcile

        // NOTE: LLM pre-resolution is NOT auto-fired — user can trigger manually
        // via the "AI Resolve" button in the reconciliation header to avoid
        // loading a multi-GB model simultaneously with complex view rendering.
        let discrepancyCount = reconciliationDraft?.rows.filter { $0.differenceKind.hasDifference }.count ?? 0
        if discrepancyCount > 0 {
            reconciliationStatusMessage = "\(discrepancyCount) discrepancies found. Use AI Resolve to auto-pick best options."
        }
    }

    /// Manually triggered LLM pre-resolution for reconciliation.
    func runLLMPreResolution() async {
        await preResolveReconciliationWithLLM()
    }

    /// Use local LLM to pre-resolve reconciliation discrepancies.
    private func preResolveReconciliationWithLLM() async {
        guard var draft = reconciliationDraft else { return }

        reconciliationStatusMessage = "AI is analyzing discrepancies..."
        processLog.isVisible = true
        processLog.log("Starting AI reconciliation pre-resolution...", level: .aiThinking)

        do {
            try await cleanupService.loadModel(selectedCleanupModel) { [weak self] progress in
                Task { @MainActor in
                    if progress < 1.0 {
                        self?.reconciliationStatusMessage = "Loading AI model... \(Int(progress * 100))%"
                    }
                }
            }

            processLog.log("AI model loaded: \(selectedCleanupModel.displayName)", level: .success)
            reconciliationStatusMessage = "AI classifying discrepancies (trivial vs substantive)..."
            processLog.setOutputLabel("AI Reconciliation")
            processLog.clearOutput()
            processLog.log("Classifying discrepancies as trivial vs substantive...", level: .aiThinking)

            let result = try await cleanupService.preResolveReconciliation(
                rows: draft.rows,
                speakerMapping: speakerMapping
            )

            // Apply LLM choices and trivial classifications to draft rows
            var trivialCount = 0
            var substantiveCount = 0

            for (rowID, choice) in result.choices {
                if let index = draft.rows.firstIndex(where: { $0.id == rowID }) {
                    let isTrivial = result.trivialRowIDs.contains(rowID)

                    switch choice {
                    case .reference:
                        draft.rows[index].selectedSource = .reference
                        draft.rows[index].draftText = draft.rows[index].referenceText
                        draft.rows[index].resolvedSpeakerID = draft.rows[index].referenceSpeakerID
                    case .candidate:
                        draft.rows[index].selectedSource = .candidate
                        draft.rows[index].draftText = draft.rows[index].candidateText
                        draft.rows[index].resolvedSpeakerID = draft.rows[index].candidateSpeakerID
                    case .manual:
                        break
                    }

                    // Speaker disagreements are ALWAYS substantive, regardless of LLM classification
                    let hasSpeakerDisagreement = draft.rows[index].differenceKind == .speaker
                        || draft.rows[index].differenceKind == .textAndSpeaker

                    if isTrivial && !hasSpeakerDisagreement {
                        // Auto-resolve trivial differences — no review needed
                        draft.rows[index].needsReview = false
                        draft.rows[index].differenceKind = .punctuation  // Downgrade to soft difference
                        trivialCount += 1
                    } else {
                        substantiveCount += 1
                    }
                }
            }

            draft.updatedAt = Date()
            reconciliationDraft = draft

            let statusMsg = "AI found \(substantiveCount) substantive and \(trivialCount) trivial differences. Only substantive ones need your review."
            reconciliationStatusMessage = statusMsg
            processLog.log("Reconciliation complete: \(trivialCount) trivial auto-resolved, \(substantiveCount) substantive for review", level: .success)

        } catch {
            reconciliationStatusMessage = "AI pre-resolution unavailable: \(error.localizedDescription)"
            processLog.log("AI pre-resolution failed: \(error.localizedDescription)", level: .error)
        }
    }

    func cancelTranscription() {
        pipeline.cancel()
    }

    func runCleanup() async {
        guard let result else { return }
        isCleanupRunning = true
        cleanupError = nil
        cleanupResult = nil
        cleanupProgress = "Loading model..."
        processLog.isVisible = true

        NSLog("[Polish] Starting cleanup with model: \(selectedCleanupModel.modelID)")
        processLog.log("Starting Polish with \(selectedCleanupModel.displayName)...", level: .aiThinking)

        do {
            // Load model — catch download/load failures separately
            do {
                NSLog("[Polish] Loading model...")
                try await cleanupService.loadModel(selectedCleanupModel) { [weak self] progress in
                    Task { @MainActor in
                        guard let self, self.isCleanupRunning else { return }
                        if progress < 1.0 {
                            self.cleanupProgress = "Downloading model... \(Int(progress * 100))%"
                        } else {
                            self.cleanupProgress = "Model ready, processing..."
                        }
                    }
                }
                NSLog("[Polish] Model loaded successfully")
            } catch {
                NSLog("[Polish] Model load FAILED: \(error)")
                throw TranscriboError.transcriptionFailed(
                    "Failed to load the cleanup model (\(selectedCleanupModel.displayName)). "
                    + "Try selecting a different model. "
                    + "Error: \(error.localizedDescription)"
                )
            }

            try Task.checkCancellation()

            let transcriptText = TranscriptCleanupService.formatForCleanup(
                result: result,
                speakerMapping: speakerMapping
            )

            NSLog("[Polish] Processing transcript (\(transcriptText.count) chars)...")
            cleanupProgress = "Processing transcript..."
            processLog.setOutputLabel("AI Output")
            processLog.clearOutput()
            processLog.log("Processing \(transcriptText.count) characters...", level: .aiThinking)

            let output = try await cleanupService.process(
                transcript: transcriptText,
                task: cleanupTask,
                tokenCallback: { [weak self] chunk in
                    Task { @MainActor in
                        self?.processLog.appendOutput(chunk)
                    }
                }
            )

            NSLog("[Polish] Processing complete, output: \(output.count) chars")
            cleanupResult = output
            cleanupProgress = "Complete"
            processLog.log("Polish complete: \(output.count) characters output", level: .success)
            isCleanupRunning = false
        } catch is CancellationError {
            NSLog("[Polish] Cancelled")
            cleanupProgress = ""
            processLog.log("Polish cancelled", level: .warning)
            isCleanupRunning = false
        } catch {
            NSLog("[Polish] Error: \(error)")
            cleanupError = error.localizedDescription
            cleanupProgress = ""
            processLog.log("Polish failed: \(error.localizedDescription)", level: .error)
            isCleanupRunning = false
        }
    }

    /// Summary-only convenience — forces the summarize task and stores result separately.
    var summaryResult: String?
    var isSummaryRunning: Bool = false
    var summaryProgress: String = ""
    var summaryError: String?

    func runSummary() async {
        guard let result else { return }
        isSummaryRunning = true
        summaryError = nil
        summaryResult = nil
        summaryProgress = "Loading model..."
        processLog.isVisible = true

        processLog.log("Generating summary with \(selectedCleanupModel.displayName)...", level: .aiThinking)

        do {
            do {
                try await cleanupService.loadModel(selectedCleanupModel) { [weak self] progress in
                    Task { @MainActor in
                        guard let self, self.isSummaryRunning else { return }
                        if progress < 1.0 {
                            self.summaryProgress = "Downloading model... \(Int(progress * 100))%"
                        } else {
                            self.summaryProgress = "Model ready, generating summary..."
                        }
                    }
                }
            } catch {
                throw TranscriboError.transcriptionFailed(
                    "Failed to load the AI model (\(selectedCleanupModel.displayName)). "
                    + "Error: \(error.localizedDescription)"
                )
            }

            try Task.checkCancellation()

            let transcriptText = TranscriptCleanupService.formatForCleanup(
                result: result,
                speakerMapping: speakerMapping
            )

            summaryProgress = "Generating summary..."
            processLog.setOutputLabel("AI Summary")
            processLog.clearOutput()
            processLog.log("Summarizing \(transcriptText.count) characters...", level: .aiThinking)

            let output = try await cleanupService.process(
                transcript: transcriptText,
                task: .summarize,
                tokenCallback: { [weak self] chunk in
                    Task { @MainActor in
                        self?.processLog.appendOutput(chunk)
                    }
                }
            )

            summaryResult = output
            summaryProgress = "Complete"
            processLog.log("Summary complete: \(output.count) characters", level: .success)
            isSummaryRunning = false
        } catch is CancellationError {
            summaryProgress = ""
            processLog.log("Summary cancelled", level: .warning)
            isSummaryRunning = false
        } catch {
            summaryError = error.localizedDescription
            summaryProgress = ""
            processLog.log("Summary failed: \(error.localizedDescription)", level: .error)
            isSummaryRunning = false
        }
    }

    func renameSpeaker(_ id: String, to name: String) {
        speakerMapping.rename(id, to: name)
        currentProject?.speakerMapping = speakerMapping

        Task {
            await persistCurrentProject()
        }
    }

    func persistProjectDraft() {
        Task {
            await persistCurrentProject()
        }
    }

    func selectReconciliationRow(id: UUID) {
        reconciliationSelectedRowID = id
    }

    func chooseReferenceForReconciliationRow(_ id: UUID) {
        updateReconciliationRow(id) { row in
            guard !row.referenceSegments.isEmpty else { return }
            row.selectedSource = .reference
            row.draftText = row.referenceText
            row.resolvedSpeakerID = row.referenceSpeakerID
        }
    }

    func chooseCandidateForReconciliationRow(_ id: UUID) {
        updateReconciliationRow(id) { row in
            guard !row.candidateSegments.isEmpty else { return }
            row.selectedSource = .candidate
            row.draftText = row.candidateText
            row.resolvedSpeakerID = row.candidateSpeakerID
        }
    }

    func updateReconciliationText(_ text: String, for rowID: UUID) {
        updateReconciliationRow(rowID) { row in
            row.draftText = text
            row.selectedSource = .manual
        }
    }

    func playReconciliationContext(for rowID: UUID) {
        guard let row = reconciliationRows.first(where: { $0.id == rowID }) else { return }
        guard let url = currentAudioURL else {
            presentError(TranscriboError.transcriptionFailed("The source audio file could not be found for playback."))
            return
        }

        let clipStart = max(0, row.start - 5)
        let maxDuration = audioDuration > 0 ? audioDuration : (result?.duration ?? row.end + 5)
        let clipEnd = min(maxDuration, row.end + 5)

        reconciliationPlayingRowID = rowID
        audioContextPlayer.play(url: url, from: clipStart, to: clipEnd) { [weak self] in
            self?.reconciliationPlayingRowID = nil
        }
    }

    func stopReconciliationPlayback() {
        audioContextPlayer.stop()
        reconciliationPlayingRowID = nil
    }

    func saveReconciliationConsensus() async {
        guard var project = currentProject,
              var draft = reconciliationDraft else {
            return
        }

        guard let consensusResult = buildConsensusResult(from: draft) else {
            presentError(TranscriboError.transcriptionFailed("Could not build a consensus transcript from the reconciliation draft."))
            return
        }

        let existingConsensusPass = latestConsensusPass
        let consensusPass = TranscriptionPass(
            id: draft.consensusPassID ?? existingConsensusPass?.id ?? UUID(),
            kind: .deepReviewConsensus,
            createdAt: existingConsensusPass?.createdAt ?? Date(),
            engineName: "Manual Reconciliation",
            modelName: "Consensus",
            diarizationEngineName: "Merged",
            language: language,
            minSpeakers: minSpeakers > 0 ? minSpeakers : nil,
            maxSpeakers: maxSpeakers > 0 ? maxSpeakers : nil,
            warnings: [],
            result: consensusResult,
            qualitySummary: QualityAnalysisService.analyze(result: consensusResult)
        )

        project.upsertPass(consensusPass)
        project.speakerMapping = speakerMapping
        project.transcriptionSettings = currentTranscriptionSettings()
        project.exportPreferences = currentExportPreferences()

        currentProject = project
        draft.consensusPassID = consensusPass.id
        draft.updatedAt = Date()
        reconciliationDraft = draft
        reconciliationStatusMessage = "Consensus saved."

        synchronizeFromActivePass()
        await persistCurrentProject()
    }

    func selectPass(id: UUID) {
        guard var project = currentProject else { return }
        project.setActivePass(id: id)
        currentProject = project
        synchronizeFromActivePass()

        Task {
            await persistCurrentProject()
        }
    }

    func formattedPreview() -> String {
        guard let result else { return "" }
        return ExportService.formatText(
            result: result,
            speakerMapping: speakerMapping,
            includeTimestamps: true
        )
    }

    func exportAll() async {
        guard let result else { return }

        // If only one format is selected, use a Save panel instead of a directory picker
        if selectedFormats.count == 1, let format = selectedFormats.first {
            await exportSingle(format: format)
            return
        }

        isExporting = true
        exportError = nil

        // For multiple formats, use NSOpenPanel to pick a directory
        let panel = NSOpenPanel()
        panel.title = "Choose Export Folder"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.prompt = "Export Here"
        panel.message = "Choose a folder to save \(selectedFormats.count) transcript files."

        let response = panel.runModal()
        guard response == .OK, let dir = panel.url else {
            isExporting = false
            return
        }

        do {
            let pdfOptions = LegalPDFOptions(
                showElapsedTime: showElapsedTime,
                showClockTime: showClockTime,
                recordingStartTime: recordingStartTime,
                headerText: legalPDFHeader
            )
            let paths = try ExportService.exportAll(
                result: result,
                speakerMapping: speakerMapping,
                formats: selectedFormats,
                legalPDFOptions: pdfOptions,
                to: dir
            )
            lastExportDirectory = dir
            isExporting = false

            for path in paths.values {
                if let format = ExportFormat(fileExtension: path.pathExtension) {
                    recordExport(format: format, destinationURL: path)
                }
            }
            await persistCurrentProject()

            NSWorkspace.shared.selectFile(
                paths.values.first?.path,
                inFileViewerRootedAtPath: dir.path
            )
        } catch {
            exportError = error.localizedDescription
            isExporting = false
        }
    }

    func exportSingle(format: ExportFormat) async {
        guard let result else { return }

        let panel = NSSavePanel()
        panel.title = "Save \(format.displayName)"
        panel.nameFieldLabel = "Save As:"
        panel.nameFieldStringValue = "\(result.audioFileName)_transcript.\(format.fileExtension)"
        panel.allowedContentTypes = [UTType(filenameExtension: format.fileExtension) ?? .plainText]
        panel.isExtensionHidden = false
        panel.canCreateDirectories = true
        panel.message = "Choose where to save the \(format.displayName) file."

        let response = panel.runModal()
        guard response == .OK, let url = panel.url else { return }

        do {
            let pdfOptions = LegalPDFOptions(
                showElapsedTime: showElapsedTime,
                showClockTime: showClockTime,
                recordingStartTime: recordingStartTime,
                headerText: legalPDFHeader
            )
            try ExportService.export(
                format: format,
                result: result,
                speakerMapping: speakerMapping,
                legalPDFOptions: pdfOptions,
                to: url
            )
            recordExport(format: format, destinationURL: url)
            await persistCurrentProject()
            NSWorkspace.shared.selectFile(url.path, inFileViewerRootedAtPath: url.deletingLastPathComponent().path)
        } catch {
            exportError = error.localizedDescription
        }
    }

    // MARK: - Private

    private func configureImportedAudio(
        info: AudioFileValidator.AudioInfo,
        url: URL,
        creationDate: Date?
    ) {
        audioFileURL = info.url
        audioDuration = info.duration
        audioFileName = info.fileName
        currentPhase = .setup
        result = nil
        speakerMapping = SpeakerMapping()
        speakerSamples = [:]
        reconciliationDraft = nil
        reconciliationSelectedRowID = nil
        reconciliationPlayingRowID = nil
        reconciliationStatusMessage = nil
        selectedFormats = [.legalPDF]
        showElapsedTime = true
        showClockTime = false
        // File creation date is when recording ENDED, so subtract duration to get start time
        if let creationDate {
            recordingStartTime = creationDate.addingTimeInterval(-info.duration)
        } else {
            recordingStartTime = nil
        }
        legalPDFHeader = Self.defaultLegalPDFHeader(fileName: info.fileName, creationDate: recordingStartTime)
    }

    private func loadProjectState(_ project: TranscriptionProject) {
        audioFileName = project.audioFileName
        audioDuration = project.audioDuration
        audioFileURL = resolveAudioURL(for: project)
        selectedModel = project.transcriptionSettings.model
        deepReviewEngine = project.transcriptionSettings.deepReviewEngineChoice ?? .defaultChoice
        deepReviewModel = project.transcriptionSettings.deepReviewComparisonModel ?? project.transcriptionSettings.model.recommendedDeepReviewModel
        minSpeakers = project.transcriptionSettings.minSpeakers
        maxSpeakers = project.transcriptionSettings.maxSpeakers
        language = project.transcriptionSettings.language
        speakerMapping = project.speakerMapping
        selectedFormats = Set(project.exportPreferences.selectedFormats)
        showElapsedTime = project.exportPreferences.showElapsedTime
        showClockTime = project.exportPreferences.showClockTime
        recordingStartTime = project.exportPreferences.recordingStartTime
        legalPDFHeader = project.exportPreferences.legalPDFHeader
        reconciliationDraft = nil
        reconciliationSelectedRowID = nil
        reconciliationPlayingRowID = nil
        reconciliationStatusMessage = nil

        if let activePass = project.activePass {
            result = activePass.result
            speakerSamples = extractSpeakerSamples(from: activePass.result)
            currentPhase = .review
        } else {
            result = nil
            speakerSamples = [:]
            currentPhase = .setup
        }
    }

    private func saveCompletedPass(
        result: TranscriptionResult,
        kind: TranscriptionPassKind,
        engine: TranscriptionEngineDescriptor,
        resetSpeakerMapping: Bool
    ) async {
        guard var project = currentProject else { return }

        if resetSpeakerMapping {
            project.speakerMapping = SpeakerMapping()
        } else {
            project.speakerMapping = speakerMapping
        }
        project.transcriptionSettings = currentTranscriptionSettings()
        project.exportPreferences = currentExportPreferences()
        project.updatedAt = Date()

        let pass = TranscriptionPass(
            kind: kind,
            engineName: engine.engineName,
            modelName: engine.modelName,
            diarizationEngineName: diarizationEngine.shortName,
            language: language,
            minSpeakers: minSpeakers > 0 ? minSpeakers : nil,
            maxSpeakers: maxSpeakers > 0 ? maxSpeakers : nil,
            warnings: pipeline.lastWarnings,
            result: result,
            qualitySummary: QualityAnalysisService.analyze(result: result)
        )

        project.appendPass(pass)
        currentProject = project
        synchronizeFromActivePass()
        await persistCurrentProject()
    }

    private func persistCurrentProject() async {
        guard var project = currentProject else { return }

        project.name = audioFileName.isEmpty ? project.name : audioFileName
        project.audioFileName = audioFileName.isEmpty ? project.audioFileName : audioFileName
        project.audioDuration = audioDuration > 0 ? audioDuration : project.audioDuration
        project.sourceAudioPath = audioFileURL?.path(percentEncoded: false) ?? project.sourceAudioPath
        if let audioFileURL {
            project.sourceAudioBookmark = bookmarkData(for: audioFileURL) ?? project.sourceAudioBookmark
        }
        project.transcriptionSettings = currentTranscriptionSettings()
        project.exportPreferences = currentExportPreferences()
        project.speakerMapping = speakerMapping
        project.updatedAt = Date()

        currentProject = project

        do {
            try await projectStore.saveProject(project)
            projects = try await projectStore.loadProjectSummaries()
        } catch {
            presentError(error)
        }
    }

    private func recordExport(format: ExportFormat, destinationURL: URL) {
        currentProject?.exportHistory.append(
            ExportRecord(format: format, destinationPath: destinationURL.path(percentEncoded: false))
        )
        currentProject?.exportPreferences = currentExportPreferences()
    }

    private func currentTranscriptionSettings() -> ProjectTranscriptionSettings {
        ProjectTranscriptionSettings(
            model: selectedModel,
            deepReviewEngineChoice: deepReviewEngine,
            deepReviewComparisonModel: deepReviewModel,
            minSpeakers: minSpeakers,
            maxSpeakers: maxSpeakers,
            language: language
        )
    }

    private func currentExportPreferences() -> ProjectExportPreferences {
        ProjectExportPreferences(
            selectedFormats: selectedFormats.sorted { $0.rawValue < $1.rawValue },
            showElapsedTime: showElapsedTime,
            showClockTime: showClockTime,
            recordingStartTime: recordingStartTime,
            legalPDFHeader: legalPDFHeader
        )
    }

    private func resolveAudioURL(for project: TranscriptionProject) -> URL? {
        if let bookmarkData = project.sourceAudioBookmark {
            var isStale = false
            if let url = try? URL(
                resolvingBookmarkData: bookmarkData,
                options: [.withSecurityScope],
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            ) {
                return url
            }
        }

        guard let sourceAudioPath = project.sourceAudioPath else { return nil }
        return URL(fileURLWithPath: sourceAudioPath)
    }

    private func updateReconciliationRow(
        _ rowID: UUID,
        update: (inout ReconciliationRow) -> Void
    ) {
        guard var draft = reconciliationDraft,
              let index = draft.rows.firstIndex(where: { $0.id == rowID }) else {
            return
        }

        update(&draft.rows[index])
        draft.rows[index].needsReview = reconciliationNeedsReview(for: draft.rows[index])
        draft.updatedAt = Date()
        reconciliationDraft = draft
        reconciliationStatusMessage = nil
    }

    private func reconciliationNeedsReview(for row: ReconciliationRow) -> Bool {
        guard row.differenceKind.hasDifference else {
            return false
        }

        let referenceText = row.referenceText.trimmingCharacters(in: .whitespacesAndNewlines)
        let candidateText = row.candidateText.trimmingCharacters(in: .whitespacesAndNewlines)
        let draftText = row.draftText.trimmingCharacters(in: .whitespacesAndNewlines)

        let matchesReference = !referenceText.isEmpty && normalizeComparisonText(draftText) == normalizeComparisonText(referenceText)
        let matchesCandidate = !candidateText.isEmpty && normalizeComparisonText(draftText) == normalizeComparisonText(candidateText)

        if row.referenceSegments.isEmpty || row.candidateSegments.isEmpty {
            return !(matchesReference || matchesCandidate)
        }

        if row.selectedSource == .manual {
            return !(matchesReference || matchesCandidate)
        }

        return false
    }

    private func buildConsensusResult(from draft: ReconciliationDraft) -> TranscriptionResult? {
        let audioPath = currentAudioURL?.path(percentEncoded: false)
            ?? currentProject?.sourceAudioPath
            ?? result?.audioPath

        guard let audioPath else { return nil }

        let segments = draft.rows.compactMap { row -> TranscriptionSegment? in
            let finalText = row.draftText.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !finalText.isEmpty else { return nil }

            let baseSegments = consensusBaseSegments(for: row)
            let baseText = ReconciliationSegmentSummary.joinedText(baseSegments)
            let keepWordTimings = normalizeComparisonText(baseText) == normalizeComparisonText(finalText)

            return TranscriptionSegment(
                speakerID: row.resolvedSpeakerID,
                start: row.start,
                end: row.end,
                text: finalText,
                words: keepWordTimings ? ReconciliationSegmentSummary.aggregateWords(baseSegments) : nil,
                averageLogProb: averageValue(baseSegments.map(\.averageLogProb)),
                noSpeechProb: averageValue(baseSegments.map(\.noSpeechProb)),
                decodingTemperature: averageValue(baseSegments.map(\.decodingTemperature)),
                compressionRatio: averageValue(baseSegments.map(\.compressionRatio)),
                diarizationQuality: ReconciliationSegmentSummary.averageDiarizationQuality(baseSegments),
                diarizationOverlap: baseSegments.compactMap(\.diarizationOverlap).max()
            )
        }

        let duration = currentProject?.audioDuration ?? result?.duration ?? audioDuration
        return TranscriptionResult(audioPath: audioPath, duration: duration, segments: segments)
    }

    private func consensusBaseSegments(for row: ReconciliationRow) -> [TranscriptionSegment] {
        switch row.selectedSource {
        case .reference:
            return row.referenceSegments.isEmpty ? row.candidateSegments : row.referenceSegments
        case .candidate:
            return row.candidateSegments.isEmpty ? row.referenceSegments : row.candidateSegments
        case .manual:
            if normalizeComparisonText(row.referenceText) == normalizeComparisonText(row.draftText) {
                return row.referenceSegments
            }

            if normalizeComparisonText(row.candidateText) == normalizeComparisonText(row.draftText) {
                return row.candidateSegments
            }

            let referenceConfidence = row.referenceAverageConfidence ?? 0
            let candidateConfidence = row.candidateAverageConfidence ?? 0
            return candidateConfidence > referenceConfidence
                ? (row.candidateSegments.isEmpty ? row.referenceSegments : row.candidateSegments)
                : (row.referenceSegments.isEmpty ? row.candidateSegments : row.referenceSegments)
        }
    }

    private func averageValue(_ values: [Float?]) -> Float? {
        let presentValues = values.compactMap { $0 }
        guard !presentValues.isEmpty else { return nil }
        let total = presentValues.reduce(Float.zero, +)
        return total / Float(presentValues.count)
    }

    private func normalizeComparisonText(_ text: String) -> String {
        text
            .lowercased()
            .replacingOccurrences(of: "[^a-z0-9\\s]", with: "", options: .regularExpression)
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func synchronizeFromActivePass() {
        guard let project = currentProject else { return }
        speakerMapping = project.speakerMapping

        if let activePass = project.activePass {
            result = activePass.result
            speakerSamples = extractSpeakerSamples(from: activePass.result)
        } else {
            result = nil
            speakerSamples = [:]
        }
    }

    private func runPipelinePass(
        kind: TranscriptionPassKind,
        engine: TranscriptionEngineDescriptor,
        resetSpeakerMapping: Bool
    ) async {
        guard let url = currentAudioURL else {
            presentError(TranscriboError.transcriptionFailed("The source audio file could not be found. Re-import the audio file to continue."))
            return
        }

        let accessing = url.startAccessingSecurityScopedResource()
        defer {
            if accessing {
                url.stopAccessingSecurityScopedResource()
            }
        }

        if let transcriptionResult = await pipeline.run(
            audioURL: url,
            engine: engine,
            minSpeakers: minSpeakers > 0 ? minSpeakers : nil,
            maxSpeakers: maxSpeakers > 0 ? maxSpeakers : nil,
            language: language
        ) {
            if resetSpeakerMapping {
                speakerMapping = SpeakerMapping()
            }

            result = transcriptionResult
            speakerSamples = extractSpeakerSamples(from: transcriptionResult)
            currentPhase = kind == .standard ? .review : .quality
            await saveCompletedPass(
                result: transcriptionResult,
                kind: kind,
                engine: engine,
                resetSpeakerMapping: resetSpeakerMapping
            )
        } else if case .failed(let error) = pipeline.state {
            presentError(error)
        }
    }

    private func bookmarkData(for url: URL) -> Data? {
        try? url.bookmarkData(
            options: [.withSecurityScope],
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )
    }

    private func extractSpeakerSamples(from result: TranscriptionResult) -> [String: String] {
        var samples: [String: String] = [:]
        for seg in result.segments {
            let spk = seg.speakerID
            let text = seg.text.trimmingCharacters(in: .whitespaces)
            if samples[spk] == nil, !text.isEmpty {
                let sample = String(text.prefix(120))
                samples[spk] = text.count > 120 ? sample + "..." : sample
            }
        }
        return samples
    }

    private func presentError(_ error: Error) {
        errorMessage = error.localizedDescription
        showError = true
    }

    private static func creationDate(for url: URL) -> Date? {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let creationDate = attrs[.creationDate] as? Date else {
            return nil
        }
        return creationDate
    }

    private static func defaultLegalPDFHeader(fileName: String, creationDate: Date?) -> String {
        guard let creationDate else {
            return "TRANSCRIPT\n\(fileName)"
        }

        let formatter = DateFormatter()
        formatter.dateStyle = .long
        formatter.timeStyle = .short
        return "TRANSCRIPT\n\(fileName)\n\(formatter.string(from: creationDate))"
    }
}

private extension ExportFormat {
    init?(fileExtension: String) {
        guard let format = ExportFormat.allCases.first(where: { $0.fileExtension == fileExtension }) else {
            return nil
        }
        self = format
    }
}
