# Consensus (formerly BDK Transcribo) -- Project History

## The Idea

BDK Transcribo started from a straightforward need: a way to transcribe audio recordings locally, with speaker identification, without sending sensitive files to a cloud service. The goal was privacy-first transcription — everything processed on the user's own machine.

## Phase 1: The Python Prototype

The first version was built in Python using a Gradio web UI. It combined WhisperX (OpenAI's Whisper model) for speech-to-text with pyannote.audio for speaker diarization. The stack also included torch, torchaudio, python-docx, and ffmpeg. It worked — you could upload an audio file through a browser interface, and it would produce a transcript with speaker labels.

But the prototype had the typical friction of a Python ML project: heavyweight dependencies, environment management headaches, and a web UI that felt detached from the Mac desktop experience. It proved the concept, but it wasn't something you'd want to use daily.

This prototype is preserved in the `Legacy/PythonPrototype/` directory.

## Phase 2: Going Native with Swift

The decision was made to rebuild the entire application as a native macOS app using SwiftUI. This was a ground-up rewrite — not a port. The native app targets macOS 15+ and was designed from the start to feel like a proper Mac application, with a real Dock icon, menu bar integration, and keyboard shortcuts.

The core transcription engine switched to **WhisperKit** (a Swift-native Whisper implementation), paired with **FluidAudio** for an alternative ASR engine using Parakeet models. For DOCX export, the app uses ZIPFoundation to build Open XML files directly.

### Building the Foundation

The initial native app delivered the basic pipeline: select an audio file, run transcription, get a transcript with speaker labels. Export options were ambitious from the start — the app shipped with seven formats: plain text, Markdown, JSON, SRT subtitles, RTF, DOCX, and a specialized legal PDF format modeled after court reporter transcripts (25 lines per page, Courier 12pt, left-margin line numbers).

### Persistent Projects

Rather than treating each transcription as a one-off operation, the app evolved to support persistent projects. Each project saves to `~/Library/Application Support/BDK Transcribo/Projects/` as a JSON file containing audio metadata, transcription settings, speaker mappings, multiple transcription passes, export history, and quality metrics. This turned the app from a simple converter into a workspace.

### Deep Review and Multi-Pass Analysis

The most significant evolution was the introduction of **Deep Review** — the ability to run multiple, intentionally different transcription passes over the same audio and compare the results. The idea is that different engines (WhisperKit vs. FluidAudio's Parakeet) will disagree in places where the audio is ambiguous, and those disagreements highlight exactly the spots that need human attention.

Each pass produces quality metrics: word confidence, segment confidence, diarization quality, compression ratio, and log probability. Quality flags are generated automatically when metrics fall below thresholds, categorized by severity (low, medium, high).

### The Reconciliation Workspace

Deep Review naturally led to reconciliation — a manual workspace for comparing two transcription passes line by line. The interface shows differences categorized as aligned, punctuation-only, speaker disagreements, text disagreements, or missing segments. For each line, the user can choose the left (reference) pass, the right (candidate) pass, or type a manual edit. The result is a "consensus" pass that represents the best human-verified version of the transcript.

### Onboarding and Help (March 2026)

The most recent work added a welcome tour for first-time users, a built-in Help Center workspace, and a demo project pre-loaded with Standard, Deep Review, and Consensus passes so new users can explore the full workflow without needing their own audio file first.

## Where It Stands

As of March 2026, the app has completed its core feature set: persistent projects, multi-engine transcription, Deep Review with quality metrics, reconciliation workspace, onboarding, and help system. The codebase spans approximately 7,400 lines of Swift across 39 source files.

The roadmap ahead includes an interface overhaul with waveform visualization, search and filtering, hotspot navigation, better model and storage management in Settings, and eventually app signing and notarization for distribution.

## Technical Notes

- **Languages**: Swift 6.0, SwiftUI
- **Key Dependencies**: WhisperKit (v0.12.0+), FluidAudio (v0.12.3+), ZIPFoundation (v0.9.0+)
- **Platform**: macOS 15+
- **Build System**: Swift Package Manager
- **Includes headless smoke testing** via command-line flags for pipeline validation

---

### March 16, 2026 — Renamed to Consensus; Design System Foundation

Renamed the app from "BDK Transcribo" to "Consensus" across all user-facing strings, Package.swift, and the app entry point. Added dual-path migration in ProjectStore so existing projects under the old Application Support directory are still found. Created a comprehensive UI overhaul plan (UI-OVERHAUL-PLAN.md) covering 6 phases of visual redesign. Built the design system foundation: ConsensusTheme.swift (centralized colors, fonts, spacing, radii), ConsensusCardStyle.swift (glassmorphism card modifier replacing GroupBox), and ConsensusButtonStyles.swift (primary, secondary, ghost, and pill button styles). Applied dark mode and indigo accent (#6366F1) at the WindowGroup level. Updated SpeakerBadge and SegmentRow to use theme tokens. The name "Consensus" was chosen because the app's differentiating feature — multi-engine reconciliation — literally produces a consensus transcript.

### March 16, 2026 — Sidebar Redesign & Quality Dashboard Overhaul (Phases 2-3)

Rewrote the sidebar with date-grouped project library (Today/Yesterday/Last 7 Days/Older), StatusBadge showing reconciliation state, ConfidencePill with three-tier color coding, and a pulse animation on the Transcribe icon when the pipeline is running. Added `hasConsensus` and `hasMultiplePasses` to TranscriptionProjectSummary. For the Quality Dashboard, created two new components: CircularProgressGauge (custom arc via Circle().trim with red/amber/green tier coloring and SF Mono center label) and DisagreementHeatmapView (horizontal timeline bar using GeometryReader for proportional segment positioning, with a four-item legend). Rewrote QualityView.swift entirely — replaced all GroupBox with .consensusCard(), swapped flat metric cards for circular gauges, added the heatmap to the comparison section, and themed every element through ConsensusTheme. All three phases (0, 1, 2, 3) now build clean.

### March 16, 2026 — Reconciliation Workspace Redesign (Phase 4)

Rewrote the reconciliation workspace from a 4-column comparison table into a unified single-column document stream. Aligned blocks are now compact cards showing speaker badge and text in dimmed style. Disagreement blocks expand into full cards with a header bar (timestamp, difference badge, status, play button), two source panels with inline diff highlighting via the existing LCS algorithm, and a consensus editor at the bottom with Use A / Use B buttons showing keyboard shortcut keys. Created the FloatingAudioController component — a bottom bar using `safeAreaInset(edge: .bottom)` that shows play/stop state, current playback timestamp, and keyboard shortcut hints rendered as styled key caps. Added keyboard-first navigation via `.onKeyPress` (macOS 14+): [1] selects reference, [2] selects candidate, [Space] toggles audio playback, [Up/Down] moves between rows, [Return] jumps to next unresolved disagreement with wrap-around. Updated ReconciliationSourceChoice display names from "Left"/"Middle" to "Reference"/"Candidate" to match the new layout language. Added solid diff tint colors to ConsensusTheme alongside the existing 15%-opacity background variants. Phases 0-4 all build clean.

### March 18, 2026 — LLM Polish, Reconciliation Fix, Export Fix

Added local LLM-powered transcript cleanup and summarization via Apple's mlx-swift-lm framework. Three tiered Qwen 3.5 models (4B/9B/27B) auto-selected based on system RAM — all run fully on-device via MLX on Apple Silicon, no cloud services or signups required. Created PolishView with model selection, task picker (cleanup only, summarize only, or both), and a split-pane result viewer with copy button. Fixed reconciliation false discrepancies caused by different engines splitting speech into different numbers of segments: added a pre-merge step that collapses consecutive same-speaker segments before alignment, eliminating the visual noise of "5 lines vs 0 lines" when the text was actually identical. Fixed the export dialog showing as an "Open" panel instead of a "Save" panel — single-format exports now use NSSavePanel with proper filename field, multi-format exports use NSOpenPanel configured as a directory picker. Added CleanupModel enum, TranscriptCleanupService actor, and wired everything through the sidebar as a new "Polish" phase.

### March 19, 2026 — Renamed to Consensus, SpeakerKit Integration, Process Log

Officially renamed the app from "BDK Transcribo" to "Consensus" across the entire codebase: Package.swift, build-app.sh, Info.plist (bundle ID, display name, executable), desktop shortcut, error types, smoke runner. Added backward compatibility for the old "BDK Transcribo" Application Support directory so existing projects are preserved.

Integrated Argmax SpeakerKit (pyannote v4 on CoreML) as the primary diarization engine, bumping WhisperKit from 0.12.0 to 0.17.0. SpeakerKit uses newer models than FluidAudio's community-1 pipeline and has published benchmark parity with pyannote at 10x speed. Created SpeakerKitDiarizationService that handles audio loading as 16kHz mono PCM and wraps the SpeakerKit API. The DiarizationService now coordinates both engines: SpeakerKit runs as primary with extra vote weight, FluidAudio runs secondary passes at different thresholds for cross-engine comparison. Users can select their diarization engine in the Transcribe setup screen.

Redesigned the deep diarization pipeline to use multi-engine comparison (SpeakerKit + FluidAudio) instead of FluidAudio-only multi-threshold passes, giving genuinely independent diarization results that catch different types of errors.

Built a modular floating Process Log window (ProcessLogView) with a split-pane design: left pane shows timestamped task entries with color-coded severity levels (info, progress, success, warning, error, AI thinking); right pane shows live output — transcription text scrolling in real-time during WhisperKit processing, and token-by-token LLM generation during Polish/cleanup. Added streaming support to TranscriptCleanupService using MLX Swift LM's `streamResponse` API, so AI output appears character-by-character in the output pane. The log auto-scrolls, can be collapsed/expanded, cleared, and closed. Wired into the transcription pipeline, deep diarization, Polish, and reconciliation flows. Accessible via a "Process Log" toggle in the sidebar's new Tools section. The live transcription text that previously only appeared in the main window's progress area now also feeds into the output pane, and the main window's inline transcription preview was kept as-is for backward compatibility.

### March 16, 2026 — Export Suite & Polish Pass (Phases 5-6)

Completed the final two phases of the UI overhaul. For the Export Suite, themed ExportView and ExportFormatCard with ConsensusTheme tokens, replaced the GroupBox with .consensusCard(), and added a live PDF preview pane: when Legal PDF format is selected, an HSplitView reveals a PDFKit-based PDFView on the right showing the generated document. Preview regenerates when options change (500ms debounce on header text to avoid lag) and runs on a detached task to keep the UI responsive. For the Polish Pass, applied ConsensusTheme to all remaining views: TranscriptionSetupView (GroupBox to .consensusCard, mono fonts for steppers), AudioDropZone (accent/surfacePrimary/textMuted/accentMuted tokens replacing raw colors, dashed border uses theme), TranscriptView (mono timestamps, surfacePrimary speaker panel, themed SpeakerRenameCard), HelpCenterView (.regularMaterial to .consensusCard() with .ultraThinMaterial, updated help text to match new reconciliation UI language), WelcomeTourView (replaced raw tint colors with theme colors, .ultraThinMaterial + border, full text theming), and SettingsView (updated About section with "Consensus" name). All six phases of the UI overhaul are now complete and building clean. Zero hardcoded colors remain in the view layer.

### March 19, 2026 — Workflow Redesign: Guided Sidebar, Summary Tool, Polish-in-Export

Redesigned the sidebar from a flat menu into a guided numbered workflow: (1) Transcribe, (2) Review & Rename Speakers, (3) Deep Review (optional), (4) Reconcile (with "recommended" badge when available), (5) Export. Each step shows a numbered circle that turns into a green checkmark when complete. Created a new WorkflowStepRow component with step numbers, completion state, pulse animation, and optional badges. Removed Polish as a standalone navigation phase — transcript cleanup is now folded into ExportView as an optional "Polish Before Exporting" toggle with model selection, run button, and a preview panel showing the polished result. Summary was extracted into its own always-available tool (SummaryView) accessible from the sidebar's Tools section at any time once a transcript exists, so users can generate action-item summaries for colleagues without waiting for the final transcript. Added dedicated `runSummary()` method and state variables to TranscriptionViewModel. PolishView.swift is now dead code (kept for reference but no longer referenced from navigation).
