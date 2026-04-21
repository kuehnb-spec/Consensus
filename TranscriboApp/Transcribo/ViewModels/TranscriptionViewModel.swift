import AVFoundation
import SwiftUI
import UniformTypeIdentifiers

@Observable
@MainActor
final class TranscriptionViewModel {
    // Primary transcription engine
    enum PrimaryEngine: String, CaseIterable, Identifiable {
        case parakeetV3 = "Parakeet v3"
        case whisper = "WhisperKit"

        var id: String { rawValue }

        var description: String {
            switch self {
            case .parakeetV3: return "Recommended. CTC-native timestamps, best diarization accuracy."
            case .whisper: return "Multiple model sizes. Cleaner text formatting."
            }
        }
    }

    // Phase 1: Setup
    var audioFileURL: URL?
    var audioDuration: TimeInterval = 0
    var audioFileName: String = ""
    var primaryEngine: PrimaryEngine = .parakeetV3
    var selectedModel: WhisperModel
    var deepReviewEngine: DeepReviewEngineChoice
    var deepReviewModel: WhisperModel
    // deepReviewTranscription and deepReviewDiarization removed — each step is now
    // independently triggered from the Deep Review wizard views.
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

    // Confidence-weighted merge (new reconciliation approach)
    var mergedTranscript: MergedTranscript?
    var selectedMergeFlagID: UUID?
    var playingMergeFlagID: UUID?

    // Forced-alignment stage (Phase 1 of the memo's Word-Timeline Rebuild).
    // Runs after ConfidenceMergeService builds a MergedTranscript, re-deriving
    // word timings from the audio against the chosen text. See
    // Brainstorming/WORD-TIMELINE-REBUILD-PLAN.md for scope and risks.
    var isAligningWordTimings: Bool = false
    var wordAlignmentProgress: String = ""
    var wordAlignmentError: String?
    /// Last delta summary from a successful forced-alignment pass. Displayed
    /// as a badge on the merged-transcript view for transparency.
    var lastWordAlignmentDelta: ForcedAlignmentDelta?

    // Export
    var selectedFormats: Set<ExportFormat> = [.legalPDF]
    var isExporting = false
    var exportError: String?
    var lastExportDirectory: URL?

    // Legal PDF options
    var showElapsedTime: Bool = true
    var showClockTime: Bool = false
    var includeQualityTierBadge: Bool = false
    var highlightLowConfidence: Bool = false
    var recordingStartTime: Date?
    var legalPDFHeader: String = ""
    var includeCoverPage: Bool = false
    var coverPageIncludeSummary: Bool = true
    var coverPageIncludeActionItems: Bool = true
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

    /// Snapshot of pre-Polish segment state for the currently active pass. Captured
    /// before `applyCleanedText` rewrites the transcript; lets the user undo a Polish
    /// that went wrong. Cleared when the user closes the project, runs a new
    /// transcription, or manually performs an undo.
    struct PolishUndoSnapshot: Sendable {
        let passID: UUID
        let segments: [TranscriptionSegment]
        let speakerMapping: SpeakerMapping
        let capturedAt: Date
    }
    var polishUndoSnapshot: PolishUndoSnapshot?

    /// Whether the Manual Transcript Editor sheet is currently open.
    var showManualEditor: Bool = false

    /// Snapshot of pre-manual-edit segment state, for Undo parity with Polish.
    var manualEditUndoSnapshot: PolishUndoSnapshot?
    var canUndoManualEdit: Bool {
        guard let snapshot = manualEditUndoSnapshot,
              let project = currentProject,
              let passIndex = project.passes.firstIndex(where: { $0.id == snapshot.passID }) else {
            return false
        }
        return project.passes[passIndex].result.segments.count > 0
    }
    var canUndoPolish: Bool {
        guard let snapshot = polishUndoSnapshot,
              let project = currentProject,
              let passIndex = project.passes.firstIndex(where: { $0.id == snapshot.passID }) else {
            return false
        }
        return project.passes[passIndex].result.segments.count > 0
    }

    // Process Log
    let processLog = ProcessLog()

    // Navigation
    enum WorkflowPhase: Hashable {
        // Standard workflow
        case setup      // Upload + configure + transcribe
        case review     // Transcript + speaker labeling
        case export     // Format selection + export

        // Deep Review wizard (guided sequential steps)
        case deepTranscription   // Run Engine B + auto-merge + flag review
        case deepDiarization     // Multi-pass + LLM boundary confirmation
        case deepSpeakerConfirm  // Confirm auto-mapped speaker names
        case deepReviewCompare   // Before/after summary + final preview

        // Utility
        case help
        case summary
        case polish          // LLM cleanup + summary of the transcript
        case comparePasses   // Side-by-side pass comparison

        var isDeepReview: Bool {
            switch self {
            case .deepTranscription, .deepDiarization, .deepSpeakerConfirm, .deepReviewCompare:
                return true
            default:
                return false
            }
        }
    }
    var currentPhase: WorkflowPhase = .setup
    var hasEnteredWorkflow: Bool = false
    var deepReviewCompletedSteps: Set<String> = []

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
    var isInDeepReview: Bool { currentPhase.isDeepReview }
    var qualityTier: String {
        hasConsensusPass ? "Verified Transcript" : "Standard Transcript"
    }
    var activePass: TranscriptionPass? { currentProject?.activePass }
    var standardPass: TranscriptionPass? {
        currentProject?.passes.last(where: { $0.kind == .standard })
    }
    var latestDeepComparisonPass: TranscriptionPass? {
        currentProject?.passes.last(where: { $0.kind == .deepReviewComparison })
    }
    var latestDeepDiarizationPass: TranscriptionPass? {
        currentProject?.passes.last(where: { $0.kind == .deepReviewPrimary })
    }
    var passHistory: [TranscriptionPass] {
        (currentProject?.passes ?? []).sorted { $0.createdAt > $1.createdAt }
    }
    var qualitySummary: TranscriptQualitySummary? { activePass?.qualitySummary }
    var qualityFlags: [QualityFlag] { qualitySummary?.riskySegments ?? [] }
    var currentWarnings: [String] { activePass?.warnings ?? [] }
    var currentAudioURL: URL? { audioFileURL ?? currentProject.flatMap(resolveAudioURL(for:)) }
    var comparisonReferencePass: TranscriptionPass? {
        guard let activePass, let project = currentProject else { return nil }

        if let sourcePassID = activePass.sourcePassID,
           let sourcePass = project.passes.first(where: { $0.id == sourcePassID }) {
            return sourcePass
        }

        if activePass.kind == .standard {
            return latestDeepComparisonPass
                ?? latestDeepDiarizationPass
                ?? project.passes.last(where: { $0.id != activePass.id })
        }

        return standardPass
            ?? project.passes.last(where: { $0.id != activePass.id })
    }
    var passComparisonSummary: PassComparisonSummary? {
        guard let activePass, let reference = comparisonReferencePass else { return nil }
        return PassComparisonService.compare(reference: reference, candidate: activePass)
    }
    var reconciliationReferencePass: TranscriptionPass? {
        guard let project = currentProject else { return nil }

        if let candidatePass = reconciliationCandidatePass,
           let sourcePassID = candidatePass.sourcePassID,
           let sourcePass = project.passes.first(where: { $0.id == sourcePassID }) {
            return sourcePass
        }

        return standardPass ?? project.passes.last(where: { $0.kind != .deepReviewConsensus })
    }
    var reconciliationCandidatePass: TranscriptionPass? {
        if let activePass,
           activePass.kind == .deepReviewComparison || activePass.kind == .deepReviewPrimary {
            return activePass
        }

        return latestDeepComparisonPass ?? latestDeepDiarizationPass
    }
    var latestConsensusPass: TranscriptionPass? {
        currentProject?.passes.last(where: { $0.kind == .deepReviewConsensus })
    }
    // deepDiarizationBasePass removed — refineSpeakers() now prefers mergedTranscript
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

    /// Track when transcription started for ETA calculations.
    private var transcriptionStartTime: Date?

    var statusMessage: String {
        switch pipeline.state {
        case .idle: return "Ready"
        case .loadingAudio: return "Loading audio..."
        case .downloadingModel(let p):
            return p >= 1.0 ? "Compiling model (this may take a minute)..." : "Downloading model... \(Int(p * 100))%"
        case .transcribing(let p, _):
            if transcriptionStartTime == nil { transcriptionStartTime = Date() }
            let eta = estimatedTimeRemaining(progress: p)
            return eta != nil ? "Transcribing... \(Int(p * 100))% (\(eta!) remaining)" : "Transcribing... \(Int(p * 100))%"
        case .diarizing: return "Identifying speakers..."
        case .mergingResults: return "Preparing results..."
        case .complete: return "Complete"
        case .failed(let err): return "Error: \(err.localizedDescription)"
        case .cancelled: return "Cancelled"
        }
    }

    /// Estimate remaining time based on current progress and elapsed time.
    private func estimatedTimeRemaining(progress: Double) -> String? {
        guard progress > 0.05, let start = transcriptionStartTime else { return nil }
        let elapsed = Date().timeIntervalSince(start)
        let totalEstimate = elapsed / progress
        let remaining = totalEstimate - elapsed
        guard remaining > 5 else { return nil } // Don't show for < 5 seconds

        if remaining < 60 {
            return "\(Int(remaining))s"
        } else if remaining < 3600 {
            let min = Int(remaining) / 60
            let sec = Int(remaining) % 60
            return "\(min)m \(sec)s"
        } else {
            let hours = Int(remaining) / 3600
            let min = (Int(remaining) % 3600) / 60
            return "\(hours)h \(min)m"
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
            configureImportedAudio(info: info, url: url)
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
            hasEnteredWorkflow = true
            loadProjectState(project)
            await persistCurrentProject()
        } catch {
            presentError(error)
        }
    }

    func closeProject() {
        pipeline.reset()
        currentProject = nil
        hasEnteredWorkflow = false
        result = nil
        speakerMapping = SpeakerMapping()
        speakerSamples = [:]
        reconciliationDraft = nil
        reconciliationSelectedRowID = nil
        reconciliationPlayingRowID = nil
        reconciliationStatusMessage = nil
        mergedTranscript = nil
        selectedMergeFlagID = nil
        playingMergeFlagID = nil
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

    func deleteProject(id: UUID) async {
        // If deleting the currently open project, close it first
        if currentProject?.id == id {
            closeProject()
        }

        do {
            try await projectStore.deleteProject(id: id)
            await refreshProjectLibrary()
        } catch {
            presentError(error)
        }
    }

    func shareableProjectURL(for id: UUID) async -> URL? {
        await projectStore.shareableFileURL(for: id)
    }

    /// Write the current process log to a markdown file on disk and return the URL.
    /// Used by the Diagnostic Mode "Save Report" button to capture a full audit of a
    /// Deep Review run — every smoother reassignment, every LLM confirmation, every
    /// FA word-move — for offline review. The caller is responsible for surfacing the
    /// file (open a Save panel, reveal in Finder, etc.).
    func saveDiagnosticReport() -> URL? {
        let fm = FileManager.default
        let docs = fm.urls(for: .documentDirectory, in: .userDomainMask).first ?? fm.temporaryDirectory
        let folder = docs.appendingPathComponent("Consensus Diagnostics", isDirectory: true)
        try? fm.createDirectory(at: folder, withIntermediateDirectories: true)

        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd_HHmmss"
        let projectName = currentProject?.name.replacingOccurrences(of: "/", with: "-") ?? "unknown"
        let fileURL = folder.appendingPathComponent(
            "\(formatter.string(from: Date()))_\(projectName).md",
            conformingTo: .plainText
        )

        let title = currentProject.map { "Diagnostic Report · \($0.name)" } ?? "Diagnostic Report"
        let markdown = processLog.renderAsMarkdown(title: title)
        do {
            try markdown.write(to: fileURL, atomically: true, encoding: .utf8)
            processLog.log("Diagnostic report saved to \(fileURL.path)", level: .success)
            return fileURL
        } catch {
            processLog.log("Failed to save diagnostic report: \(error.localizedDescription)", level: .error)
            return nil
        }
    }

    /// Discard all transcription passes on the currently-open project and return to the
    /// Transcribe phase, keeping the project identity (UUID, name, audio link, export
    /// preferences, templates). Intended for "I want to re-run this project fresh with
    /// the new pipeline code" — so the user keeps their project metadata but gets a
    /// clean slate for transcription + diarization + Deep Review work.
    ///
    /// Destructive: all prior passes (Standard, Deep Review, Consensus) are removed.
    /// Speaker names are also cleared since they were tied to the old SPEAKER_0/1 IDs
    /// which won't match a fresh diarization run.
    func restartCurrentProjectFromScratch() async {
        guard var project = currentProject else { return }

        // Clear all pass data from the project model
        project.passes = []
        project.activePassID = nil
        project.speakerMapping = SpeakerMapping()
        project.updatedAt = Date()

        // Reset in-memory state that's derived from pass data
        result = nil
        speakerMapping = SpeakerMapping()
        speakerSamples = [:]
        reconciliationDraft = nil
        reconciliationSelectedRowID = nil
        reconciliationPlayingRowID = nil
        reconciliationStatusMessage = nil
        mergedTranscript = nil
        selectedMergeFlagID = nil
        playingMergeFlagID = nil
        cleanupResult = nil
        cleanupError = nil
        deepReviewCompletedSteps = []

        // Return to the Transcribe phase so the user can re-run
        currentPhase = .setup

        currentProject = project
        await persistCurrentProject()
        await refreshProjectLibrary()
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
        transcriptionStartTime = nil
        pipeline.diarizationEngine = diarizationEngine
        processLog.isVisible = true
        processLog.clear()
        let engine: TranscriptionEngineDescriptor
        switch primaryEngine {
        case .parakeetV3:
            engine = .fluidAsr(.parakeetV3)
        case .whisper:
            engine = .whisper(selectedModel)
        }
        await runPipelinePass(kind: .standard, engine: engine, resetSpeakerMapping: true)
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
            let pdfOptions = buildLegalPDFOptions()
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

    /// Step 1 of Deep Review: Run Engine B transcription (text-only) and build
    /// a confidence-weighted merge with Engine A. Does NOT run diarization or
    /// advance to the next phase — the user clicks "Continue" to proceed.
    func startDeepTranscription() async {
        guard currentProject?.hasTranscript == true else {
            presentError(TranscriboError.transcriptionFailed("Run a standard transcription before starting Deep Review."))
            return
        }

        // Remember the diarized standard pass so we can restore it after Engine B runs
        let diarizedPassID = standardPass?.id ?? activePass?.id

        // Run Engine B for text-only comparison (no diarization — we keep Engine A's speakers)
        let engine: TranscriptionEngineDescriptor
        switch deepReviewEngine {
        case .whisper:
            engine = .whisper(deepReviewModel)
        case .parakeetV3:
            engine = .fluidAsr(.parakeetV3)
        case .parakeetV2:
            engine = .fluidAsr(.parakeetV2)
        }

        // Skip diarization on Engine B — we only need its text + word timings
        pipeline.skipDiarization = true
        await runPipelinePass(
            kind: .deepReviewComparison,
            engine: engine,
            resetSpeakerMapping: false,
            sourcePassID: diarizedPassID
        )
        pipeline.skipDiarization = false

        // Switch back to the diarized standard pass so the transcript view
        // shows proper speaker labels while the comparison pass is saved.
        if let diarizedPassID {
            selectPass(id: diarizedPassID)
        }

        // Build confidence-weighted merge if we have both passes
        if reconciliationReferencePass != nil && reconciliationCandidatePass != nil {
            openReconciliationMerge()
        }

        deepReviewCompletedSteps.insert("transcription")
    }

    /// Build the confidence-weighted merge without changing the current phase.
    /// Called internally by startDeepTranscription after Engine B completes.
    /// Dispatches to the merge strategy selected in `settings.deepMergeMode`.
    private func openReconciliationMerge() {
        guard let referencePass = reconciliationReferencePass,
              let candidatePass = reconciliationCandidatePass else {
            return
        }

        switch settings.deepMergeMode {
        case .llmReconcile:
            // LLM reconciliation is async (model load + prompt + parse).
            // Dispatch to the async entry point; UI shows progress via cleanupProgress.
            Task { [weak self] in
                await self?.runLLMReconciliation(
                    referencePass: referencePass,
                    candidatePass: candidatePass
                )
            }

        case .engineAOnly, .confidenceWeighted:
            // Synchronous path — same as before, with applyConfidenceMerge honoring
            // the legacy setting for the `.confidenceWeighted` case.
            let applyMerge = settings.deepMergeMode == .confidenceWeighted
            let merged = ConfidenceMergeService.buildMergedTranscript(
                referencePass: referencePass,
                candidatePass: candidatePass,
                applyConfidenceMerge: applyMerge
            )
            mergedTranscript = merged

            let flagCount = merged.totalFlagCount
            if flagCount > 0 {
                reconciliationStatusMessage = "\(flagCount) regions flagged for review."
            } else {
                reconciliationStatusMessage = "Engines agree on the full transcript."
            }

            // Kick off forced alignment if enabled (sync path only).
            if settings.enableForcedAlignment {
                Task { [weak self] in
                    await self?.rebuildWordTimeline()
                }
            }
        }
    }

    /// Run LLM reconciliation on two passes via the local Qwen model. Produces a
    /// `MergedTranscript` wrapped around the LLM-reasoned output, then kicks off
    /// optional forced alignment. Called by `openReconciliationMerge` when
    /// `settings.deepMergeMode == .llmReconcile`.
    private func runLLMReconciliation(
        referencePass: TranscriptionPass,
        candidatePass: TranscriptionPass
    ) async {
        let reconciler = LLMReconcileService()
        processLog.isVisible = true
        processLog.log("LLM reconciliation: loading \(selectedCleanupModel.displayName)...", level: .aiThinking)
        cleanupProgress = "Loading reconciliation model..."
        isCleanupRunning = true
        defer { isCleanupRunning = false; cleanupProgress = "" }

        do {
            try await reconciler.loadModel(selectedCleanupModel) { [weak self] progress in
                Task { @MainActor in
                    if progress < 1.0 {
                        self?.cleanupProgress = "Loading model... \(Int(progress * 100))%"
                    }
                }
            }

            cleanupProgress = "Reconciling transcripts — reading both engines and applying context..."
            processLog.setOutputLabel("LLM Reconciliation")
            processLog.clearOutput()

            let knownNames = Array(speakerMapping.names.values).filter { !$0.isEmpty }
            let options = LLMReconcileService.ReconcileOptions(
                domainHint: nil,
                knownSpeakerNames: knownNames,
                maxTokens: 16_000
            )

            let segments = try await reconciler.reconcile(
                referencePass: referencePass,
                candidatePass: candidatePass,
                speakerMapping: speakerMapping,
                options: options,
                tokenCallback: { [weak self] chunk in
                    Task { @MainActor in self?.processLog.appendOutput(chunk) }
                }
            )

            guard !segments.isEmpty else {
                processLog.log("LLM reconciliation returned no segments; falling back to Engine A.", level: .warning)
                let fallback = ConfidenceMergeService.buildMergedTranscript(
                    referencePass: referencePass,
                    candidatePass: candidatePass,
                    applyConfidenceMerge: false
                )
                mergedTranscript = fallback
                return
            }

            // Wrap the LLM-produced segments in a MergedTranscript so the rest of the
            // UI (review flags, exports, Step-4 compare view) works unchanged. Each
            // reconciled segment becomes a MergedSegment with a single "merged"
            // source word per word of text — we don't have word-level confidence
            // from the LLM, so text fidelity flows through as-is and any uncertain
            // regions the LLM flagged become MergeFlags for the user to review.
            let (mergedSegments, flags) = Self.buildMergedTranscriptFromLLM(
                reconciled: segments,
                referencePass: referencePass,
                candidatePass: candidatePass
            )

            let merged = MergedTranscript(
                referencePassID: referencePass.id,
                candidatePassID: candidatePass.id,
                referenceLabel: "\(referencePass.kind.displayName) \u{2022} \(referencePass.modelName)",
                candidateLabel: "\(candidatePass.kind.displayName) \u{2022} \(candidatePass.modelName)",
                segments: mergedSegments,
                flags: flags
            )
            mergedTranscript = merged
            processLog.log(
                "LLM reconciliation complete: \(segments.count) turn(s), \(flags.count) flagged uncertain.",
                level: .success
            )
            let uncertainCount = segments.filter { $0.isUncertain }.count
            if uncertainCount > 0 {
                reconciliationStatusMessage = "\(uncertainCount) regions flagged uncertain by the LLM — review in the editor."
            } else {
                reconciliationStatusMessage = "LLM reconciliation complete."
            }

            // Forced alignment still applies — the LLM didn't set word timings.
            if settings.enableForcedAlignment {
                Task { [weak self] in await self?.rebuildWordTimeline() }
            }
        } catch {
            processLog.log("LLM reconciliation failed: \(error.localizedDescription). Falling back to Engine A.", level: .error)
            let fallback = ConfidenceMergeService.buildMergedTranscript(
                referencePass: referencePass,
                candidatePass: candidatePass,
                applyConfidenceMerge: false
            )
            mergedTranscript = fallback
        }
    }

    /// Build `MergedSegment`s and `MergeFlag`s from LLM-reconciled output. Each
    /// reconciled segment becomes one MergedSegment; segments the LLM flagged as
    /// uncertain become MergeFlags for the user to review in the editor.
    private static func buildMergedTranscriptFromLLM(
        reconciled: [LLMReconcileService.ReconciledSegment],
        referencePass: TranscriptionPass,
        candidatePass: TranscriptionPass
    ) -> (segments: [MergedSegment], flags: [MergeFlag]) {
        var segments: [MergedSegment] = []
        var flags: [MergeFlag] = []

        for (segIndex, rseg) in reconciled.enumerated() {
            // Split text into pseudo-words with linearly-interpolated timings for
            // the MergedWord / flag machinery. True word timings come from forced
            // alignment as a separate pass.
            let tokens = rseg.text.split(whereSeparator: { $0.isWhitespace }).map(String.init)
            guard !tokens.isEmpty else { continue }
            let duration = max(0.1, rseg.end - rseg.start)
            let perWord = duration / Double(tokens.count)
            var words: [MergedWord] = []
            words.reserveCapacity(tokens.count)
            for (i, tok) in tokens.enumerated() {
                let start = Float(rseg.start + Double(i) * perWord)
                let end = Float(rseg.start + Double(i + 1) * perWord)
                words.append(MergedWord(
                    word: tok,
                    start: start,
                    end: end,
                    confidence: rseg.isUncertain ? 0.5 : 0.9,
                    source: .agreed(
                        referenceWord: tok, candidateWord: tok,
                        referenceConfidence: 0.9, candidateConfidence: 0.9
                    ),
                    speakerID: rseg.speakerID
                ))
            }

            var seg = MergedSegment(
                speakerID: rseg.speakerID,
                start: rseg.start,
                end: rseg.end,
                words: words
            )

            if rseg.isUncertain {
                let flagIndex = flags.count
                flags.append(MergeFlag(
                    kind: .lowConfidence,
                    segmentIndex: segIndex,
                    wordRange: 0..<words.count,
                    start: rseg.start,
                    end: rseg.end,
                    mergedText: rseg.text,
                    referenceText: rseg.text,
                    candidateText: rseg.text,
                    referenceSpeakerID: rseg.speakerID,
                    candidateSpeakerID: rseg.speakerID,
                    referenceConfidence: 0.5,
                    candidateConfidence: 0.5
                ))
                seg.flagIndices.append(flagIndex)
            }

            segments.append(seg)
        }
        _ = referencePass  // placeholder — signature keeps these for future use
        _ = candidatePass
        return (segments, flags)
    }

    /// Rebuild per-word timings in the current `mergedTranscript` by forced-aligning
    /// its chosen text against the source audio.
    ///
    /// Runs automatically after Deep Transcription if `settings.enableForcedAlignment`
    /// is on. Can also be invoked manually from UI. Failure is non-fatal; the
    /// original ASR-produced timings are preserved.
    func rebuildWordTimeline() async {
        guard !isAligningWordTimings else { return }
        guard let merged = mergedTranscript else {
            processLog.log("No merged transcript to align.", level: .warning)
            return
        }
        guard let audioURL = currentAudioURL else {
            processLog.log("Forced alignment skipped: audio file not found.", level: .warning)
            return
        }

        isAligningWordTimings = true
        wordAlignmentError = nil
        wordAlignmentProgress = "Loading forced-alignment model..."
        processLog.isVisible = true
        processLog.log("Forced alignment: rebuilding word timings from audio", level: .progress)

        let service = ForcedAlignmentServiceFactory.make(enabled: settings.enableForcedAlignment)
        processLog.log("Aligner: \(service.displayName)", level: .info)

        defer {
            isAligningWordTimings = false
            wordAlignmentProgress = ""
        }

        let accessing = audioURL.startAccessingSecurityScopedResource()
        defer {
            if accessing { audioURL.stopAccessingSecurityScopedResource() }
        }

        do {
            try await service.prepareModel(progressCallback: { [weak self] p in
                Task { @MainActor in
                    self?.wordAlignmentProgress = "Loading aligner model... \(Int(p * 100))%"
                }
            })

            wordAlignmentProgress = "Aligning words to audio..."

            // Build per-segment hints so the aligner can chunk. Single-shot
            // alignment on multi-minute audio fails hard (see Slice 4.5
            // AlignmentValidator findings against Clayton Everett: 1.6% match
            // rate single-shot vs. 72% match rate chunked). Each
            // MergedSegment becomes one hint; the service coalesces
            // consecutive hints up to its internal max chunk duration.
            let hints: [ForcedAlignmentHint] = merged.segments.compactMap { seg in
                let segText = seg.words.map(\.word).joined(separator: " ")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                guard !segText.isEmpty else { return nil }
                return ForcedAlignmentHint(
                    audioStart: seg.start,
                    audioEnd: seg.end,
                    text: segText
                )
            }

            guard !hints.isEmpty else {
                processLog.log("Forced alignment skipped: merged transcript has no text.", level: .warning)
                return
            }
            processLog.log("Aligning across \(hints.count) segments", level: .info)

            let alignedWords = try await service.alignSegments(
                audioURL: audioURL,
                hints: hints
            )

            wordAlignmentProgress = "Applying aligned timings..."
            let (updated, delta) = WordTimelineRebuilder.apply(
                to: merged,
                alignedWords: alignedWords,
                alignerLabel: service.displayName
            )

            // Re-attribute speakers and re-group segments using the refined timings.
            // This is what actually makes FA fix cross-speaker sentences: the original
            // attribution was computed using pre-FA noisy timestamps. Words whose
            // refined timestamps now fall on the other side of a speaker-turn
            // boundary need to be pulled into the correct segment.
            let finalMerged: MergedTranscript
            if let referencePass = reconciliationReferencePass {
                wordAlignmentProgress = "Re-attributing speakers to refined timings..."
                let reattributed = ConfidenceMergeService.reattributeAfterRetiming(
                    updated,
                    referenceSegments: referencePass.result.segments
                )
                let moved = Self.countWordsThatMovedSpeaker(before: updated, after: reattributed)
                if moved > 0 {
                    processLog.log(
                        "Re-attribution after FA: \(moved) word(s) moved to a different speaker based on refined timings",
                        level: .info
                    )
                }
                finalMerged = reattributed
            } else {
                // Fallback: no reference pass available (shouldn't happen in Deep Review
                // where FA runs, but guard against it). Use updated without re-attribution.
                finalMerged = updated
            }

            mergedTranscript = finalMerged
            lastWordAlignmentDelta = delta
            processLog.log("Forced alignment complete: \(delta.summaryLine)", level: .success)
        } catch ForcedAlignmentError.disabled {
            processLog.log("Forced alignment is disabled in Settings.", level: .info)
        } catch ForcedAlignmentError.notImplemented(let detail) {
            wordAlignmentError = detail
            processLog.log("Forced alignment not available: \(detail)", level: .warning)
        } catch {
            wordAlignmentError = error.localizedDescription
            processLog.log("Forced alignment failed: \(error.localizedDescription)", level: .warning)
        }

        await service.unload()
    }

    /// Run multi-threshold diarization on the finalized transcript, then use LLM
    /// to resolve disputes. This runs AFTER the transcript text is finalized (post-verification).
    /// Speaker names are automatically re-mapped from the original labeling.
    /// Run multi-pass diarization, collect ALL candidate speaker boundaries from every pass,
    /// then use the LLM to confirm which boundaries are real based on transcript context.
    /// This finds speaker changes that any single pass missed.
    func refineSpeakers() async {
        guard let url = currentAudioURL else {
            presentError(TranscriboError.transcriptionFailed("Audio file not found. Re-import to continue."))
            return
        }

        // Prefer the verified/merged text from Deep Transcription (Step 1) as the LLM context.
        // This gives the LLM the best possible transcript to reason about speaker changes.
        let currentResult: TranscriptionResult
        if let merged = mergedTranscript {
            let audioPath = currentAudioURL?.path(percentEncoded: false)
                ?? self.result?.audioPath ?? ""
            let duration = self.result?.duration ?? audioDuration
            currentResult = ConfidenceMergeService.buildConsensusResult(
                from: merged,
                audioPath: audioPath,
                audioDuration: duration
            )
            processLog.log("Using verified merged transcript for speaker analysis (\(currentResult.segments.count) segments)", level: .info)
        } else if let passResult = activePass?.result ?? result {
            currentResult = passResult
            processLog.log("Using standard transcript for speaker analysis", level: .info)
        } else {
            presentError(TranscriboError.transcriptionFailed("No transcript available to refine speakers."))
            return
        }

        let previousMapping = speakerMapping
        let previousSegments = currentResult.segments

        let accessing = url.startAccessingSecurityScopedResource()
        defer {
            if accessing { url.stopAccessingSecurityScopedResource() }
        }

        isCleanupRunning = true
        cleanupProgress = "Running multi-pass speaker detection..."
        cleanupError = nil
        processLog.isVisible = true

        do {
            let diarizationService = DiarizationService()

            processLog.log("Phase 1: Running multiple diarization passes to find all candidate speaker boundaries", level: .progress)

            // Run multi-engine diarization to get all passes
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

            // Step 2: Collect ALL speaker boundaries from every pass
            processLog.log("Phase 2: Collecting candidate speaker boundaries from all passes", level: .progress)

            // Get the baseline boundaries (from the primary/first pass)
            let baselineSegments = SegmentMerger.postProcessDiarization(multiResult.passes[0].segments)
            let baselineBoundaries = extractBoundaryTimes(from: baselineSegments)

            // Collect boundaries from ALL passes, tracking where each candidate originated
            // so we can apply origin-aware verification rules downstream (Phase 3b).
            var allBoundaryVotes: [TimeInterval: Int] = [:]
            var acousticOriginTimes: Set<TimeInterval> = []
            var conversationalOriginTimes: Set<TimeInterval> = []
            let totalPasses = multiResult.passes.count

            for pass in multiResult.passes {
                let cleaned = SegmentMerger.postProcessDiarization(pass.segments)
                let boundaries = extractBoundaryTimes(from: cleaned)
                for b in boundaries {
                    // Round to 0.5s to cluster nearby boundaries
                    let rounded = (b * 2).rounded() / 2
                    allBoundaryVotes[rounded, default: 0] += 1
                    acousticOriginTimes.insert(rounded)
                }
            }

            // Pool lexical / conversational-logic candidates alongside acoustic ones.
            // These catch back-channels, long pauses, direct name addresses, and intros
            // that acoustic embedding clustering consistently misses. The LLM confirmation
            // pass (Phase 3) then decides which candidates are real; acoustic verification
            // (Phase 3b) still runs, but conversational-only candidates are not vetoed by
            // it — acoustic is the known-failing channel for those patterns.
            let conversationalCandidates = ConversationalBoundaryService.proposeBoundaries(
                from: currentResult.segments
            )
            if !conversationalCandidates.isEmpty {
                var reasonCounts: [ConversationalBoundaryReason: Int] = [:]
                for candidate in conversationalCandidates {
                    let rounded = (candidate.time * 2).rounded() / 2
                    allBoundaryVotes[rounded, default: 0] += 1
                    conversationalOriginTimes.insert(rounded)
                    reasonCounts[candidate.reason, default: 0] += 1
                }
                let breakdown = reasonCounts
                    .sorted { $0.value > $1.value }
                    .map { "\($0.key.rawValue)=\($0.value)" }
                    .joined(separator: ", ")
                processLog.log(
                    "Added \(conversationalCandidates.count) conversational-logic candidates (\(breakdown))",
                    level: .info
                )
            }

            // Find boundaries that ANY pass detected but the baseline missed
            let candidateBoundaries = allBoundaryVotes.keys.sorted().compactMap { time -> TranscriptCleanupService.CandidateBoundary? in
                // Skip if the baseline already has a boundary within 2 seconds
                let nearBaseline = baselineBoundaries.contains { abs($0 - time) < 2.0 }
                if nearBaseline { return nil }

                let votes = allBoundaryVotes[time] ?? 0
                // At least 1 pass must have detected it
                guard votes >= 1 else { return nil }

                // Find the speakers on either side in the baseline
                let beforeSpeaker = speakerAtTime(time - 0.5, in: baselineSegments)
                let afterSpeaker = speakerAtTime(time + 0.5, in: baselineSegments)

                return TranscriptCleanupService.CandidateBoundary(
                    time: time,
                    beforeSpeaker: beforeSpeaker,
                    afterSpeaker: afterSpeaker,
                    detectedByCount: votes,
                    totalPasses: totalPasses
                )
            }

            let candidateAcousticCount = candidateBoundaries.filter {
                acousticOriginTimes.contains($0.time)
            }.count
            let candidateConversationalOnlyCount = candidateBoundaries.filter {
                conversationalOriginTimes.contains($0.time) && !acousticOriginTimes.contains($0.time)
            }.count
            processLog.log(
                "Found \(candidateBoundaries.count) candidate boundaries not in baseline " +
                "(\(candidateAcousticCount) with acoustic evidence, " +
                "\(candidateConversationalOnlyCount) lexical-only, " +
                "\(allBoundaryVotes.count) total across all passes)",
                level: .info
            )

            // Step 3: Use LLM to confirm boundaries
            // Track confirmed boundaries with their target speaker from the candidate data
            var confirmedBoundaries: [(time: TimeInterval, targetSpeaker: String?)] = []

            if !candidateBoundaries.isEmpty {
                cleanupProgress = "AI analyzing \(candidateBoundaries.count) candidate speaker changes..."
                processLog.log("Phase 3: Loading AI to confirm speaker boundaries from transcript context", level: .aiThinking)

                try await cleanupService.loadModel(selectedCleanupModel) { [weak self] progress in
                    Task { @MainActor in
                        if progress < 1.0 {
                            self?.cleanupProgress = "Loading AI model... \(Int(progress * 100))%"
                        }
                    }
                }

                processLog.setOutputLabel("AI Speaker Boundary Confirmation")
                processLog.clearOutput()

                // Process in batches of 20 to stay within token limits
                let batchSize = 20
                for batchStart in stride(from: 0, to: candidateBoundaries.count, by: batchSize) {
                    let batchEnd = min(batchStart + batchSize, candidateBoundaries.count)
                    let batch = Array(candidateBoundaries[batchStart..<batchEnd])

                    cleanupProgress = "AI confirming boundaries \(batchStart + 1)-\(batchEnd) of \(candidateBoundaries.count)..."

                    let confirmations = try await cleanupService.confirmSpeakerBoundaries(
                        candidates: batch,
                        transcriptionSegments: currentResult.segments,
                        speakerMapping: previousMapping
                    )

                    for (confIndex, confirmation) in confirmations.enumerated() where confirmation.isConfirmed {
                        // Carry the afterSpeaker from the candidate so insertBoundary knows who to assign
                        let candidate = batch[confIndex]
                        let target = candidate.afterSpeaker != candidate.beforeSpeaker ? candidate.afterSpeaker : nil
                        confirmedBoundaries.append((time: confirmation.time, targetSpeaker: target))
                    }

                    processLog.log("Batch \(batchStart / batchSize + 1): \(confirmations.filter(\.isConfirmed).count) confirmed out of \(batch.count)", level: .info)
                }

                processLog.log("AI confirmed \(confirmedBoundaries.count) candidate boundaries from text context", level: .success)

                // Phase 3b: Acoustic verification — re-diarize a focused clip around each
                // LLM-confirmed boundary to check if the audio actually has a speaker change there
                if !confirmedBoundaries.isEmpty {
                    cleanupProgress = "Verifying \(confirmedBoundaries.count) boundaries against audio..."
                    processLog.log("Phase 3b: Acoustic verification — running focused diarization on each candidate", level: .progress)

                    let speakerCount: Int? = (minSpeakers > 0 && maxSpeakers > 0 && maxSpeakers - minSpeakers <= 1) ? minSpeakers : nil
                    var verifiedBoundaries: [(time: TimeInterval, targetSpeaker: String?)] = []
                    var acousticallyConfirmedCount = 0
                    var lexicalBypassCount = 0
                    var droppedCount = 0

                    for (idx, boundary) in confirmedBoundaries.sorted(by: { $0.time < $1.time }).enumerated() {
                        cleanupProgress = "Verifying boundary \(idx + 1) of \(confirmedBoundaries.count) at \(TimeFormatting.timestamp(boundary.time))..."

                        // Origin-aware verification: if a candidate was proposed only by
                        // conversational logic (no acoustic pass voted for it), acoustic
                        // verification is the known-failing channel for that pattern, so
                        // we don't let it veto a decision from two agreeing non-acoustic
                        // signals (lexical proposer + LLM confirmation).
                        let roundedTime = (boundary.time * 2).rounded() / 2
                        let isLexicalOnly = conversationalOriginTimes.contains(roundedTime)
                            && !acousticOriginTimes.contains(roundedTime)

                        do {
                            let verified = try await diarizationService.verifyBoundary(
                                audioURL: url,
                                candidateTime: boundary.time,
                                contextWindow: 30,
                                numberOfSpeakers: speakerCount
                            )

                            if verified {
                                verifiedBoundaries.append(boundary)
                                acousticallyConfirmedCount += 1
                                processLog.log("  Boundary at \(TimeFormatting.timestamp(boundary.time)): CONFIRMED by audio", level: .success)
                            } else if isLexicalOnly {
                                // Lexical + LLM agree, acoustic can't verify (expected on
                                // short back-channels, similar-voiced speakers). Apply it.
                                verifiedBoundaries.append(boundary)
                                lexicalBypassCount += 1
                                processLog.log("  Boundary at \(TimeFormatting.timestamp(boundary.time)): applied from lexical+LLM (acoustic couldn't verify)", level: .info)
                            } else {
                                droppedCount += 1
                                processLog.log("  Boundary at \(TimeFormatting.timestamp(boundary.time)): dropped (acoustic disagrees with LLM)", level: .info)
                            }
                        } catch {
                            // If focused diarization fails, trust the LLM
                            verifiedBoundaries.append(boundary)
                            lexicalBypassCount += 1
                            processLog.log("  Boundary at \(TimeFormatting.timestamp(boundary.time)): verification failed, trusting LLM", level: .warning)
                        }
                    }

                    processLog.log(
                        "Verification: \(acousticallyConfirmedCount) acoustically confirmed, " +
                        "\(lexicalBypassCount) via lexical+LLM bypass, \(droppedCount) dropped",
                        level: .success
                    )

                    confirmedBoundaries = verifiedBoundaries
                }
            } else {
                processLog.log("No new candidate boundaries found beyond baseline", level: .info)
            }

            // Step 4: Apply confirmed boundaries to the transcript
            cleanupProgress = "Applying refined speaker assignments..."
            processLog.log("Phase 4: Applying \(confirmedBoundaries.count) new boundaries + baseline diarization", level: .progress)

            // Start with the baseline diarization
            var finalDiarization = baselineSegments

            // Insert confirmed boundaries with their target speakers
            for boundary in confirmedBoundaries.sorted(by: { $0.time < $1.time }) {
                finalDiarization = insertBoundary(at: boundary.time, targetSpeaker: boundary.targetSpeaker, in: finalDiarization)
            }

            // Merge with transcript. When Diagnostic Mode is on, pass a closure that
            // forwards every smoother reassignment into the process log so the user
            // can review exactly what the smoother changed and why.
            let diagnosticCallback: ((String) -> Void)? = settings.diagnosticModeEnabled
                ? { [weak self] message in
                    Task { @MainActor in self?.processLog.log(message, level: .info) }
                }
                : nil
            let updatedSegments = SegmentMerger.merge(
                transcriptionSegments: currentResult.segments,
                diarizationSegments: finalDiarization,
                diagnostic: diagnosticCallback
            )

            let updatedResult = TranscriptionResult(
                audioPath: currentResult.audioPath,
                duration: currentResult.duration,
                segments: updatedSegments
            )

            // Re-map speaker names
            let newMapping = remapSpeakerNames(
                previousSegments: previousSegments,
                previousMapping: previousMapping,
                newSegments: updatedSegments
            )
            speakerMapping = newMapping
            result = updatedResult
            speakerSamples = extractSpeakerSamples(from: updatedResult)

            // Save
            if var project = currentProject {
                let pass = TranscriptionPass(
                    kind: .deepReviewPrimary,
                    engineName: activePass?.engineName ?? "WhisperKit",
                    modelName: activePass?.modelName ?? "Refined",
                    diarizationEngineName: "Multi-Pass + LLM Boundary Confirmation",
                    language: language,
                    minSpeakers: minSpeakers > 0 ? minSpeakers : nil,
                    maxSpeakers: maxSpeakers > 0 ? maxSpeakers : nil,
                    sourcePassID: activePass?.id,
                    warnings: confirmedBoundaries.isEmpty
                        ? []
                        : ["Refined: \(confirmedBoundaries.count) speaker boundaries confirmed by AI from \(candidateBoundaries.count) candidates across \(multiResult.passes.count) passes."],
                    result: updatedResult,
                    qualitySummary: QualityAnalysisService.analyze(result: updatedResult)
                )

                project.appendPass(pass)
                project.speakerMapping = newMapping
                currentProject = project
                synchronizeFromActivePass()
                await persistCurrentProject()
            }

            let summary = "Speaker refinement complete. \(confirmedBoundaries.count) new boundaries confirmed from \(candidateBoundaries.count) candidates."
            cleanupProgress = summary
            processLog.log(summary, level: .success)
            deepReviewCompletedSteps.insert("diarization")
            isCleanupRunning = false

        } catch {
            cleanupError = "Speaker refinement failed: \(error.localizedDescription)"
            cleanupProgress = ""
            processLog.log("Speaker refinement failed: \(error.localizedDescription)", level: .error)
            isCleanupRunning = false
        }
    }

    // MARK: - Speaker Boundary Helpers

    /// Extract the time of each speaker change from a sorted list of diarization segments.
    private func extractBoundaryTimes(from segments: [DiarizationSegment]) -> [TimeInterval] {
        var boundaries: [TimeInterval] = []
        for i in 1..<segments.count {
            if segments[i].speakerID != segments[i - 1].speakerID {
                boundaries.append(segments[i].start)
            }
        }
        return boundaries
    }

    /// Find which speaker is active at a given time in a sorted diarization segment list.
    private func speakerAtTime(_ time: TimeInterval, in segments: [DiarizationSegment]) -> String {
        for seg in segments {
            if time >= seg.start && time <= seg.end {
                return seg.speakerID
            }
        }
        // Find nearest
        return segments.min(by: {
            abs(($0.start + $0.end) / 2 - time) < abs(($1.start + $1.end) / 2 - time)
        })?.speakerID ?? "UNKNOWN"
    }

    /// Insert a speaker boundary at the given time by splitting an existing segment.
    /// Uses `targetSpeaker` when provided (from multi-pass candidate detection);
    /// otherwise infers the speaker from the next segment or nearby context.
    private func insertBoundary(
        at time: TimeInterval,
        targetSpeaker: String?,
        in segments: [DiarizationSegment]
    ) -> [DiarizationSegment] {
        var result = segments
        guard let splitIndex = result.firstIndex(where: { $0.start <= time && $0.end > time }) else {
            return result
        }

        let original = result[splitIndex]

        // Determine who speaks after the boundary:
        // 1. Use the explicitly provided target speaker (from CandidateBoundary.afterSpeaker)
        // 2. Look at the next segment in the diarization timeline
        // 3. Find the nearest different speaker within ±5 seconds
        // 4. Fall back to the current speaker (no change)
        let newSpeaker: String
        if let target = targetSpeaker, target != original.speakerID, target != "UNKNOWN" {
            newSpeaker = target
        } else if splitIndex + 1 < result.count, result[splitIndex + 1].speakerID != original.speakerID {
            newSpeaker = result[splitIndex + 1].speakerID
        } else {
            // Search nearby segments for a different speaker
            let nearbyWindow: TimeInterval = 5.0
            let nearby = segments.filter {
                $0.speakerID != original.speakerID &&
                $0.speakerID != "UNKNOWN" &&
                abs($0.start - time) < nearbyWindow
            }
            newSpeaker = nearby.min(by: { abs($0.start - time) < abs($1.start - time) })?.speakerID
                ?? original.speakerID
        }

        let before = DiarizationSegment(
            speakerID: original.speakerID,
            start: original.start,
            end: time,
            qualityScore: original.qualityScore
        )

        let after = DiarizationSegment(
            speakerID: newSpeaker,
            start: time,
            end: original.end,
            qualityScore: original.qualityScore * 0.9
        )

        result.replaceSubrange(splitIndex...splitIndex, with: [before, after])
        return result
    }

    /// Re-map speaker names from a previous labeling to new speaker IDs by matching
    /// which new speaker covers the most time that was previously labeled as each named speaker.
    private func remapSpeakerNames(
        previousSegments: [TranscriptionSegment],
        previousMapping: SpeakerMapping,
        newSegments: [TranscriptionSegment]
    ) -> SpeakerMapping {
        // Build time-weighted speaker overlap between old and new IDs
        var overlapMatrix: [String: [String: TimeInterval]] = [:] // [newID: [oldID: overlap]]

        for newSeg in newSegments {
            let newMid = (newSeg.start + newSeg.end) / 2
            // Find the old segment closest in time
            if let oldSeg = previousSegments.min(by: {
                abs(($0.start + $0.end) / 2 - newMid) < abs(($1.start + $1.end) / 2 - newMid)
            }) {
                let overlap = max(0, min(newSeg.end, oldSeg.end) - max(newSeg.start, oldSeg.start))
                if overlap > 0 {
                    overlapMatrix[newSeg.speakerID, default: [:]][oldSeg.speakerID, default: 0] += overlap
                }
            }
        }

        // For each new speaker, find the old speaker with the most overlap
        var newMapping = SpeakerMapping()
        var usedOldSpeakers = Set<String>()

        // Sort new speakers by total duration (most prominent first) for stable assignment
        let newSpeakersByDuration = overlapMatrix.sorted { lhs, rhs in
            lhs.value.values.reduce(0, +) > rhs.value.values.reduce(0, +)
        }

        for (newID, oldOverlaps) in newSpeakersByDuration {
            // Find the best-matching old speaker that hasn't been claimed yet
            let bestOld = oldOverlaps
                .filter { !usedOldSpeakers.contains($0.key) }
                .max(by: { $0.value < $1.value })

            if let (oldID, _) = bestOld, let name = previousMapping.names[oldID] {
                newMapping.rename(newID, to: name)
                usedOldSpeakers.insert(oldID)
            }
        }

        return newMapping
    }

    func openReconciliation() {
        guard let referencePass = reconciliationReferencePass,
              let candidatePass = reconciliationCandidatePass else {
            presentError(TranscriboError.transcriptionFailed("Run a standard pass and a Deep Review comparison pass before opening reconciliation."))
            return
        }

        // Use the new confidence-weighted merge engine
        let merged = ConfidenceMergeService.buildMergedTranscript(
            referencePass: referencePass,
            candidatePass: candidatePass,
            applyConfidenceMerge: settings.useConfidenceMerge
        )
        mergedTranscript = merged

        // Select first unresolved flag for keyboard navigation
        selectedMergeFlagID = merged.flags.first(where: { !$0.isResolved })?.id
        playingMergeFlagID = nil
        reconciliationStatusMessage = nil
        currentPhase = .deepReviewCompare

        let flagCount = merged.totalFlagCount
        if flagCount > 0 {
            reconciliationStatusMessage = "\(flagCount) regions flagged for review. Use keyboard shortcuts to navigate."
        } else {
            reconciliationStatusMessage = "Engines agree on the full transcript. Ready to save."
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

    /// Run LLM cleanup on the transcript text: fix repeated words, punctuation,
    /// number formatting, and filler word runs. Does NOT change speaker assignments.
    /// Used as part of Deep Review Step 1 after the transcription merge.
    func runDeepCleanup() async {
        guard let result else { return }
        isCleanupRunning = true
        cleanupProgress = "Loading AI model for transcript cleanup..."
        processLog.log("Starting transcript cleanup pass...", level: .aiThinking)

        do {
            try await cleanupService.loadModel(selectedCleanupModel) { [weak self] progress in
                Task { @MainActor in
                    if progress < 1.0 {
                        self?.cleanupProgress = "Downloading model... \(Int(progress * 100))%"
                    }
                }
            }

            let transcriptText = TranscriptCleanupService.formatForCleanup(
                result: result,
                speakerMapping: speakerMapping
            )

            cleanupProgress = "AI cleaning up transcript..."
            processLog.setOutputLabel("Cleanup Output")
            processLog.clearOutput()

            let cleaned = try await cleanupService.process(
                transcript: transcriptText,
                task: .cleanup,
                tokenCallback: { [weak self] chunk in
                    Task { @MainActor in
                        self?.processLog.appendOutput(chunk)
                    }
                }
            )

            // Apply cleaned text back to transcript segments by matching speaker labels
            applyCleanedText(cleaned)

            cleanupProgress = "Transcript cleanup complete."
            processLog.log("Cleanup complete: \(cleaned.count) characters", level: .success)
            isCleanupRunning = false
        } catch {
            cleanupProgress = ""
            processLog.log("Cleanup failed: \(error.localizedDescription)", level: .error)
            isCleanupRunning = false
        }
    }

    /// Parse cleaned text (with speaker labels) and apply it back to transcript segments.
    ///
    /// The LLM frequently merges multiple short same-speaker segments into one larger
    /// block. The prior implementation wrote each block to the first matching segment
    /// and left the subsequent same-speaker segments untouched — producing duplicated
    /// text when the LLM's single block covered what used to be three original
    /// segments (the new text in segment 0, the original text lingering in segments 1
    /// and 2).
    ///
    /// This implementation REBUILDS the segment list from the LLM blocks: for each
    /// block, consumes the contiguous run of same-speaker original segments, coalesces
    /// their time ranges, and emits one new segment with the block's text. Original
    /// segments that don't match any block (LLM dropped a speaker or mis-labeled it)
    /// are passed through unchanged, so nothing gets lost silently.
    ///
    /// Before rewriting, captures a snapshot of the current segments on
    /// `polishUndoSnapshot` so the user can undo if the result looks wrong.
    private func applyCleanedText(_ cleanedText: String) {
        guard var project = currentProject,
              let passIndex = project.passes.firstIndex(where: { $0.id == project.activePassID }) else {
            return
        }

        // Snapshot for undo
        polishUndoSnapshot = PolishUndoSnapshot(
            passID: project.passes[passIndex].id,
            segments: project.passes[passIndex].result.segments,
            speakerMapping: speakerMapping,
            capturedAt: Date()
        )

        let blocks = parsePolishBlocks(cleanedText)
        guard !blocks.isEmpty else {
            processLog.log("Polish: no speaker-labeled blocks parsed from output — skipping apply to avoid corruption.", level: .warning)
            polishUndoSnapshot = nil
            return
        }

        let original = project.passes[passIndex].result.segments
        var rebuilt: [TranscriptionSegment] = []
        rebuilt.reserveCapacity(max(blocks.count, original.count))

        var segCursor = 0
        for block in blocks {
            // Find the contiguous run of same-speaker segments starting at segCursor
            // whose displayName matches the block's speaker.
            var runEnd = segCursor
            while runEnd < original.count,
                  speakerBlockMatchesSegment(block: block, segment: original[runEnd]) {
                runEnd += 1
            }

            if runEnd == segCursor {
                // No match at current cursor. Skip forward past any unmatched segments
                // until we find one that matches this block (LLM may have reordered or
                // dropped something). If we never find a match, emit the block as a
                // new segment with a best-guess time range and move on.
                let searchIndex = original[segCursor...].firstIndex { seg in
                    speakerBlockMatchesSegment(block: block, segment: seg)
                }
                if let found = searchIndex {
                    // Pass through any unmatched segments between segCursor and found
                    for passThrough in original[segCursor..<found] {
                        rebuilt.append(passThrough)
                    }
                    segCursor = found
                    runEnd = found
                    while runEnd < original.count,
                          speakerBlockMatchesSegment(block: block, segment: original[runEnd]) {
                        runEnd += 1
                    }
                } else {
                    // No matching segment anywhere downstream. Skip this block.
                    continue
                }
            }

            let runSegments = Array(original[segCursor..<runEnd])
            if runSegments.isEmpty { continue }

            // Coalesce the run's time range + metadata; replace text with block.
            let first = runSegments[0]
            let last = runSegments[runSegments.count - 1]
            rebuilt.append(TranscriptionSegment(
                id: first.id,
                speakerID: first.speakerID,
                start: first.start,
                end: last.end,
                text: block.text,
                // Drop word-level timings: the LLM rewrote the text so the old
                // per-word timestamps no longer align. Consumers that need word-level
                // timing (subtitle export) should run before Polish, not after.
                words: nil,
                averageLogProb: first.averageLogProb,
                noSpeechProb: first.noSpeechProb,
                decodingTemperature: first.decodingTemperature,
                compressionRatio: first.compressionRatio,
                diarizationQuality: first.diarizationQuality,
                diarizationOverlap: first.diarizationOverlap
            ))
            segCursor = runEnd
        }

        // Pass-through any trailing original segments the LLM didn't touch.
        if segCursor < original.count {
            for passThrough in original[segCursor..<original.count] {
                rebuilt.append(passThrough)
            }
        }

        project.passes[passIndex].result.segments = rebuilt
        currentProject = project
        result = project.passes[passIndex].result
        Task { await persistCurrentProject() }
    }

    /// A parsed speaker-labeled block from LLM Polish output.
    private struct PolishBlock {
        let speaker: String
        let text: String
    }

    /// Parse Polish output into (speaker, text) blocks. Speaker labels are ALL-CAPS
    /// lines ending in a colon, e.g. `BRANT KUEHN:`.
    private func parsePolishBlocks(_ cleanedText: String) -> [PolishBlock] {
        let lines = cleanedText.components(separatedBy: "\n")
        var currentSpeaker: String?
        var currentText = ""
        var blocks: [PolishBlock] = []

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { continue }

            let isSpeakerLabel = trimmed.hasSuffix(":") && trimmed.dropLast().allSatisfy {
                $0.isUppercase || $0.isWhitespace || $0 == "_"
            }

            if isSpeakerLabel {
                if let speaker = currentSpeaker, !currentText.isEmpty {
                    blocks.append(PolishBlock(
                        speaker: speaker,
                        text: currentText.trimmingCharacters(in: .whitespacesAndNewlines)
                    ))
                }
                currentSpeaker = String(trimmed.dropLast()).trimmingCharacters(in: .whitespaces)
                currentText = ""
            } else {
                currentText += (currentText.isEmpty ? "" : " ") + trimmed
            }
        }
        if let speaker = currentSpeaker, !currentText.isEmpty {
            blocks.append(PolishBlock(
                speaker: speaker,
                text: currentText.trimmingCharacters(in: .whitespacesAndNewlines)
            ))
        }
        return blocks
    }

    /// Check whether a Polish block's speaker label matches a segment. Compares both
    /// the display name (what the LLM was shown) and the raw SPEAKER_N ID.
    private func speakerBlockMatchesSegment(
        block: PolishBlock,
        segment: TranscriptionSegment
    ) -> Bool {
        let displayName = speakerMapping.displayName(for: segment.speakerID).uppercased()
        return block.speaker == displayName || block.speaker == segment.speakerID
    }

    /// Apply segments produced by the Manual Transcript Editor to the active pass.
    /// Snapshots the prior state on `manualEditUndoSnapshot` so the user can undo.
    /// Also refreshes the speaker mapping with any new display names the editor
    /// introduced (e.g. the user typed a real name where there was a SPEAKER_N).
    func applyManualEdits(segments: [TranscriptionSegment]) {
        guard var project = currentProject,
              let passIndex = project.passes.firstIndex(where: { $0.id == project.activePassID }) else {
            return
        }

        manualEditUndoSnapshot = PolishUndoSnapshot(
            passID: project.passes[passIndex].id,
            segments: project.passes[passIndex].result.segments,
            speakerMapping: speakerMapping,
            capturedAt: Date()
        )

        // Any MANUAL_<NAME> IDs the editor produced mean the user named a speaker
        // that wasn't in the mapping. Promote each to its own speakerID and add to
        // the mapping so the rest of the app treats them consistently.
        var updatedMapping = speakerMapping
        var resolvedSegments: [TranscriptionSegment] = []
        resolvedSegments.reserveCapacity(segments.count)
        for segment in segments {
            if segment.speakerID.hasPrefix("MANUAL_") {
                let displayName = String(segment.speakerID.dropFirst("MANUAL_".count))
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                // Reuse an existing speakerID if the display name matches a known one
                let existing = updatedMapping.names.first { $0.value.uppercased() == displayName }?.key
                let assignID = existing ?? Self.nextManualSpeakerID(existing: updatedMapping)
                if existing == nil {
                    updatedMapping.names[assignID] = displayName.capitalized
                }
                var copy = segment
                copy.speakerID = assignID
                resolvedSegments.append(copy)
            } else {
                resolvedSegments.append(segment)
            }
        }

        project.passes[passIndex].result.segments = resolvedSegments
        project.speakerMapping = updatedMapping
        project.updatedAt = Date()
        currentProject = project
        result = project.passes[passIndex].result
        speakerMapping = updatedMapping
        processLog.log("Manual edits applied: \(segments.count) segment(s) rewritten from the editor.", level: .success)
        Task { await persistCurrentProject() }
    }

    /// Undo the most recent manual edit by restoring the snapshot.
    func undoManualEdits() {
        guard let snapshot = manualEditUndoSnapshot,
              var project = currentProject,
              let passIndex = project.passes.firstIndex(where: { $0.id == snapshot.passID }) else {
            return
        }
        project.passes[passIndex].result.segments = snapshot.segments
        project.speakerMapping = snapshot.speakerMapping
        speakerMapping = snapshot.speakerMapping
        currentProject = project
        result = project.passes[passIndex].result
        manualEditUndoSnapshot = nil
        processLog.log("Manual edits undone — transcript restored.", level: .info)
        Task { await persistCurrentProject() }
    }

    /// Produce a speakerID for a newly-named speaker introduced via the manual
    /// editor. Uses the next available `SPEAKER_N` slot that isn't already in use.
    private static func nextManualSpeakerID(existing mapping: SpeakerMapping) -> String {
        var n = 0
        let used = Set(mapping.names.keys)
        while used.contains("SPEAKER_\(n)") {
            n += 1
        }
        return "SPEAKER_\(n)"
    }

    /// Restore the segment state captured before the most recent Polish pass. Clears
    /// the undo snapshot after restoration.
    func undoPolish() {
        guard let snapshot = polishUndoSnapshot,
              var project = currentProject,
              let passIndex = project.passes.firstIndex(where: { $0.id == snapshot.passID }) else {
            return
        }
        project.passes[passIndex].result.segments = snapshot.segments
        speakerMapping = snapshot.speakerMapping
        project.speakerMapping = snapshot.speakerMapping
        currentProject = project
        result = project.passes[passIndex].result
        polishUndoSnapshot = nil
        cleanupResult = nil
        cleanupError = nil
        processLog.log("Polish undone — transcript restored to pre-Polish state.", level: .info)
        Task { await persistCurrentProject() }
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

    /// Apply the most recent `cleanupResult` produced by `runCleanup()` back
    /// to the active transcript pass. Used by PolishView's "Apply to Transcript"
    /// button. For cleanup+summarize output, strips everything after a
    /// "SUMMARY" heading so only the cleaned transcript is applied.
    ///
    /// No-op if `cleanupResult` is nil/empty or if the current task was
    /// `.summarize` (pure summary output has no speaker labels to match).
    func applyPolishResult() {
        guard let raw = cleanupResult, !raw.isEmpty else { return }
        guard cleanupTask != .summarize else {
            processLog.log("Polish result is summary-only; nothing to apply to transcript.", level: .warning)
            return
        }

        // For cleanup+summarize, drop the trailing SUMMARY section if present.
        var cleaned = raw
        if cleanupTask == .cleanupAndSummarize {
            // Match an optional leading blank line, optional markdown/decoration
            // prefixes, then the SUMMARY heading on its own line.
            if let range = cleaned.range(
                of: #"\n[ \t#*]*SUMMARY[ \t:]*\n"#,
                options: [.regularExpression, .caseInsensitive]
            ) {
                cleaned = String(cleaned[..<range.lowerBound])
            }
        }

        applyCleanedText(cleaned)
        processLog.log("Applied polished transcript to active pass (\(cleaned.count) chars)", level: .success)
    }

    /// Summary-only convenience — forces the summarize task and stores result separately.
    var summaryResult: String?
    var isSummaryRunning: Bool = false
    var summaryProgress: String = ""
    var summaryError: String?
    var showSummarySidepane: Bool = false

    /// Load any persisted summary from the project into the sidepane.
    func loadPersistedSummary() {
        if let saved = currentProject?.detailedSummary, !saved.isEmpty {
            summaryResult = saved
        }
    }

    /// Save the current summary text back to the project.
    func persistSummary() async {
        guard var project = currentProject, let text = summaryResult, !text.isEmpty else { return }
        project.detailedSummary = text
        currentProject = project
        await persistCurrentProject()
    }

    /// Generate a brief 1-2 sentence project summary and store it in project metadata.
    /// Used for project cards in the dashboard.
    func generateProjectSummary() async {
        guard let result else { return }

        do {
            try await cleanupService.loadModel(selectedCleanupModel) { _ in }

            let transcript = TranscriptCleanupService.formatForCleanup(
                result: result,
                speakerMapping: speakerMapping
            )

            // Only send the first ~2000 chars to keep it fast
            let excerpt = String(transcript.prefix(2000))

            let summary = try await cleanupService.process(
                transcript: "Summarize this transcript in exactly 1-2 sentences. Include speaker names if visible. Be specific about the topic. Return ONLY the summary.\n\n\(excerpt)",
                task: .summarize
            )

            let cleaned = summary
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .components(separatedBy: "\n")
                .first ?? summary.trimmingCharacters(in: .whitespacesAndNewlines)

            if !cleaned.isEmpty, var project = currentProject {
                project.projectSummary = String(cleaned.prefix(300))
                currentProject = project
                await persistCurrentProject()
                await refreshProjectLibrary()
            }
        } catch {
            processLog.log("Auto-summary generation failed: \(error.localizedDescription)", level: .warning)
        }
    }

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
            await persistSummary()
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

    /// Add a proper noun correction to the project dictionary and apply it to the transcript.
    func addProperNounCorrection(misspelling: String, correct: String) {
        guard var project = currentProject else { return }

        var dict = project.properNounDictionary ?? [:]
        dict[misspelling] = correct
        project.properNounDictionary = dict
        currentProject = project

        // Apply the correction to all segments in the active pass
        applyProperNounCorrections()

        Task { await persistCurrentProject() }
    }

    /// Apply all proper noun corrections from the dictionary to the active transcript.
    func applyProperNounCorrections() {
        guard let dictionary = currentProject?.properNounDictionary, !dictionary.isEmpty,
              var project = currentProject,
              let passIndex = project.passes.firstIndex(where: { $0.id == project.activePassID }) else {
            return
        }

        for (segIndex, segment) in project.passes[passIndex].result.segments.enumerated() {
            var text = segment.text
            for (misspelling, correct) in dictionary {
                text = text.replacingOccurrences(
                    of: "\\b\(NSRegularExpression.escapedPattern(for: misspelling))\\b",
                    with: correct,
                    options: [.regularExpression, .caseInsensitive]
                )
            }
            if text != segment.text {
                project.passes[passIndex].result.segments[segIndex].text = text
            }
        }

        currentProject = project
        result = project.passes[passIndex].result
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
        playingMergeFlagID = nil
    }

    // MARK: - Confidence-Weighted Merge Methods

    func selectMergeFlag(id: UUID) {
        selectedMergeFlagID = id
    }

    /// Preview a resolution choice without confirming — updates the displayed text
    /// and highlights the selection, but doesn't mark the flag as resolved.
    func previewFlagResolution(id: UUID, resolution: MergeFlagResolution) {
        guard var merged = mergedTranscript,
              let flagIndex = merged.flags.firstIndex(where: { $0.id == id }) else {
            return
        }

        merged.flags[flagIndex].resolution = resolution

        // Update the merged text to preview the choice
        switch resolution {
        case .useReference:
            merged.flags[flagIndex].mergedText = merged.flags[flagIndex].referenceText
        case .useCandidate:
            merged.flags[flagIndex].mergedText = merged.flags[flagIndex].candidateText
        case .manual(let text):
            merged.flags[flagIndex].mergedText = text
        case .merged, .speakerOverride:
            break
        }

        merged.updatedAt = Date()
        mergedTranscript = merged
    }

    /// Confirm the current resolution choice — marks the flag as resolved and
    /// auto-advances to the next unresolved flag.
    func confirmMergeFlag(id: UUID) {
        guard var merged = mergedTranscript,
              let flagIndex = merged.flags.firstIndex(where: { $0.id == id }) else {
            return
        }

        merged.flags[flagIndex].isResolved = true
        merged.updatedAt = Date()
        mergedTranscript = merged

        let remaining = merged.unresolvedFlagCount
        if remaining == 0 {
            reconciliationStatusMessage = "All flags resolved. Ready to save consensus."
            selectedMergeFlagID = nil
        } else {
            reconciliationStatusMessage = "\(remaining) flag\(remaining == 1 ? "" : "s") remaining."

            // Auto-advance to the next unresolved flag
            let currentIndex = merged.flags.firstIndex(where: { $0.id == id }) ?? -1
            if let next = merged.flags.dropFirst(currentIndex + 1).first(where: { !$0.isResolved }) {
                selectedMergeFlagID = next.id
            } else if let first = merged.flags.first(where: { !$0.isResolved }) {
                selectedMergeFlagID = first.id
            }
        }
    }

    func playMergeFlagContext(for flagID: UUID) {
        guard let merged = mergedTranscript,
              let flag = merged.flags.first(where: { $0.id == flagID }),
              let url = currentAudioURL else {
            return
        }

        let clipStart = max(0, flag.start - 3)
        let maxDuration = audioDuration > 0 ? audioDuration : (result?.duration ?? flag.end + 3)
        let clipEnd = min(maxDuration, flag.end + 3)

        playingMergeFlagID = flagID
        audioContextPlayer.play(url: url, from: clipStart, to: clipEnd) { [weak self] in
            self?.playingMergeFlagID = nil
        }
    }

    func saveMergedConsensus() async {
        guard var project = currentProject else { return }

        // Safety: if no merge happened, ensure we're on the best diarized pass (never the comparison)
        guard let merged = mergedTranscript else {
            // No merge — switch to the best diarized pass and save
            let bestPass = project.passes.last(where: { $0.kind == .deepReviewPrimary })
                ?? project.passes.first(where: { $0.kind == .standard })
            if let bestPass {
                project.setActivePass(id: bestPass.id)
                currentProject = project
                synchronizeFromActivePass()
                await persistCurrentProject()
            }
            return
        }

        let audioPath = currentAudioURL?.path(percentEncoded: false)
            ?? currentProject?.sourceAudioPath
            ?? result?.audioPath

        guard let audioPath else {
            presentError(TranscriboError.transcriptionFailed("Could not determine audio file path for consensus save."))
            return
        }

        let duration = currentProject?.audioDuration ?? result?.duration ?? audioDuration
        let consensusResult = ConfidenceMergeService.buildConsensusResult(
            from: merged,
            audioPath: audioPath,
            audioDuration: duration
        )

        let existingConsensusPass = latestConsensusPass
        let consensusPass = TranscriptionPass(
            id: existingConsensusPass?.id ?? UUID(),
            kind: .deepReviewConsensus,
            createdAt: existingConsensusPass?.createdAt ?? Date(),
            engineName: "Confidence Merge",
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
        reconciliationStatusMessage = "Consensus saved."

        synchronizeFromActivePass()
        await persistCurrentProject()
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
            let pdfOptions = buildLegalPDFOptions()
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
            let pdfOptions = buildLegalPDFOptions()
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
        url: URL
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
        mergedTranscript = nil
        selectedMergeFlagID = nil
        playingMergeFlagID = nil
        selectedFormats = [.legalPDF]
        showElapsedTime = true
        showClockTime = false
        recordingStartTime = Self.recordingStartTime(for: url, duration: info.duration)
        legalPDFHeader = Self.defaultLegalPDFHeader(fileName: info.fileName, recordingStartTime: recordingStartTime)
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
        includeQualityTierBadge = project.exportPreferences.includeQualityTierBadge
        highlightLowConfidence = project.exportPreferences.highlightLowConfidence
        let storedRecordingStartTime = project.exportPreferences.recordingStartTime
        let resolvedRecordingStartTime = Self.recordingStartTime(
            for: audioFileURL,
            duration: project.audioDuration,
            fallbackStartTime: storedRecordingStartTime
        )
        recordingStartTime = resolvedRecordingStartTime

        let storedHeader = project.exportPreferences.legalPDFHeader
        let usesDefaultHeader = storedHeader == Self.defaultLegalPDFHeader(
            fileName: project.audioFileName,
            recordingStartTime: storedRecordingStartTime
        )
        legalPDFHeader = usesDefaultHeader
            ? Self.defaultLegalPDFHeader(
                fileName: project.audioFileName,
                recordingStartTime: resolvedRecordingStartTime
            )
            : storedHeader
        reconciliationDraft = nil
        reconciliationSelectedRowID = nil
        reconciliationPlayingRowID = nil
        reconciliationStatusMessage = nil
        mergedTranscript = nil
        selectedMergeFlagID = nil
        playingMergeFlagID = nil

        if var currentProject {
            currentProject.exportPreferences.recordingStartTime = resolvedRecordingStartTime
            if usesDefaultHeader {
                currentProject.exportPreferences.legalPDFHeader = legalPDFHeader
            }
            self.currentProject = currentProject
        }

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
        resetSpeakerMapping: Bool,
        sourcePassID: UUID? = nil
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
            sourcePassID: sourcePassID,
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

    func buildLegalPDFOptions() -> LegalPDFOptions {
        // Parse summary into sections for cover page
        let summaryText = summaryResult ?? currentProject?.detailedSummary
        var coverSummary: String?
        var coverActions: String?

        if let text = summaryText, !text.isEmpty {
            let lines = text.components(separatedBy: "\n")
            var actionLines: [String] = []
            var summaryLines: [String] = []
            var section = "summary"

            for line in lines {
                let upper = line.uppercased().trimmingCharacters(in: .whitespaces)
                if upper.contains("ACTION ITEM") || upper.contains("DELIVERABLE") || upper.contains("TO-DO") || upper.contains("TODO") {
                    section = "actions"
                    continue
                } else if upper.contains("KEY POINT") || upper.contains("SUMMARY") {
                    section = "summary"
                    continue
                }
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                guard !trimmed.isEmpty else { continue }
                if section == "actions" { actionLines.append(trimmed) }
                else { summaryLines.append(trimmed) }
            }

            coverSummary = summaryLines.isEmpty ? text : summaryLines.joined(separator: "\n")
            coverActions = actionLines.isEmpty ? nil : actionLines.joined(separator: "\n")
        }

        return LegalPDFOptions(
            showElapsedTime: showElapsedTime,
            showClockTime: showClockTime,
            recordingStartTime: recordingStartTime,
            headerText: legalPDFHeader,
            includeCoverPage: includeCoverPage,
            coverPageSummary: coverPageIncludeSummary ? coverSummary : nil,
            coverPageActionItems: coverPageIncludeActionItems ? coverActions : nil,
            audioFileName: currentProject?.audioFileName,
            audioDuration: currentProject?.audioDuration,
            speakerNames: speakerMapping.names.values.sorted()
        )
    }

    private func currentExportPreferences() -> ProjectExportPreferences {
        ProjectExportPreferences(
            selectedFormats: selectedFormats.sorted { $0.rawValue < $1.rawValue },
            showElapsedTime: showElapsedTime,
            showClockTime: showClockTime,
            recordingStartTime: recordingStartTime,
            legalPDFHeader: legalPDFHeader,
            includeQualityTierBadge: includeQualityTierBadge,
            highlightLowConfidence: highlightLowConfidence
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
            let sentenceScopedWords = trimmedWords(
                from: baseSegments,
                start: row.start,
                end: row.end
            )
            let expectedSourceText = consensusSourceText(for: row)
            let keepWordTimings =
                normalizeComparisonText(expectedSourceText) == normalizeComparisonText(finalText)
                || normalizeComparisonText(textFromWords(sentenceScopedWords)) == normalizeComparisonText(finalText)

            return TranscriptionSegment(
                speakerID: row.resolvedSpeakerID,
                start: row.start,
                end: row.end,
                text: finalText,
                words: keepWordTimings ? sentenceScopedWords : nil,
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

    private func consensusSourceText(for row: ReconciliationRow) -> String {
        switch row.selectedSource {
        case .reference:
            return row.referenceText
        case .candidate:
            return row.candidateText
        case .manual:
            if normalizeComparisonText(row.referenceText) == normalizeComparisonText(row.draftText) {
                return row.referenceText
            }

            if normalizeComparisonText(row.candidateText) == normalizeComparisonText(row.draftText) {
                return row.candidateText
            }

            return row.draftText
        }
    }

    private func trimmedWords(
        from segments: [TranscriptionSegment],
        start: TimeInterval,
        end: TimeInterval
    ) -> [TranscriptionSegment.WordTiming]? {
        guard let words = ReconciliationSegmentSummary.aggregateWords(segments) else { return nil }

        let filteredWords = words.filter { word in
            Double(word.end) > start && Double(word.start) < end
        }

        return filteredWords.isEmpty ? nil : filteredWords
    }

    private func textFromWords(_ words: [TranscriptionSegment.WordTiming]?) -> String {
        guard let words, !words.isEmpty else { return "" }
        return words.map(\.word).joined(separator: " ")
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
        resetSpeakerMapping: Bool,
        sourcePassID: UUID? = nil
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
            currentPhase = kind == .standard ? .review : .deepTranscription
            await saveCompletedPass(
                result: transcriptionResult,
                kind: kind,
                engine: engine,
                resetSpeakerMapping: resetSpeakerMapping,
                sourcePassID: sourcePassID
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

    /// Count how many words ended up with a different speakerID after re-attribution.
    /// Uses word UUIDs to match words across the before/after merged transcripts.
    private static func countWordsThatMovedSpeaker(
        before: MergedTranscript,
        after: MergedTranscript
    ) -> Int {
        var beforeSpeaker: [UUID: String] = [:]
        for segment in before.segments {
            for word in segment.words {
                beforeSpeaker[word.id] = word.speakerID
            }
        }
        var moved = 0
        for segment in after.segments {
            for word in segment.words {
                if let prior = beforeSpeaker[word.id], prior != word.speakerID {
                    moved += 1
                }
            }
        }
        return moved
    }

    private static func recordingStartTime(
        for url: URL?,
        duration: TimeInterval,
        fallbackStartTime: Date? = nil
    ) -> Date? {
        guard duration > 0 else { return fallbackStartTime }
        guard let url else { return fallbackStartTime }

        // Primary: Read the embedded creation_time from the audio container metadata.
        // M4A/MP4 files store this in the container header as the recording end time
        // (when the file was finalized). More reliable than filesystem dates, which
        // reflect when the file was copied/transferred to this machine.
        if let embeddedDate = embeddedCreationDate(for: url) {
            return embeddedDate.addingTimeInterval(-duration)
        }

        // Fallback: filesystem creation date minus duration.
        if let endTime = filesystemEndTime(for: url) {
            return endTime.addingTimeInterval(-duration)
        }

        return fallbackStartTime
    }

    /// Read the embedded creation date from the audio file's container metadata.
    private static func embeddedCreationDate(for url: URL) -> Date? {
        let asset = AVURLAsset(url: url)
        guard let metadataItem = asset.creationDate else { return nil }
        // Use the synchronous value accessor (deprecated but simpler for this context)
        // swiftlint:disable:next legacy_objc_type
        return (metadataItem.value as? NSDate) as Date?
    }

    /// Filesystem creation date fallback.
    private static func filesystemEndTime(for url: URL) -> Date? {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path) else {
            return nil
        }
        if let creationDate = attrs[.creationDate] as? Date {
            return creationDate
        }
        return attrs[.modificationDate] as? Date
    }

    private static func defaultLegalPDFHeader(fileName: String, recordingStartTime: Date?) -> String {
        guard let recordingStartTime else {
            return "TRANSCRIPT\n\(fileName)"
        }

        let formatter = DateFormatter()
        formatter.dateStyle = .long
        formatter.timeStyle = .short
        return "TRANSCRIPT\n\(fileName)\n\(formatter.string(from: recordingStartTime))"
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
