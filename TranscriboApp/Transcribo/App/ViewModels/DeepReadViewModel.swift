import Foundation
import Observation
import AVFoundation
import AppKit

/// Orchestrates the Deep Read flow — and, via the `mode` property, the
/// trimmed Quick Take and expanded Studio surfaces too. There is one shared
/// nine-stage pipeline: each stage either runs automatically or surfaces an
/// interactive screen, depending on the active `ModeState`.
///
/// Phase 1a: the idle → importing → setup transition is wired end-to-end.
/// Later stages are present as cases on `Stage` so views can route against
/// them, but their work is stubbed — TODO markers point at the services
/// that will drive each step in Phase 1b (transcription), Phase 1c (speaker
/// naming + LLM reconciliation), and Phase 1d (interactive review + export).
@Observable
@MainActor
final class DeepReadViewModel {

    // MARK: - State

    /// Which of the three UI surfaces is active. Kept on the VM (rather than
    /// injected from each view) so mid-flow mode switches work — a user can
    /// enter via Quick Take, promote to Deep Read when they realise they
    /// want to control the review, or drop into Studio for fine-tuning.
    var mode: ModeState = .default

    /// Current stage of the flow. Views observe this and route accordingly.
    private(set) var stage: Stage = .idle

    /// The project currently being worked on. `nil` when `stage == .idle`.
    private(set) var project: ProjectDocument?

    /// In-memory cache of the currently-shown pass. The review view reads
    /// from here rather than re-hitting disk. Cleared on `close()`.
    private(set) var activePassContent: TranscriptPass?

    /// Indices (into `activePassContent.segments`) that the user has
    /// explicitly marked as resolved from the uncertainty list. Survives
    /// only for the duration of the open project — cleared on `close()`.
    /// Persistence to disk can come later if the use case demands it.
    var resolvedUncertaintyIndices: Set<Int> = []

    /// Whether the audio player is currently playing a context clip.
    /// Drives the Play / Stop button icon in the uncertainty popover.
    private(set) var isPlayingContext: Bool = false

    /// Shared audio player for Play Context actions.
    private let audioPlayer = AudioContextPlayer()

    /// The summary + to-dos document for the current project. Loaded from
    /// disk on entering `.reviewing`; edited in `SummaryPane`; saved via
    /// `ProjectLibrary.saveSummary(_:for:)`.
    var summary: SummaryDocument = SummaryDocument()

    /// Whether the summary pane is visible in the review view. Persisted
    /// on `project.settings.includeSummary` so the choice survives a
    /// close-and-reopen.
    var showSummaryPane: Bool = false

    /// UI state for summary generation.
    enum SummaryState: Equatable {
        case idle
        case running(fraction: Double, label: String)
        case error(String)
    }
    var summaryState: SummaryState = .idle

    /// User-facing error, consumed by the parent view's alert modifier.
    var errorMessage: String?
    var showError: Bool = false

    /// Drives the `.fileImporter` on the root view.
    var showFilePicker: Bool = false

    // MARK: - Dependencies

    let library: ProjectLibrary
    let voiceStore: VoiceLibraryStore

    init(library: ProjectLibrary, voiceStore: VoiceLibraryStore) {
        self.library = library
        self.voiceStore = voiceStore
    }

    // MARK: - Stage definition

    /// The nine flow stages described in the rewrite plan, collapsed to the
    /// eight the UI needs to route against. The `import` stage is folded
    /// into `.importingAudio`.
    enum Stage: Equatable {
        /// No project open — the drop card is visible.
        case idle

        /// Validating and copying the user's audio into the project directory.
        case importingAudio(url: URL)

        /// Project created, audio settled, setup card is showing.
        /// User picks Speed (Quick / Deep) and Include (Summary, To-dos).
        case setup

        /// Engine A transcribing. Later, Engine B runs in parallel for Deep
        /// tier. Progress is tracked via `StageProgress`.
        case transcribing(progress: StageProgress)

        /// User confirms auto-detected speaker names. The suggestions list
        /// is pre-filled from the "Hi, this is X" scan and voice library.
        case namingSpeakers(suggestions: [SpeakerSuggestion])

        /// LLM reconciliation running — either the single-shot pass or the
        /// question-loop second pass. Progress reflects streaming tokens.
        case reconciling(progress: StageProgress)

        /// Main transcript view with inline uncertainty popovers and the
        /// verbatim/clean toggle. The reviewing state stays active until
        /// the user exports.
        case reviewing

        /// Export sheet open on top of the reviewing state.
        case exporting
    }

    struct StageProgress: Equatable {
        /// Value in `[0, 1]`. Progress bars bind to this.
        var fraction: Double
        /// Short user-facing label, e.g. "Transcribing… 04:12 of 08:00".
        var label: String
        /// Seconds since the stage started. Used for ETA interpolation.
        var elapsedSeconds: TimeInterval

        static let zero = StageProgress(fraction: 0, label: "", elapsedSeconds: 0)
    }

    struct SpeakerSuggestion: Identifiable, Equatable {
        let id: String            // SPEAKER_N from the diarizer
        var suggestedName: String // autofilled from intro scan or voice library
        var voiceLibraryMatchID: UUID?
        var sampleClipURL: URL?
        var confidence: Double    // 0...1
    }

    // MARK: - Flow

    /// Refresh the project library's index so the drop screen's recent-
    /// projects section can show the latest rows. Safe to call from an
    /// `.onAppear` — cheap (reads per-project `project.json` headers only).
    func refreshRecentProjects() async {
        do {
            try await library.reload()
        } catch {
            // Non-fatal — the drop screen still works, the recent list is
            // just empty.
        }
    }

    /// Open a previously-transcribed project. Loads its document + active
    /// pass from disk, hydrates the in-memory caches, advances to the
    /// stage that makes sense given what's there (`.reviewing` if a pass
    /// is saved, `.setup` otherwise), and flips the summary pane on if
    /// the project has saved summary content.
    func openProject(_ id: UUID) async {
        do {
            let doc = try library.load(id)
            let pass = try library.loadPass(doc.activePass, for: id)
            project = doc
            activePassContent = pass
            resolvedUncertaintyIndices = []
            if let loadedSummary = try? library.loadSummary(id) {
                summary = loadedSummary
                showSummaryPane = !loadedSummary.summary.isEmpty || !loadedSummary.todos.isEmpty
            } else {
                summary = SummaryDocument()
                showSummaryPane = doc.settings.includeSummary
            }
            stage = pass == nil ? .setup : .reviewing
        } catch {
            report(error)
        }
    }

    /// Kick off the import from a dropped audio URL. Validates the file,
    /// copies or links it into the project directory, persists a fresh
    /// `ProjectDocument`, and advances the stage.
    ///
    /// For `.deepRead` and `.studio`, the flow stops at `.setup` so the
    /// user can pick Speed + Include options. For `.quickTake`, the setup
    /// stage is bypassed entirely (no configuration screens, per the plan)
    /// — Speed auto-picks from audio duration (≤30 min → Deep, else
    /// Standard), summary stays off by default, transcription starts
    /// immediately.
    func beginImport(from url: URL) async {
        stage = .importingAudio(url: url)

        do {
            let info = try await probeAudio(at: url)
            let audio = AudioAsset(
                originalURL: url,
                localFilename: nil,
                durationSeconds: info.duration,
                recordingStartTime: info.creationDate.map { $0.addingTimeInterval(-info.duration) },
                contentHash: nil
            )
            let title = url.deletingPathExtension().lastPathComponent
            var settings = ProjectSettings()
            if mode == .quickTake {
                settings.speed = Self.recommendedQuickTakeSpeed(durationSeconds: info.duration)
                settings.includeSummary = false
                settings.includeTodos = false
            }
            let document = ProjectDocument(
                title: title,
                audio: audio,
                mode: mode,
                settings: settings
            )
            let created = try library.create(document)
            self.project = created

            if mode == .quickTake {
                // Skip the setup card — go straight to Transcribing.
                await startTranscription()
            } else {
                self.stage = .setup
            }
        } catch {
            report(error)
        }
    }

    /// Speed tier Quick Take should auto-pick from audio length.
    /// Under 30 minutes gets the LLM reconciliation tier; over 30 minutes
    /// falls back to Standard so the single-shot LLM prompt doesn't blow
    /// out its context window.
    static func recommendedQuickTakeSpeed(durationSeconds: Double) -> SpeedTier {
        durationSeconds <= 30 * 60 ? .deep : .standard
    }

    /// Called from the setup card when the user presses Transcribe.
    /// Phase 1b: runs the standard (single-engine) pipeline end-to-end —
    /// Parakeet + SpeakerKit + merge — persists the result, and transitions
    /// directly to `.reviewing`. Phase 1c will branch on `.deep` speed to
    /// add Engine B + `LLMReconcileService` + the speaker-naming stage.
    func startTranscription() async {
        guard let current = project else { return }
        stage = .transcribing(progress: .zero)

        let runStart = Date()
        let runner = StandardPassRunner()

        do {
            let pass = try await runner.run(
                audioURL: current.audio.originalURL,
                options: .init(
                    variant: .parakeetV3,
                    language: "en",
                    requestedSpeakerCount: nil,
                    audioDurationSeconds: current.audio.durationSeconds
                ),
                progress: { [weak self] update in
                    Task { @MainActor [weak self] in
                        self?.stage = .transcribing(progress: .init(
                            fraction: update.fraction,
                            label: update.label,
                            elapsedSeconds: Date().timeIntervalSince(runStart)
                        ))
                    }
                }
            )

            try library.savePass(pass, for: current.id)

            var updated = current
            let roster = StandardPassRunner.speakerRoster(for: pass.segments)
            updated.speakers = Self.mergeSpeakers(existing: current.speakers, detected: roster)
            updated.activePass = pass.kind
            project = try library.save(updated)
            activePassContent = pass

            stage = .namingSpeakers(
                suggestions: Self.buildSuggestions(
                    from: updated.speakers,
                    segments: pass.segments
                )
            )
        } catch {
            report(error)
            stage = .setup
        }
    }

    /// Builds the suggestion list the naming screen binds to. Phase 1c.2
    /// enriches the diarizer's default labels with matches from the
    /// `IntroScanner` ("Hi, this is X" / "My name is X" / etc.); voice
    /// library matching arrives in Phase 4.
    private static func buildSuggestions(
        from speakers: [Speaker],
        segments: [TranscriptionSegment]
    ) -> [SpeakerSuggestion] {
        let intros = IntroScanner.scan(segments: segments)
        let introByID = Dictionary(
            uniqueKeysWithValues: intros.map { ($0.speakerID, $0) }
        )
        return speakers.map { speaker in
            let intro = introByID[speaker.id]
            let usingIntro = intro != nil && !speaker.isConfirmed
            return SpeakerSuggestion(
                id: speaker.id,
                suggestedName: usingIntro ? intro!.proposedName : speaker.displayName,
                voiceLibraryMatchID: speaker.voiceLibraryID,
                sampleClipURL: nil,
                confidence: intro?.confidence ?? (speaker.isConfirmed ? 1.0 : 0.0)
            )
        }
    }

    /// Merge a freshly-detected speaker roster with the project's existing
    /// one. Preserves user-confirmed names and voice library matches that
    /// were set before re-running transcription; new speakers get default
    /// labels.
    private static func mergeSpeakers(
        existing: [Speaker],
        detected: [Speaker]
    ) -> [Speaker] {
        let existingByID = Dictionary(uniqueKeysWithValues: existing.map { ($0.id, $0) })
        return detected.map { freshSpeaker in
            if var prior = existingByID[freshSpeaker.id] {
                prior.paletteIndex = freshSpeaker.paletteIndex
                return prior
            }
            return freshSpeaker
        }
    }

    /// Called from `SpeakerNamingView` when the user confirms speaker names.
    /// Writes the confirmed names onto the project and then branches on
    /// Speed:
    /// - `.standard` (Quick) → advances directly to `.reviewing` with the
    ///    Standard pass that's already on disk.
    /// - `.deep` / `.verified` / `.perfect` → advances to `.reconciling`,
    ///    runs `DeepPassRunner` (Whisper + LLMReconcileService) with the
    ///    confirmed names as `knownSpeakerNames`, writes `.deep` pass to
    ///    disk, swaps it in as the active pass, and advances to `.reviewing`.
    ///    If the deep run fails, falls back to the Standard pass with an
    ///    error alert so the user still sees their transcript.
    func confirmSpeakers(_ mappings: [SpeakerSuggestion]) async {
        guard var current = project else { return }

        for suggestion in mappings {
            guard let idx = current.speakers.firstIndex(where: { $0.id == suggestion.id }) else { continue }
            let trimmed = suggestion.suggestedName.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                current.speakers[idx].displayName = trimmed
            }
            current.speakers[idx].isConfirmed = true
            current.speakers[idx].voiceLibraryID = suggestion.voiceLibraryMatchID
        }

        do {
            project = try library.save(current)
        } catch {
            report(error)
            return
        }

        switch current.settings.speed {
        case .standard:
            stage = .reviewing
        case .deep, .verified, .perfect:
            await runDeepPass()
        }

        // If the user opted into Summary at setup, kick off auto-generation
        // in the background so the pane populates while they're reading.
        // Runs on top of whatever transcript pass just completed.
        if current.settings.includeSummary, activePassContent != nil {
            showSummaryPane = true
            Task { await regenerateSummary() }
        }
    }

    /// Runs the Deep-tier pass (Engine B + LLM reconciliation) on top of
    /// the already-persisted Standard pass. Keeps the VM live so the
    /// reconciliation progress updates the UI in real time.
    private func runDeepPass() async {
        guard let current = project,
              let standardPass = activePassContent else {
            stage = .reviewing
            return
        }

        stage = .reconciling(progress: .zero)

        let runStart = Date()
        let runner = DeepPassRunner()

        do {
            let deepPass = try await runner.run(
                audioURL: current.audio.originalURL,
                standardPass: standardPass,
                speakers: current.speakers,
                options: .init(
                    whisperModel: .largeV3,
                    llmModel: CleanupModel.recommended(),
                    domainHint: current.settings.domainHint,
                    language: "en",
                    audioDurationSeconds: current.audio.durationSeconds
                ),
                progress: { [weak self] update in
                    Task { @MainActor [weak self] in
                        self?.stage = .reconciling(progress: .init(
                            fraction: update.fraction,
                            label: update.label,
                            elapsedSeconds: Date().timeIntervalSince(runStart)
                        ))
                    }
                }
            )

            try library.savePass(deepPass, for: current.id)

            var updated = current
            updated.activePass = deepPass.kind
            project = try library.save(updated)
            activePassContent = deepPass

            stage = .reviewing
        } catch {
            // Deep path failed — fall back to the Standard pass we already have.
            // The user still gets a transcript; an alert explains the degrade.
            errorMessage = "Deep reconciliation failed: \(error.localizedDescription). Showing the Standard-tier transcript instead."
            showError = true
            stage = .reviewing
        }
    }

    /// Called from the interactive review view as the user resolves A/B
    /// uncertainty items. The final pass runs once everything is resolved
    /// (or skipped).
    func resolveUncertainties() async {
        stage = .reviewing

        // TODO (Phase 1d): final LLM pass with user-resolved answers;
        // update the deep pass on disk; refresh the visible transcript.
    }

    /// Open the export sheet. Final state of the flow; user returns to
    /// `.reviewing` on dismiss.
    func openExport() {
        guard case .reviewing = stage else { return }
        stage = .exporting
    }

    func dismissExport() {
        guard case .exporting = stage else { return }
        stage = .reviewing
    }

    /// Return to the idle state, releasing the current project from memory.
    /// The project stays on disk; reopen via the Project Library window.
    func close() {
        audioPlayer.stop()
        isPlayingContext = false
        resolvedUncertaintyIndices = []
        summary = SummaryDocument()
        summaryState = .idle
        showSummaryPane = false
        project = nil
        activePassContent = nil
        stage = .idle
    }

    // MARK: - Summary

    /// Load the summary document for the current project from disk. Called
    /// from the review view on first appearance. No-op if there's no
    /// project or if `summaryState` is already populated for it.
    func loadSummaryIfNeeded() {
        guard let project, case .idle = summaryState else { return }
        if let loaded = try? library.loadSummary(project.id) {
            summary = loaded
        }
        // Auto-show the pane if the project was set up with summary on,
        // or if there's already content on disk.
        if project.settings.includeSummary ||
           !summary.summary.isEmpty ||
           !summary.todos.isEmpty {
            showSummaryPane = true
        }
    }

    func toggleSummaryPane() {
        showSummaryPane.toggle()
    }

    /// Runs `SummaryRunner` against the active pass and persists the
    /// result. Called from the SummaryPane's Generate / Regenerate
    /// buttons. On success, updates `summary` and persists to
    /// `summary.json`. On failure, surfaces an error on `summaryState`.
    func regenerateSummary() async {
        guard let project, let pass = activePassContent else { return }

        let runner = SummaryRunner()
        summaryState = .running(fraction: 0, label: "Starting…")

        do {
            let output = try await runner.run(
                project: project,
                pass: pass,
                model: CleanupModel.recommended(),
                progress: { [weak self] update in
                    Task { @MainActor [weak self] in
                        self?.summaryState = .running(
                            fraction: update.fraction,
                            label: update.label
                        )
                    }
                }
            )

            var updated = summary
            updated.summary = output.summary
            updated.todos = output.todos
            updated.summaryRegeneratedAt = Date()
            updated.todosRegeneratedAt = Date()
            updated.summaryEditedByUser = false
            updated.todosEditedByUser = false
            try library.saveSummary(updated, for: project.id)
            summary = updated
            summaryState = .idle
        } catch {
            summaryState = .error(error.localizedDescription)
        }
    }

    /// Write user-edited summary text back to disk. Called from the
    /// SummaryPane's text editor on commit.
    func saveSummaryEdit(_ newSummary: String) {
        guard let project else { return }
        summary.summary = newSummary
        summary.summaryEditedByUser = true
        try? library.saveSummary(summary, for: project.id)
    }

    /// Toggle a to-do's done state; persists immediately.
    func toggleTodoDone(_ todoID: UUID) {
        guard let project,
              let idx = summary.todos.firstIndex(where: { $0.id == todoID }) else { return }
        summary.todos[idx].isDone.toggle()
        summary.todosEditedByUser = true
        try? library.saveSummary(summary, for: project.id)
    }

    /// Edit a to-do's text; persists immediately.
    func updateTodoText(_ todoID: UUID, _ newText: String) {
        guard let project,
              let idx = summary.todos.firstIndex(where: { $0.id == todoID }) else { return }
        summary.todos[idx].text = newText
        summary.todosEditedByUser = true
        try? library.saveSummary(summary, for: project.id)
    }

    /// Copy the summary text to the pasteboard.
    func copySummary() {
        guard !summary.summary.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(summary.summary, forType: .string)
        copyConfirmationVisible = true
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 1_800_000_000)
            self?.copyConfirmationVisible = false
        }
    }

    /// Copy the to-dos to the pasteboard as a Markdown checklist.
    func copyTodos() {
        guard !summary.todos.isEmpty else { return }
        let lines = summary.todos.map { todo -> String in
            let box = todo.isDone ? "[x]" : "[ ]"
            let owner = todo.ownerSpeakerID.flatMap { id in
                project?.speakers.first { $0.id == id }?.displayName
            }
            let suffix = owner.map { " (\($0))" } ?? ""
            return "- \(box) \(todo.text)\(suffix)"
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(lines.joined(separator: "\n"), forType: .string)
        copyConfirmationVisible = true
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 1_800_000_000)
            self?.copyConfirmationVisible = false
        }
    }

    // MARK: - Uncertainty review

    /// Count of uncertain segments the user still needs to look at.
    /// Drives the "N to review" badge in the review view header.
    var unresolvedUncertaintyCount: Int {
        guard let pass = activePassContent else { return 0 }
        return pass.uncertainSegmentIndices.subtracting(resolvedUncertaintyIndices).count
    }

    /// True when this segment index is flagged by the LLM AND not yet
    /// resolved by the user.
    func isUncertain(index: Int) -> Bool {
        guard let pass = activePassContent else { return false }
        return pass.uncertainSegmentIndices.contains(index)
            && !resolvedUncertaintyIndices.contains(index)
    }

    /// Mark an uncertain segment as resolved — removes it from the review
    /// counter but keeps the LLM flag on disk so the pass stays honest.
    func markUncertaintyResolved(at index: Int) {
        resolvedUncertaintyIndices.insert(index)
    }

    /// Undo a resolve — puts the segment back into the counter.
    func unresolveUncertainty(at index: Int) {
        resolvedUncertaintyIndices.remove(index)
    }

    /// The next unresolved-uncertainty segment index after `current`,
    /// wrapping to the start if needed. `nil` when none remain.
    func nextUncertainty(after current: Int?) -> Int? {
        guard let pass = activePassContent else { return nil }
        let candidates = pass.uncertainSegmentIndices
            .subtracting(resolvedUncertaintyIndices)
            .sorted()
        guard !candidates.isEmpty else { return nil }
        if let current, let found = candidates.first(where: { $0 > current }) {
            return found
        }
        return candidates.first
    }

    /// The previous unresolved-uncertainty segment, wrapping to the end.
    func previousUncertainty(before current: Int?) -> Int? {
        guard let pass = activePassContent else { return nil }
        let candidates = pass.uncertainSegmentIndices
            .subtracting(resolvedUncertaintyIndices)
            .sorted()
        guard !candidates.isEmpty else { return nil }
        if let current, let found = candidates.last(where: { $0 < current }) {
            return found
        }
        return candidates.last
    }

    // MARK: - Play Context

    /// Play the audio under a segment ±`padding` seconds. Used by the Play
    /// Context button in uncertainty popovers and future inline playback.
    func playContext(
        for segment: TranscriptionSegment,
        padding: TimeInterval = 2
    ) {
        guard let url = project?.audio.originalURL else { return }
        let start = max(0, segment.start - padding)
        let end = segment.end + padding
        isPlayingContext = true
        audioPlayer.play(url: url, from: start, to: end) { [weak self] in
            Task { @MainActor [weak self] in
                self?.isPlayingContext = false
            }
        }
    }

    func stopContext() {
        audioPlayer.stop()
        isPlayingContext = false
    }

    // MARK: - Export

    /// Export formats exposed in the review toolbar. Phase 1e ships text,
    /// Markdown, and Obsidian Markdown; Legal PDF / DOCX / SRT layer on
    /// later with their own renderers.
    enum ExportFormat: String, CaseIterable, Identifiable, Hashable, Sendable {
        case plainText
        case markdown
        case obsidianMarkdown

        var id: String { rawValue }

        var displayName: String {
            switch self {
            case .plainText:        return "Plain text (.txt)"
            case .markdown:         return "Markdown (.md)"
            case .obsidianMarkdown: return "Obsidian Markdown (.md)"
            }
        }

        var fileExtension: String {
            switch self {
            case .plainText:        return "txt"
            case .markdown, .obsidianMarkdown: return "md"
            }
        }
    }

    /// Transient flag that flips true for a couple of seconds after a
    /// successful copy-to-clipboard so the toolbar button can show a
    /// checkmark. Read by the review view.
    var copyConfirmationVisible: Bool = false

    /// Render the current active pass in the chosen format and place it on
    /// the pasteboard. Convenience for "grab the transcript right now"
    /// flows. Summary/to-dos not included by default — the explicit
    /// `exportToFile` flow has the include-summary checkbox.
    func copyToPasteboard(format: ExportFormat = .markdown) {
        guard let rendered = renderActivePass(format: format, includeSummary: false) else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(rendered, forType: .string)

        copyConfirmationVisible = true
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 1_800_000_000)
            self?.copyConfirmationVisible = false
        }
    }

    /// Opens an `NSSavePanel` and writes the rendered transcript to disk.
    /// Returns the saved URL (or `nil` on cancel / error). Runs on the main
    /// actor — safe to call directly from a SwiftUI action.
    @discardableResult
    func exportToFile(
        format: ExportFormat = .markdown,
        includeSummary: Bool = false
    ) -> URL? {
        guard let rendered = renderActivePass(format: format, includeSummary: includeSummary),
              let project else { return nil }

        let panel = NSSavePanel()
        panel.title = "Export transcript"
        panel.nameFieldStringValue = "\(project.title).\(format.fileExtension)"
        panel.allowedContentTypes = format.fileExtension == "txt"
            ? [.plainText]
            : [.plainText] // macOS UTType doesn't have .markdown natively; .plainText covers .md
        panel.canCreateDirectories = true

        guard panel.runModal() == .OK, let url = panel.url else { return nil }

        do {
            try rendered.write(to: url, atomically: true, encoding: .utf8)
            return url
        } catch {
            report(error)
            return nil
        }
    }

    private func renderActivePass(format: ExportFormat, includeSummary: Bool) -> String? {
        guard let project, let pass = activePassContent else { return nil }

        let summary: SummaryDocument?
        if includeSummary {
            summary = try? library.loadSummary(project.id)
        } else {
            summary = nil
        }

        switch format {
        case .plainText:
            return TranscriptExporter.plainText(project: project, pass: pass)
        case .markdown:
            return TranscriptExporter.markdown(
                project: project,
                pass: pass,
                summary: summary,
                includeSummary: includeSummary
            )
        case .obsidianMarkdown:
            return TranscriptExporter.obsidianMarkdown(
                project: project,
                pass: pass,
                summary: summary,
                includeSummary: includeSummary
            )
        }
    }

    // MARK: - Settings mutators

    /// Mutators for the setup card's Speed / Include choices. They write
    /// back to `project.settings` and persist so the selections survive a
    /// close-and-reopen.
    func setSpeed(_ tier: SpeedTier) {
        update { $0.settings.speed = tier }
    }

    func setIncludeSummary(_ on: Bool) {
        update { $0.settings.includeSummary = on }
    }

    func setIncludeTodos(_ on: Bool) {
        update { $0.settings.includeTodos = on }
    }

    func setTranscriptStyle(_ style: TranscriptStyle) {
        update { $0.settings.transcriptStyle = style }
    }

    func setDomainHint(_ hint: DomainHint) {
        update { $0.settings.domainHint = hint }
    }

    private func update(_ mutate: (inout ProjectDocument) -> Void) {
        guard var current = project else { return }
        mutate(&current)
        do {
            project = try library.save(current)
        } catch {
            report(error)
        }
    }

    // MARK: - Error handling

    private func report(_ error: Error) {
        errorMessage = error.localizedDescription
        showError = true
        // Don't leave the flow stuck in a transitional stage — fall back to
        // whatever state makes most sense given the error.
        switch stage {
        case .importingAudio:
            stage = .idle
        case .transcribing, .reconciling:
            stage = .reviewing
        default:
            break
        }
    }

    // MARK: - Audio probe

    /// Asset-probes the dropped file for duration + creation metadata.
    /// The `creationDate` in AV container metadata represents when the file
    /// was finalised (i.e., end of recording) — the caller subtracts
    /// `durationSeconds` to derive the actual recording start time.
    private func probeAudio(at url: URL) async throws -> AudioProbe {
        let asset = AVURLAsset(url: url)
        let duration = try await asset.load(.duration)
        let metadata = try await asset.load(.commonMetadata)
        let creationItem = AVMetadataItem.metadataItems(
            from: metadata,
            withKey: AVMetadataKey.commonKeyCreationDate,
            keySpace: .common
        ).first
        let creationDate = try await creationItem?.load(.dateValue)
        return AudioProbe(
            duration: CMTimeGetSeconds(duration),
            creationDate: creationDate
                ?? (try? FileManager.default.attributesOfItem(atPath: url.path)[.creationDate] as? Date)
                ?? nil
        )
    }

    private struct AudioProbe {
        let duration: TimeInterval
        let creationDate: Date?
    }
}
