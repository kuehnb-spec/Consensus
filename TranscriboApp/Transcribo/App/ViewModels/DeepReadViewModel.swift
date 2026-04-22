import Foundation
import Observation
import AVFoundation

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

    /// Kick off the import from a dropped audio URL. Validates the file,
    /// copies or links it into the project directory, persists a fresh
    /// `ProjectDocument`, and advances the stage to `.setup`.
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
            let document = ProjectDocument(
                title: title,
                audio: audio,
                mode: mode
            )
            let created = try library.create(document)
            self.project = created
            self.stage = .setup
        } catch {
            report(error)
        }
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
                suggestions: Self.buildSuggestions(from: updated.speakers)
            )
        } catch {
            report(error)
            stage = .setup
        }
    }

    /// Builds the suggestion list the naming screen binds to. Phase 1c.2 will
    /// enrich this with "Hi, this is X" intro scans and voice library matches.
    private static func buildSuggestions(from speakers: [Speaker]) -> [SpeakerSuggestion] {
        speakers.map { speaker in
            SpeakerSuggestion(
                id: speaker.id,
                suggestedName: speaker.displayName,
                voiceLibraryMatchID: speaker.voiceLibraryID,
                sampleClipURL: nil,
                confidence: speaker.isConfirmed ? 1.0 : 0.0
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
    /// Phase 1c.1: writes the confirmed names back into the project and
    /// advances directly to `.reviewing`. Phase 1c.2 will branch on Speed —
    /// when Deep, run Engine B + `LLMReconcileService` with the confirmed
    /// names as `knownSpeakerNames` before advancing.
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
            stage = .reviewing
        } catch {
            report(error)
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
        project = nil
        activePassContent = nil
        stage = .idle
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
