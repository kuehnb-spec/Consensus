import Foundation
import Observation
import AVFoundation
import AppKit

/// Orchestrates the Deep Read flow — and, via the `mode` property, the
/// trimmed Quick Take and expanded Studio surfaces too. There is one shared
/// nine-stage pipeline: each stage either runs automatically or surfaces an
/// interactive screen, depending on the active `ModeState`.
///
/// The current architecture is patch-centered: VibeVoice produces the
/// canonical transcript, speaker naming confirms protected terms, and Deep
/// Review applies only small audio-verified patches.
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

    /// Rolling live output shown only during the VibeVoice draft pass. Kept
    /// separate from `StageProgress.label` so streaming text cannot resize the
    /// whole progress page.
    private(set) var liveTranscriptionSnippets: [LiveTranscriptionSnippet] = []

    @ObservationIgnored
    private var lastLiveTranscriptWindow: String = ""

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

        /// Patch Review running — second opinion, local re-listen, and
        /// masked-cloze audio verification.
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
        /// Stable one-line machine status for active processing views.
        var status: String?
        /// Total generated tokens when an engine reports token streaming.
        var tokenCount: Int?
        /// Current generation speed when an engine reports it.
        var tokensPerSecond: Double?

        static let zero = StageProgress(
            fraction: 0,
            label: "",
            elapsedSeconds: 0,
            status: nil,
            tokenCount: nil,
            tokensPerSecond: nil
        )
    }

    struct LiveTranscriptionSnippet: Identifiable, Equatable {
        let id: UUID
        var text: String

        init(id: UUID = UUID(), text: String) {
            self.id = id
            self.text = text
        }
    }

    struct SpeakerSuggestion: Identifiable, Equatable {
        let id: String            // SPEAKER_N from the diarizer
        var suggestedName: String // autofilled from intro scan or voice library
        var voiceLibraryMatchID: UUID?
        var sampleClipURL: URL?
        var confidence: Double    // 0...1
        var samples: [UtteranceSample] = []

        struct UtteranceSample: Identifiable, Equatable {
            let id: UUID
            let timestamp: TimeInterval
            let text: String
        }
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
            var doc = try library.load(id)
            let normalized = Self.normalizedForPatchReviewAvailability(doc)
            if normalized != doc {
                doc = try library.save(normalized)
            }
            let pass = try library.loadPass(doc.activePass, for: id)
            project = doc
            resolvedUncertaintyIndices = []
            if let loadedSummary = try? library.loadSummary(id) {
                summary = loadedSummary
                showSummaryPane = !loadedSummary.summary.isEmpty || !loadedSummary.todos.isEmpty
            } else {
                summary = SummaryDocument()
                showSummaryPane = doc.settings.includeSummary
            }
            if let pass, pass.segments.isEmpty {
                activePassContent = nil
                stage = .setup
                report(ConsensusError.transcriptionFailed("This project contains an empty transcript pass from an older build. Re-run Transcribe with Consensus 1.1 to regenerate it."))
            } else {
                activePassContent = pass
                stage = pass == nil ? .setup : .reviewing
            }
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
            var settings = Self.settingsForLocalCapabilities()
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
    /// Under 30 minutes gets the patch-review tier; over 30 minutes falls
    /// back to Standard while the sidecar batching/runtime budget is still
    /// being calibrated.
    static func recommendedQuickTakeSpeed(durationSeconds: Double) -> SpeedTier {
        guard PatchReviewRunner.isAvailable else { return SpeedTier.standard }
        return durationSeconds <= 30 * 60 ? SpeedTier.deep : SpeedTier.standard
    }

    /// Called from the setup card when the user presses Transcribe.
    /// Phase 1b: runs the standard (single-engine) pipeline end-to-end —
    /// VibeVoice (or the selected Standard engine) — persists the canonical
    /// pass, then moves to speaker confirmation before the patch-centered
    /// Deep Review pass.
    func startTranscription() async {
        guard let current = project else { return }
        stage = .transcribing(progress: .zero)
        liveTranscriptionSnippets = []
        lastLiveTranscriptWindow = ""

        let runStart = Date()
        let runner = StandardPassRunner()

        do {
            let pass = try await runner.run(
                audioURL: current.audio.originalURL,
                options: .init(
                    // The new Deep Review architecture is calibrated around
                    // VibeVoice as the canonical transcript. Other engines
                    // can still serve as second opinions inside Patch Review,
                    // but the user-facing app no longer starts from them.
                    engine: .vibevoice,
                    variant: .parakeetV3,
                    language: "en",
                    requestedSpeakerCount: nil,
                    audioDurationSeconds: current.audio.durationSeconds,
                    vibeVoiceContext: Self.vibeVoiceContext(from: current)
                ),
                progress: { [weak self] update in
                    Task { @MainActor [weak self] in
                        if let recentText = update.recentText {
                            self?.recordLiveTranscriptionSnippet(recentText)
                        }
                        self?.stage = .transcribing(progress: .init(
                            fraction: update.fraction,
                            label: update.label,
                            elapsedSeconds: Date().timeIntervalSince(runStart),
                            status: update.status,
                            tokenCount: update.tokenCount,
                            tokensPerSecond: update.tokensPerSecond
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

            let suggestions = Self.buildSuggestions(
                from: updated.speakers,
                segments: pass.segments
            )

            if updated.mode == .quickTake {
                // Quick Take never blocks on the naming screen. Apply only
                // high-confidence intro-scan names; everyone else stays
                // "Speaker N" and can be renamed inline on the result view.
                await confirmSpeakers(Self.autoConfirmMappings(from: suggestions))
            } else {
                stage = .namingSpeakers(suggestions: suggestions)
            }
        } catch {
            report(error)
            stage = mode == .quickTake ? .idle : .setup
        }
    }

    /// Intro-scan confidence a name needs before Quick Take applies it
    /// without asking. Below this, keeping the neutral "Speaker N" label is
    /// better than baptizing the transcript with a guessed name.
    private static let quickTakeAutoNameConfidence: Double = 0.75

    /// Quick Take's stand-in for the naming screen: keep suggested names
    /// only when the intro scan was confident; blank out the rest so
    /// `confirmSpeakers` preserves each speaker's existing display name.
    private static func autoConfirmMappings(
        from suggestions: [SpeakerSuggestion]
    ) -> [SpeakerSuggestion] {
        suggestions.map { suggestion in
            var mapped = suggestion
            if suggestion.confidence < quickTakeAutoNameConfidence {
                mapped.suggestedName = ""
            }
            return mapped
        }
    }

    /// Rename a speaker after the pipeline has finished — the inline rename
    /// path used by the Quick Take result view (which has no naming stage).
    func renameSpeaker(id: String, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        update { document in
            guard let idx = document.speakers.firstIndex(where: { $0.id == id }) else { return }
            document.speakers[idx].displayName = trimmed
            document.speakers[idx].isConfirmed = true
        }
    }

    private func recordLiveTranscriptionSnippet(_ rawText: String) {
        let currentWindow = Self.normalizedLiveText(rawText)
        guard !currentWindow.isEmpty else { return }

        let delta = Self.normalizedLiveText(
            Self.novelSuffix(current: currentWindow, previous: lastLiveTranscriptWindow)
        )
        lastLiveTranscriptWindow = currentWindow
        guard !delta.isEmpty else { return }

        let clipped = Self.clippedLiveSnippet(delta)
        if clipped.count < 18, !liveTranscriptionSnippets.isEmpty {
            let lastIndex = liveTranscriptionSnippets.index(before: liveTranscriptionSnippets.endIndex)
            let merged = "\(liveTranscriptionSnippets[lastIndex].text) \(clipped)"
            liveTranscriptionSnippets[lastIndex].text = Self.clippedLiveSnippet(merged, limit: 280)
        } else if liveTranscriptionSnippets.last?.text != clipped {
            liveTranscriptionSnippets.append(.init(text: clipped))
        }

        let maxRows = 48
        if liveTranscriptionSnippets.count > maxRows {
            liveTranscriptionSnippets.removeFirst(liveTranscriptionSnippets.count - maxRows)
        }
    }

    private static func normalizedLiveText(_ text: String) -> String {
        var cleaned = text
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\\\"", with: "\"")
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        while cleaned.first == "\u{2026}" {
            cleaned.removeFirst()
            cleaned = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return cleaned
    }

    private static func novelSuffix(current: String, previous: String) -> String {
        guard !previous.isEmpty else { return current }
        guard current != previous else { return "" }

        if current.hasPrefix(previous) {
            return String(current.dropFirst(previous.count))
        }
        if let previousRange = current.range(of: previous) {
            return String(current[previousRange.upperBound...])
        }

        var overlapLength = min(previous.count, current.count)
        while overlapLength >= 24 {
            if previous.suffix(overlapLength) == current.prefix(overlapLength) {
                return String(current.dropFirst(overlapLength))
            }
            overlapLength -= 1
        }
        return current
    }

    private static func clippedLiveSnippet(_ text: String, limit: Int = 220) -> String {
        let cleaned = normalizedLiveText(text)
        guard cleaned.count > limit else { return cleaned }
        return "... \(cleaned.suffix(limit))"
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
        let samplesByID = collectSamples(from: segments)
        return speakers.map { speaker in
            let intro = introByID[speaker.id]
            let usingIntro = intro != nil && !speaker.isConfirmed
            return SpeakerSuggestion(
                id: speaker.id,
                suggestedName: usingIntro ? intro!.proposedName : speaker.displayName,
                voiceLibraryMatchID: speaker.voiceLibraryID,
                sampleClipURL: nil,
                confidence: intro?.confidence ?? (speaker.isConfirmed ? 1.0 : 0.0),
                samples: samplesByID[speaker.id] ?? []
            )
        }
    }

    /// Picks up to thirty short utterances per speaker, ordered by start time,
    /// so the naming screen can show three previews and expand to a wider
    /// temporal sample on demand. Favors substantive lines (≥5 words) and
    /// truncates anything longer than ~140 chars. The expansion UI in
    /// `SpeakerNamingView` redistributes the full set across the recording's
    /// timeline so the user sees voice samples from start, middle, and end —
    /// useful when two speakers sound similar in the opening minute.
    private static func collectSamples(
        from segments: [TranscriptionSegment]
    ) -> [String: [SpeakerSuggestion.UtteranceSample]] {
        var byID: [String: [SpeakerSuggestion.UtteranceSample]] = [:]
        let maxPerSpeaker = 30
        let maxChars = 140
        let minWords = 5

        for segment in segments {
            let current = byID[segment.speakerID] ?? []
            if current.count >= maxPerSpeaker { continue }

            let trimmed = segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            let wordCount = trimmed.split(whereSeparator: { $0.isWhitespace }).count
            guard wordCount >= minWords else { continue }

            let display: String
            if trimmed.count > maxChars {
                let cut = trimmed.prefix(maxChars)
                display = String(cut).trimmingCharacters(in: .whitespacesAndNewlines) + "…"
            } else {
                display = trimmed
            }

            byID[segment.speakerID, default: []].append(
                SpeakerSuggestion.UtteranceSample(
                    id: UUID(),
                    timestamp: segment.start,
                    text: display
                )
            )
        }
        return byID
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
    ///    runs `PatchReviewRunner` (second ASR + local re-listen + masked
    ///    cloze verifier), writes the patched `.deep` pass to disk, swaps it
    ///    in as the active pass, and advances to `.reviewing`.
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

    /// Runs the Deep-tier patch editor on top of the already-persisted
    /// Standard pass. The old full-transcript LLM reconciliation path is no
    /// longer part of the active app architecture; Deep Review now means
    /// tool-constrained, auditable patches.
    private func runDeepPass() async {
        guard let current = project,
              let standardPass = activePassContent else {
            stage = .reviewing
            return
        }

        guard PatchReviewRunner.isAvailable else {
            var updated = current
            updated.settings.speed = .standard
            project = try? library.save(updated)
            stage = .reviewing
            return
        }

        stage = .reconciling(progress: .zero)

        let runStart = Date()
        let runner = PatchReviewRunner()

        do {
            let deepPass = try await runner.run(
                audioURL: current.audio.originalURL,
                standardPass: standardPass,
                speakers: current.speakers,
                options: .init(
                    whisperModel: .largeV3,
                    language: "en",
                    audioDurationSeconds: current.audio.durationSeconds,
                    context: Self.vibeVoiceContext(from: current),
                    protectedTerms: current.lexicon.terms
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
            // Deep path failed — fall back to the Standard pass we already
            // have. Deep Read/Studio users get an alert explaining the
            // degrade; Quick Take degrades silently to a polished Standard
            // transcript (June 30 decision: no scary alerts in the
            // pushbutton flow).
            if current.mode != .quickTake {
                errorMessage = "Patch Review failed: \(error.localizedDescription). Showing the Standard-tier transcript instead."
                showError = true
            }
            stage = .reviewing
        }
    }

    /// Called from the interactive review view as the user resolves A/B
    /// uncertainty items. The final pass runs once everything is resolved
    /// (or skipped).
    func resolveUncertainties() async {
        stage = .reviewing

        // TODO: persist patch-review resolution state separately from the
        // applied transcript so the audit trail survives close/reopen.
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
        liveTranscriptionSnippets = []
        lastLiveTranscriptWindow = ""
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

    /// True when this segment index is a patch-review item AND not yet
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

    /// Apply one of the Engine-A / Engine-B alternatives onto an uncertain
    /// turn. Overwrites `segments[index].text` and the matching
    /// `styles.cleanText[index]`, then persists the pass and marks the
    /// review item resolved so the badge count drops immediately.
    func applyAlternative(at index: Int, text: String) {
        guard var pass = activePassContent,
              let project,
              index >= 0, index < pass.segments.count
        else { return }

        pass.segments[index].text = text
        if var styles = pass.styles, index < styles.cleanText.count {
            styles.cleanText[index] = text
            pass.styles = styles
        }
        activePassContent = pass
        resolvedUncertaintyIndices.insert(index)

        do {
            try library.savePass(pass, for: project.id)
        } catch {
            report(error)
        }
    }

    // MARK: - Export

    /// Transient flag that flips true for a couple of seconds after a
    /// successful copy-to-clipboard so the toolbar button can show a
    /// checkmark. Read by the review view.
    var copyConfirmationVisible: Bool = false

    /// Render the current active pass in the chosen format and place it on
    /// the pasteboard. Convenience for "grab the transcript right now"
    /// flows. Summary/to-dos not included by default — the explicit
    /// `exportToFile` flow has the include-summary checkbox.
    func copyToPasteboard(format: ExportFormat = .md) {
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
        format: ExportFormat = .md,
        includeSummary: Bool = false,
        legalPDFOptions: LegalPDFOptions? = nil
    ) -> URL? {
        guard let project else { return nil }

        let panel = NSSavePanel()
        panel.title = "Export transcript"
        panel.nameFieldStringValue = "\(project.title).\(format.fileExtension)"
        panel.canCreateDirectories = true

        guard panel.runModal() == .OK, let url = panel.url else { return nil }

        do {
            let options = legalPDFOptions ?? defaultLegalPDFOptions(includeSummary: includeSummary)
            let data = try exportData(format: format, includeSummary: includeSummary, legalPDFOptions: options)
            try data.write(to: url, options: .atomic)
            return url
        } catch {
            report(error)
            return nil
        }
    }

    /// Public entry point for views (e.g. `ExportSheet`) that want the
    /// rendered string without triggering pasteboard or save-panel I/O.
    func renderExport(format: ExportFormat, includeSummary: Bool) -> String? {
        renderActivePass(format: format, includeSummary: includeSummary)
    }

    func canCopyExport(format: ExportFormat) -> Bool {
        switch format {
        case .txt, .md, .obsidianMarkdown, .json, .srt, .rtf:
            return true
        case .docx, .legalPDF:
            return false
        }
    }

    func defaultLegalPDFHeader() -> String {
        guard let project else { return "TRANSCRIPT" }
        return Self.defaultLegalPDFHeader(title: project.title, recordingStartTime: project.audio.recordingStartTime)
    }

    func defaultLegalPDFOptions(
        includeSummary: Bool,
        headerText: String? = nil,
        showElapsedTime: Bool = true,
        showClockTime: Bool = false,
        includeCoverPage: Bool = false
    ) -> LegalPDFOptions {
        guard let project else { return LegalPDFOptions() }
        let loadedSummary = includeSummary ? (try? library.loadSummary(project.id)) : nil
        let todoText = loadedSummary?.todos.map { todo in
            let prefix = todo.isDone ? "[x]" : "[ ]"
            return "\(prefix) \(todo.text)"
        }.joined(separator: "\n")

        return LegalPDFOptions(
            showElapsedTime: showElapsedTime,
            showClockTime: showClockTime,
            recordingStartTime: project.audio.recordingStartTime,
            headerText: headerText ?? defaultLegalPDFHeader(),
            includeCoverPage: includeCoverPage,
            coverPageSummary: loadedSummary?.summary,
            coverPageActionItems: todoText,
            audioFileName: project.audio.originalURL.lastPathComponent,
            audioDuration: project.audio.durationSeconds,
            speakerNames: project.speakers.map(\.displayName).filter { !$0.isEmpty }
        )
    }

    private func renderActivePass(format: ExportFormat, includeSummary: Bool) -> String? {
        guard let project, let pass = activePassContent else { return nil }

        // Respect the current verbatim/clean toggle on export.
        let styledPass = Self.applyStyle(pass: pass, style: project.settings.transcriptStyle)

        let summary: SummaryDocument?
        if includeSummary {
            summary = try? library.loadSummary(project.id)
        } else {
            summary = nil
        }

        switch format {
        case .txt:
            return TranscriptExporter.plainText(project: project, pass: styledPass)
        case .md:
            return TranscriptExporter.markdown(
                project: project,
                pass: styledPass,
                summary: summary,
                includeSummary: includeSummary
            )
        case .obsidianMarkdown:
            return TranscriptExporter.obsidianMarkdown(
                project: project,
                pass: styledPass,
                summary: summary,
                includeSummary: includeSummary
            )
        case .json:
            guard let result = transcriptionResult(project: project, pass: styledPass),
                  let data = try? ExportService.formatJSON(result: result)
            else { return nil }
            return String(data: data, encoding: .utf8)
        case .srt:
            guard let result = transcriptionResult(project: project, pass: styledPass) else { return nil }
            return ExportService.formatSRT(result: result, speakerMapping: speakerMapping(for: project))
        case .rtf:
            guard let result = transcriptionResult(project: project, pass: styledPass) else { return nil }
            return ExportService.formatRTF(result: result, speakerMapping: speakerMapping(for: project))
        case .docx, .legalPDF:
            return nil
        }
    }

    private func exportData(
        format: ExportFormat,
        includeSummary: Bool,
        legalPDFOptions: LegalPDFOptions
    ) throws -> Data {
        guard let project, let pass = activePassContent else {
            throw ConsensusError.exportFailed("No active transcript is loaded.")
        }
        let styledPass = Self.applyStyle(pass: pass, style: project.settings.transcriptStyle)

        if let text = renderActivePass(format: format, includeSummary: includeSummary) {
            return Data(text.utf8)
        }

        guard let result = transcriptionResult(project: project, pass: styledPass) else {
            throw ConsensusError.exportFailed("Could not prepare transcript for export.")
        }
        let mapping = speakerMapping(for: project)
        switch format {
        case .docx:
            return try ExportService.buildDOCX(result: result, speakerMapping: mapping)
        case .legalPDF:
            return try ExportService.buildLegalPDF(result: result, speakerMapping: mapping, options: legalPDFOptions)
        case .txt, .md, .obsidianMarkdown, .json, .srt, .rtf:
            throw ConsensusError.exportFailed("Unexpected export format.")
        }
    }

    private func transcriptionResult(project: ProjectDocument, pass: TranscriptPass) -> TranscriptionResult? {
        TranscriptionResult(
            audioPath: project.audio.originalURL.path(percentEncoded: false),
            duration: project.audio.durationSeconds,
            segments: pass.segments
        )
    }

    private func speakerMapping(for project: ProjectDocument) -> SpeakerMapping {
        var mapping = SpeakerMapping()
        for speaker in project.speakers {
            mapping.rename(speaker.id, to: speaker.displayName)
        }
        return mapping
    }

    private static func defaultLegalPDFHeader(
        title: String,
        recordingStartTime: Date?
    ) -> String {
        var lines = ["TRANSCRIPT", title]
        if let recordingStartTime {
            let formatter = DateFormatter()
            formatter.dateStyle = .medium
            formatter.timeStyle = .short
            lines.append(formatter.string(from: recordingStartTime))
        }
        return lines.joined(separator: "\n")
    }

    // MARK: - Manual revision

    func manualRevisionText() -> String? {
        guard let project, let pass = activePassContent else { return nil }
        let styledPass = Self.applyStyle(pass: pass, style: project.settings.transcriptStyle)
        return TranscriptManualEditorCodec.serialize(
            segments: styledPass.segments,
            mapping: speakerMapping(for: project)
        )
    }

    @discardableResult
    func applyManualRevision(text: String) -> Bool {
        guard let project, let pass = activePassContent else { return false }
        let styledPass = Self.applyStyle(pass: pass, style: project.settings.transcriptStyle)
        let turns = TranscriptManualEditorCodec.parse(text)
        guard !turns.isEmpty else {
            report(ConsensusError.exportFailed("No valid speaker turns found. Keep headers like [SPEAKER @ 00:00]."))
            return false
        }

        let mapping = speakerMapping(for: project)
        let segments = TranscriptManualEditorCodec.rebuildSegments(
            from: turns,
            original: styledPass.segments,
            mapping: mapping,
            audioDuration: project.audio.durationSeconds
        )
        guard !segments.isEmpty else {
            report(ConsensusError.exportFailed("Manual revision did not produce any transcript segments."))
            return false
        }

        var updatedProject = project
        updatedProject.speakers = Self.mergeManualSpeakers(existing: updatedProject.speakers, segments: segments)
        updatedProject.activePass = .manual

        let manualPass = TranscriptPass(
            kind: .manual,
            segments: segments,
            engineAttribution: EngineAttribution(
                primaryEngine: "Manual Revision",
                supportingEngines: [pass.engineAttribution.primaryEngine].filter { !$0.isEmpty },
                diarizer: pass.engineAttribution.diarizer,
                language: pass.engineAttribution.language
            ),
            quality: pass.quality
        )

        do {
            try library.savePass(manualPass, for: project.id)
            self.project = try library.save(updatedProject)
            activePassContent = manualPass
            resolvedUncertaintyIndices = []
            return true
        } catch {
            report(error)
            return false
        }
    }

    private static func mergeManualSpeakers(
        existing: [Speaker],
        segments: [TranscriptionSegment]
    ) -> [Speaker] {
        var speakers = existing
        var known = Set(existing.map(\.id))
        for speakerID in segments.map(\.speakerID) where !known.contains(speakerID) {
            known.insert(speakerID)
            let displayName = speakerID
                .replacingOccurrences(of: "MANUAL_", with: "")
                .replacingOccurrences(of: "_", with: " ")
                .capitalized
            speakers.append(Speaker(
                id: speakerID,
                displayName: displayName,
                voiceLibraryID: nil,
                isConfirmed: true,
                paletteIndex: speakers.count
            ))
        }
        return speakers
    }

    /// Return a copy of `pass` whose `segments[].text` reflects the
    /// chosen style. When `.verbatim` is requested and a `StylePair` is
    /// present, substitute the Engine-A-derived verbatim text in.
    /// Clean mode (or passes without a style pair) returns the pass
    /// unchanged.
    private static func applyStyle(pass: TranscriptPass, style: TranscriptStyle) -> TranscriptPass {
        guard style == .verbatim,
              let styles = pass.styles,
              styles.isAligned,
              styles.verbatimText.count == pass.segments.count
        else { return pass }

        var copy = pass
        copy.segments = zip(pass.segments, styles.verbatimText).map { segment, verbatim in
            var s = segment
            s.text = verbatim
            return s
        }
        return copy
    }

    // MARK: - Settings mutators

    /// Mutators for the setup card's Speed / Include choices. They write
    /// back to `project.settings` and persist so the selections survive a
    /// close-and-reopen.
    func setSpeed(_ tier: SpeedTier) {
        let availableTier = (!PatchReviewRunner.isAvailable && tier != .standard)
            ? SpeedTier.standard
            : tier
        update { $0.settings.speed = availableTier }
    }

    func setEngine(_ engine: RewrittenEngineChoice) {
        update { $0.settings.engine = engine }
    }

    func setMode(_ mode: ModeState) {
        self.mode = mode
        // Mirror onto the project document so a close-and-reopen keeps it.
        if project != nil { update { $0.mode = mode } }
    }

    /// Build VibeVoice's `context=` hotwords from any speaker names already
    /// confirmed on the project. First-pass projects have no speakers yet,
    /// so context is nil; re-runs after the speaker-naming stage benefit
    /// from the names. Domain hint adds a small set of seed terms.
    private static func vibeVoiceContext(from project: ProjectDocument) -> String? {
        var pieces: [String] = []
        let names = project.speakers
            .filter { $0.isConfirmed }
            .map { $0.displayName.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("Speaker ") }
        pieces.append(contentsOf: names)
        switch project.settings.domainHint {
        case .legal:     pieces.append("court, deposition, mediation, arbitrator, counsel")
        case .medical:   pieces.append("patient, diagnosis, prescription, dosage")
        case .technical: pieces.append("API, SDK, repository, deployment")
        case .business:  pieces.append("revenue, quarter, stakeholder, roadmap")
        case .general, .custom:
            if case .custom(let text) = project.settings.domainHint, !text.isEmpty {
                pieces.append(text)
            }
        }
        let merged = pieces.joined(separator: ", ").trimmingCharacters(in: .whitespacesAndNewlines)
        return merged.isEmpty ? nil : merged
    }

    private static func settingsForLocalCapabilities() -> ProjectSettings {
        var settings = ProjectSettings()
        if !PatchReviewRunner.isAvailable {
            settings.speed = .standard
        }
        return settings
    }

    private static func normalizedForPatchReviewAvailability(_ document: ProjectDocument) -> ProjectDocument {
        guard !PatchReviewRunner.isAvailable, document.settings.speed != .standard else {
            return document
        }
        var normalized = document
        normalized.settings.speed = .standard
        return normalized
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

    func setSummaryLength(_ length: SummaryLength) {
        summary.length = length
        if let project { try? library.saveSummary(summary, for: project.id) }
    }

    func setSummarySpecialInstructions(_ text: String) {
        summary.specialInstructions = text
        if let project { try? library.saveSummary(summary, for: project.id) }
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
