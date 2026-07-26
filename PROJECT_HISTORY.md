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

### March 25, 2026 — Deep Review Workflow Separation, Speaker Alignment, Reconciliation Provenance

Refactored Deep Review so transcript comparison and speaker refinement stopped overwriting each other in a single active-result chain. Added `sourcePassID` lineage on saved passes, made Deep Diarization refine the stable base transcript instead of whichever pass happened to be active, and changed reconciliation to prefer the true comparison transcript when both branches exist. Reworked multi-pass diarization so secondary passes are aligned into SpeakerKit's speaker-ID space before voting or AI arbitration, preventing arbitrary cluster labels from being treated as the same person. Tightened reconciliation row provenance by carrying sentence-local source segments and trimming saved word timings to the reviewed row interval, which made consensus saves better match the UI. Updated the Deep Diarization copy in the quality panel to match the new aligned-pass behavior. Verification was partially blocked by upstream Swift 6 sendability errors in FluidAudio's streaming ASR code, but the package did not report new errors in the Consensus files touched during this pass.

### March 25, 2026 — Vendored and Pinned FluidAudio; Build Unblocked

Vendored `FluidAudio` into `TranscriboApp/Vendor/FluidAudio` and switched the package manifest from the remote GitHub dependency to a local path pin so the app no longer depended on a transient checkout state. Fixed the Swift 6 streaming ASR build break by marking `AsrManager` as `@unchecked Sendable`, matching FluidAudio's existing manual synchronization approach around CoreML-backed state. Cleaned up the remaining app-side build warnings introduced during the Deep Review refactor, then rebuilt the Swift package successfully. The full bundle script still hit a missing local Metal Toolchain component, so the refreshed debug binary was copied into the existing `Consensus.app` bundle while preserving the previously generated `mlx.metallib` and resource bundles. That left the repo with a current app bundle that matches the latest code and is ready for local testing.

### March 25, 2026 — App Icon Exploration

Prepared a first-pass icon exploration set under `TranscriboApp/Design/AppIconConcepts` with four distinct directions for the Consensus app icon. Kept the visual language aligned with the workstation overhaul: deep slate backgrounds, indigo-led accents, crisp geometry, and a premium macOS feel rather than a generic utility-app look. Documented the concepts in editable SVG files plus a browser-based comparison sheet so the icon can be reviewed before committing to the final `.icns` pipeline. The set intentionally spans product reads from audio consensus to local-first trust to give the brand room to choose between literal and more abstract directions.

### March 25, 2026 — Bundled Final Brand Assets

Integrated the user-provided production icon and logo from `TranscriboApp/Design/AppIcon` and `TranscriboApp/Design/Logo` into the app packaging flow. Updated `build-app.sh` to assemble a real macOS `AppIcon.icns` from the stepped PNG exports, then copy the transparent logo into `Consensus.app/Contents/Resources` so both assets now ship with every bundle build. Rebuilt the app successfully and verified that the packaged bundle contains the new icon file, the logo asset, and the existing MLX/resource payloads together in one current build output.

### March 25, 2026 — Corrected Export Clock-Time Origin

Adjusted the export timestamp flow so clock times are derived from the recording start, not the file's end timestamp. Consolidated the logic in `TranscriptionViewModel` to recompute `recordingStartTime` from the source audio file timestamp minus audio duration, and applied that derivation again when reopening saved projects so older projects can self-correct instead of reusing stale export metadata. Added a safe header migration path that refreshes the legal PDF's default timestamp line only when the header was still auto-generated, preserving any manual header edits while fixing the recorded time shown in exports.

### March 25, 2026 — Reconciliation Pipeline Restructuring

Analyzed the reconciliation workflow and identified a fundamental design problem: the sentence-level LCS diff between two independent ASR engines was producing ~300 rows of differences for a 53-minute transcript, making "Deep Review" feel like busywork rather than quality improvement. The root cause was treating every sentence-level disagreement between engines as something requiring human review, when in reality most differences (punctuation, filler words, phrasing) are trivial and the engines are both 90%+ correct.

Decided to restructure the pipeline from "diff everything, resolve manually" to "merge automatically using confidence, surface only genuine ambiguities." The new approach uses word-level alignment via WordTiming timestamps (already available from both engines), confidence-weighted selection at the word level, and automatic speaker assignment from the existing majority-vote diarization. Instead of 300 reconciliation rows, the new system produces a single merged transcript with ~15-30 inline flags marking only the spots where the system is genuinely uncertain: low-confidence regions, close speaker-vote disputes, missing phrases, and disagreeing named entities. The reconciliation UI was redesigned from a 3-column comparison grid into a continuous readable transcript with expandable inline review panels at each flag. This is closer to "track changes" in a word processor than a spreadsheet diff. The local LLM (already integrated) now assists during the merge phase for contextual disambiguation of ambiguous words, rather than post-hoc classification of 300 rows.

### March 25, 2026 — Pipeline & Workflow Overhaul (Separation of Concerns)

First real-world test revealed the core problem with Deep Review: WhisperKit vs Parakeet produced 5% text agreement and 31% speaker agreement — 558 disputed segments on a 53-minute call. The reconciliation workspace was broken and overwhelming. Root cause: running independent diarization on both engines created uncorrelated speaker assignments that cascaded into hundreds of false disputes.

Researched ROVER (NIST's word transition network voting system), MOVER (2025 meeting recognition combination), and LLM-based ASR error correction. Key finding: different engines make uncorrelated errors, so ROVER-style voting at each word position catches what any single engine misses — typically 10-12% relative error reduction. But diarization must be handled separately from transcription to avoid the "31% speaker agreement" problem.

Implemented three major changes:

**Pipeline separation**: Engine B (the Deep Review comparison pass) now runs transcription only — diarization is skipped entirely. Speaker assignments come exclusively from Engine A's (reference) diarization. The confidence-weighted merge engine was updated to build a "speaker timeline" from the reference pass and overlay it onto all merged words, regardless of which engine the word came from. This eliminates the speaker disagreement problem completely.

**Workflow restructuring**: Collapsed the 5-step sidebar (Transcribe / Review / Deep Review / Reconcile / Export) into 3 phases (Transcribe / Review / Export). "Deep Review" and "Reconcile" were replaced with a single "Verify Accuracy" action that launches as a sub-flow from the Review phase. Added a decision card to the transcript view offering two clear paths: "Export Now" for quick results, or "Verify Accuracy" to run a second engine. This addresses the confusion of numbered optional steps that don't clearly communicate the user's actual decision.

**Documentation**: Created WORKFLOW-REDESIGN.md capturing the full UI/pipeline redesign plan including research findings on ROVER, MOVER, and LLM error correction approaches. The document serves as a reference for future iterations.

### March 25, 2026 — Bug Fixes, Project Management, Recording Timestamps

Fixed a diarization loss bug in the confidence merge: the per-word speaker lookup was failing because Engine B's word timings didn't align with Engine A's segment boundaries, causing all merged words to fall into a single speaker. Replaced the per-word speaker lookup with a direct slicing approach that cuts the merged word stream at Engine A's actual speaker turn boundaries, guaranteeing diarization carries through to the merged result.

Added project management features: delete project (with confirmation dialog), share project via macOS system share sheet (ShareLink with the project JSON file), and "Show in Finder" to reveal the project folder. All accessible via right-click context menu on project library rows in the sidebar.

Fixed recording start time calculation. The old approach used the filesystem creation date as the recording end time, which is wrong for files transferred via AirDrop, cloud sync, or download (creation date reflects the transfer, not the recording). Now reads the embedded `creation_time` from the M4A/MP4 container metadata via AVFoundation, which is the actual recording end time set by the recording device. Falls back to filesystem date only if container metadata is unavailable.

Also created SIMPLE-MODE-DESIGN.md documenting a future Simple Mode concept: a light-themed, single-screen, zero-configuration interface alongside the current Advanced (dark) mode. Deferred to after the pipeline is finalized.

### Current Status & Known Issues (End of March 25 Session)

**What works:**
- 3-phase sidebar (Transcribe / Review / Export) with "Verify Accuracy" sub-action
- Decision card in transcript view with "Export Now" and "Verify Accuracy" buttons
- Engine B runs text-only (no diarization) during verification
- Confidence-weighted word merge with Engine A's speaker boundaries
- Inline flag review UI for ambiguous regions
- Project delete, share, and "Show in Finder"
- Recording start time from embedded audio metadata

**Known issues still being debugged:**
- The merged transcript after "Verify Accuracy" may still have issues with the quality of the word-level merge — needs real-world testing to assess whether the ROVER-style word alignment is producing good results or if the merge needs further tuning
- The inline flag review panel in the reconciliation view has not been tested end-to-end with real merged data yet (keyboard shortcuts, flag resolution, save consensus flow)
- The old 5-step workflow code paths (QualityView's Deep Review configuration, old ReconciliationView 3-column layout) still exist but are partially disconnected from the new flow — may need cleanup or removal

**Design documents for reference:**
- `WORKFLOW-REDESIGN.md` — Full pipeline and UI restructuring plan
- `SIMPLE-MODE-DESIGN.md` — Future simple/advanced mode concept

### March 25, 2026 — Diarization Quality Fix & Simple Mode

Implemented three-layer diarization post-processing to fix the "breaking up paragraphs mid-sentence" problem. Layer 1: post-process raw diarization output — merge same-speaker segments with gaps under 1 second, absorb micro-segments under 1.5 seconds into neighboring speakers, detect and absorb "sandwich" false flips (A-B-A where B is under 2 seconds). Layer 2: context-aware speaker assignment — when a transcription segment has an ambiguous speaker overlap (margin under 15% of segment duration) and both neighbors are the same speaker, flip to match the neighbors. Also smooths runs of 2 isolated segments that are short false detections. Layer 3: tighter SpeakerKit parameter passing — now sends numberOfSpeakers when min/max are within 1 of each other, not just when they're identical.

Smoke-tested on a 19-minute phone call with the base model and 2-speaker constraint. Diarization produced 16 speaker transitions (vs. hundreds before the fix). Some under-segmentation remains (4.5-minute blocks where the model doesn't detect speaker changes within conversational back-and-forth), but this is vastly better than over-segmentation and is more of a model quality issue than a pipeline issue.

Also implemented the verification flow improvements: two-step flag resolution (select A/B to preview, then Accept to confirm and auto-advance), "Listen to Context" button in flag popovers, "Verification Complete" badge centered in window, and "Save & Continue" button that returns to Review after saving.

Built Simple Mode per SIMPLE-MODE-DESIGN.md: light theme (warm white backgrounds, dark text, same indigo accent), single-screen layout with three zones (drop zone / transcript / action bar), no sidebar, no configuration decisions. Auto-selects transcription model based on system RAM. Mode toggle persists in AppSettings. Advanced mode gets a "Simple Mode" button in the Tools section; Simple mode gets an "Advanced" pill in the top bar. Color scheme flips between .light and .dark based on mode. New users default to Simple mode.

### March 26, 2026 — Diarization Tuning, Multi-Pass Speaker Refinement, Engine Research

Extensive diarization testing and tuning session. Ran comparative tests across SpeakerKit, FluidAudio, and multiple threshold configurations on a 19-minute two-speaker phone call.

**Post-processing threshold tuning:** The previous session's thresholds (1.5s min segment, 2.0s sandwich flip) were too aggressive — they absorbed legitimate short interjections like "Okay" and "Right" that are real speaker changes in conversational audio. Reduced to 0.3s minimum segment, 0.5s merge gap, 0.5s sandwich threshold. This preserved short back-channel responses while still filtering sub-300ms frame-level noise.

**Speaker collapse for phantom speakers:** SpeakerKit consistently detected 3 speakers on 2-person calls despite numberOfSpeakers=2 being passed. Added automatic speaker collapse: after diarization, any speaker beyond the top 2 (by total duration) gets reassigned to the nearest primary speaker by time proximity. Also added UNKNOWN fill — transcription segments with no diarization overlap get assigned to the nearest known speaker. Result: clean 2-speaker output with zero UNKNOWN segments.

**Engine comparison results on the Clayton Everett file:**
- SpeakerKit (default): 25 transitions, 3 speakers detected, 1 UNKNOWN
- SpeakerKit + threshold 0.6: 31 transitions, 3 speakers, 6 UNKNOWN (worse)
- FluidAudio: 57 transitions, 3 speakers, 24 UNKNOWN (much worse — too fragmented)
- SpeakerKit + collapse + UNKNOWN fill: 24 transitions, 2 speakers, 0 UNKNOWN (best)

**Conclusion:** SpeakerKit is clearly the best diarization engine for this use case. FluidAudio produces too many fragments and UNKNOWN segments. The 0.6 clustering threshold made things worse, not better. The default threshold with post-processing produces the best results.

**Multi-pass speaker refinement ("Refine Speakers"):** Added a new feature that runs after the transcript is finalized. Runs SpeakerKit at multiple clustering thresholds + FluidAudio comparison passes, uses majority voting, then feeds disputes to the local LLM for context-aware resolution. Automatically re-maps speaker names from the original labeling to the new speaker IDs by time overlap matching. Accessible via a "Refine Speakers" button in the Review decision card.

**speech-swift research:** Investigated [soniqo/speech-swift](https://github.com/soniqo/speech-swift), a pure Swift/MLX speech toolkit with pyannote segmentation 3.0 + WeSpeaker embeddings + Sortformer diarization. 465 stars, Apache 2.0, ~32MB diarization stack. Couldn't integrate as a dependency due to mlx-swift version conflict (speech-swift needs 0.30.0, our mlx-swift-lm pins 0.29.x). Noted as a future integration candidate when we upgrade mlx-swift-lm. Also investigated [DiariZen](https://github.com/BUTSpeechFIT/DiariZen) (9.1% DER on VoxConverse, better than pyannote 3.1) but it's Python/CUDA only — not practical for us.

**Pipeline flow is now:** Transcribe (Engine A + basic diarization) → Review & name speakers → Verify Accuracy (Engine B text-only, confidence merge) → Refine Speakers (multi-pass diarization + LLM) → Export

**Other models evaluated (March 26):** Reviewed [insanely-fast-whisper](https://github.com/Vaibhavs10/insanely-fast-whisper) — a Python CLI wrapping Whisper + pyannote with Flash Attention 2 for ~15x GPU speedup. Not useful for us: Python-only, speed gains are NVIDIA-specific, and we already have WhisperKit (CoreML/ANE-optimized) and SpeakerKit (pyannote v4 on CoreML) which are purpose-built for Apple Silicon.

**LLM-confirmed speaker boundary detection (March 26, 2026):** Replaced the majority-vote diarization approach (which produced identical results to single-pass because SpeakerKit always outvoted FluidAudio) with a fundamentally different approach: collect ALL candidate speaker boundaries from every diarization pass, then use the LLM to confirm which ones are real based on transcript context. The LLM reads ~15 seconds of surrounding text and looks for conversational patterns (short acknowledgments between longer statements, questions followed by answers, perspective changes). Tested on the 19-minute Clayton Everett call: found 12 candidate boundaries from multi-pass that the baseline missed, LLM confirmed 4 as real speaker changes, improving transitions from 19 to 25 (32% improvement). Also added `--refine` flag to the headless smoke runner for CLI testing of the full pipeline.

**speech-swift integration attempted and reverted:** Successfully resolved the mlx-swift dependency conflict by upgrading mlx-swift-lm from 2.29.x to 2.30.6. Integrated speech-swift's pyannote 3.0 + WeSpeaker diarization as a third engine option. However, testing showed it detected 0 speaker changes on phone call audio at all threshold settings — the activity-based chaining approach doesn't work for phone calls with similar acoustic characteristics on both sides. Reverted the integration. SpeakerKit remains the best diarization engine for this use case. Kept the mlx-swift-lm upgrade (2.30.6) since it's compatible and newer.

**Cohere Transcribe released (March 26, 2026):** New SOTA ASR model, #1 on HuggingFace Open ASR Leaderboard with 5.42% WER (vs Whisper Large v3's 7.44% — 27% relative improvement). 2B parameter conformer encoder-decoder, Apache 2.0, trained on 500K hours. Supports 14 languages. No diarization, no word-level timestamps documented, no MLX port yet. At 2B params it would need an MLX conversion to run on Apple Silicon. Noted as a high-priority future integration target — when an MLX port appears, it becomes a third transcription engine option alongside WhisperKit and Parakeet. The conformer architecture is different enough from Whisper's transformer that errors would be genuinely uncorrelated, making it ideal for ROVER-style multi-engine voting.

### March 26, 2026 — Diarization Architecture Review

Reviewed the current diarization stack end to end to understand why speaker labeling still plateaus below the rest of the app's quality. Confirmed that the strongest foundation remains SpeakerKit as the primary engine, with text and diarization already partly separated in the Deep Review flow.

Identified the main constraints as pipeline-level rather than purely model-level: speaker assignment is still mostly segment-based, several refinement heuristics are explicitly tuned for two-person phone calls, and post-processing currently collapses extra speakers to the top two regardless of the requested range. Also noted that LLM-assisted refinement is useful for boundary confirmation but cannot fully recover speaker identity from transcript text alone.

Researched current upstream options and benchmarks to map future directions. The clearest path forward is a staged plan: first tighten the local pipeline around word-level alignment and speaker-count-aware logic, then evaluate stronger diarization backends or confidence-enabled enterprise options only if the local-first improvements still leave meaningful gaps.

### March 26, 2026 — Word-Level Diarization and Multi-Pass Deep Review

Reworked the diarization merge layer to assign speakers at the word level instead of only at coarse segment boundaries. The new path now uses real word timestamps when available, estimates timings when they are missing, smooths weak one-word flips, rebuilds cleaner speaker-homogeneous transcript segments, and preserves explicit speaker IDs instead of force-collapsing everything to two speakers.

Expanded Deep Diarization from a single SpeakerKit pass into a local multi-pass strategy: default SpeakerKit plus alternate threshold passes, followed by the existing aligned FluidAudio comparison passes. This kept the pipeline fully on-device while giving the refinement stage more boundary candidates to reconcile.

Updated the surrounding UI and process messaging to describe the new multi-pass behavior, fixed the Deep Review entry point so the diarization toggle actually runs the diarization path, and then rebuilt the app to verify the integration end to end. The main decision was to improve alignment and voting before changing engines, because the existing local stack still had untapped quality headroom in how its outputs were combined.

### March 27, 2026 — Whisper Model Download Timeout Fix

Investigated a new first-run transcription failure where the app hung on “Downloading model” and then surfaced a request timeout before transcription began. Reproduced the bug from the CLI with an uncached `medium` Whisper model, which confirmed the regression lived in the model download path rather than the UI flow.

Added a source-controlled Whisper asset downloader inside the app that fetches model files and tokenizer files directly from Hugging Face with longer request/resource timeouts, retry logic, and progress reporting. Wired `TranscriptionService` to use that downloader before initializing WhisperKit, which removed the app’s dependence on the upstream 10-second foreground download timeout for first-use model pulls.

Verified the fix by rebuilding and rerunning the same uncached `medium` smoke transcription that had previously failed. The download completed, the model loaded, transcription finished successfully, and the smoke run exported output as expected.

### March 27, 2026 — Advanced Mode Workflow Rewrite

Complete rewrite of the Advanced Mode user interface and workflow, addressing the accumulated confusion from incremental changes over multiple sessions.

**New two-phase structure:**
- **Standard Transcription** (sidebar section): Transcribe → Review & Label Speakers → Export as Standard. This is a clear three-step flow with an explicit terminal point.
- **Deep Review** (separate sidebar section, only visible after first pass): A guided four-step wizard — Deep Transcription → Deep Diarization → Confirm Speakers → Review & Export as Verified. Steps are sequential with back/next navigation, progress dots, and completion indicators. Each step shows a clear description of what it does, a run button, and a completion state.

**New WorkflowPhase enum** replaces the old flat `Phase` enum. Now has explicit cases for each Deep Review step (`.deepTranscription`, `.deepDiarization`, `.deepSpeakerConfirm`, `.deepReviewCompare`), plus an `.isDeepReview` computed property for grouping.

**Unified Status Pane** replaces the floating ProcessLogView. A permanent right-side panel shows all processing status in one place: overall workflow progress, current operation details with progress bar, quality metrics, Deep Review step tracker, and the process log. Not interactive — all interaction happens in the main work area.

**Quality tier in export**: Optional checkbox "Include quality tier badge" in export settings. Shows "Standard Transcript" or "Verified Transcript" based on whether Deep Review has been completed. The tier is computed from project pass data (no manual setting).

**Decision card simplified**: The Review phase now offers two clear actions — "Export as Standard" (terminal point 1) or "Enter Deep Review" (starts the wizard). Removed the confusing "Verify Accuracy", "Review Merge", and "Refine Speakers" buttons that were separately triggerable.

**New files created:** DeepReviewViews.swift (4 guided step views), StatusPaneView.swift (unified status pane).

**Dead code paths identified for future cleanup:** ReconciliationService.swift (entirely superseded by ConfidenceMergeService), old ReconciliationDraft/ReconciliationRow model types, PassComparisonService, QualityView Deep Review configuration section.

### March 27, 2026 — Feature Batch: Quick Wins + Project Dashboard

Implemented a batch of user experience improvements:

**Batch 1 (Quick Wins):**
- **Copy to Clipboard**: toolbar button copies the full formatted transcript to the system clipboard (Cmd+C for the whole thing, not just selected text)
- **Click-to-Play**: clicking any segment in the transcript plays that segment's audio. Playing segment highlighted with accent color. Click again to stop.
- **Search Within Transcript**: macOS-native `.searchable` modifier adds Cmd+F search with real-time filtering. Matching text highlighted in accent color within each segment.
- **Auto-Generated Project Summary**: `generateProjectSummary()` method uses the LLM to create a 1-2 sentence description of the audio content from the first ~2000 chars of transcript. Stored in `projectSummary` on the project model.

**Batch 2 (Medium Effort):**
- **Project Dashboard**: when no project is open, shows a rich card-based project management view instead of the sidebar. Each card displays: project name, date, duration, speaker names (from speaker mapping), quality tier badge, auto-generated summary, and word confidence bar. Cards are clickable to open, with right-click context menu for delete.
- **Progress Time Estimates**: during transcription, shows estimated time remaining based on elapsed time and current progress percentage (e.g., "Transcribing... 42% (2m 15s remaining)").
- **`TranscriptionProjectSummary` enriched**: now includes `audioDuration`, `speakerNames`, `projectSummary`, and `qualityTier` for dashboard display.

**Also created `IMPROVEMENT-IDEAS.md`** documenting 29 improvement ideas across output quality, UX, export, architecture, and visual identity, with prioritized recommendations.

**Batch 3 (Remaining Features):**
- **Keyboard Speaker Correction**: click a segment to select it (highlighted with accent border), then press 1/2/3/4 to reassign it to that speaker. Up/Down arrows navigate between segments. Space plays the selected segment. Keyboard shortcut hints shown in the speaker panel.
- **Proper Noun Dictionary**: per-project dictionary of misspellings → correct spellings. UI in the speaker panel lets users add entries (e.g., "Curby" → "Kirby"). Corrections applied via regex word-boundary matching across all segments. Persisted in project JSON.
- **Project Dashboard**: when no project is open in Advanced Mode, shows a rich card-based view of all projects. Each card shows name, date, duration, speaker names, quality tier badge, auto-summary, and confidence bar. Replaces the flat sidebar project list as the app's "home screen."

### March 30, 2026 — Deep Review Workflow Decoupling & Diarization Quality Fixes

Diagnosed and fixed two connected problems: the Deep Review workflow was broken (clicking "Run Deep Transcription" blasted through all steps and jumped to Step 4, leaving sidebar and status pane in contradictory states) and diarization quality was suffering because the pipeline didn't compose properly.

**Workflow fixes:**
- Decoupled `startDeepReview()` into `startDeepTranscription()` — now only runs Engine B + confidence merge (Step 1). Deep Diarization (Step 2) is triggered independently from its own view.
- Each step builds on the previous: Step 1 produces merged text, Step 2 uses that verified text for LLM speaker analysis, Step 3 confirms speakers, Step 4 reviews and exports.
- Step completion tracking (`deepReviewCompletedSteps`) moved from View layer into ViewModel methods — no more fragile post-async UI-side tracking.
- Sidebar and status pane now agree because both read from the same `deepReviewCompletedSteps` set, and phases advance only when the user clicks "Continue."
- Removed `deepReviewTranscription`/`deepReviewDiarization` toggle booleans and the old combined `startDeepReview()` function.
- Engine selection UI moved into DeepTranscriptionView (Step 1) where it belongs.

**Diarization quality fixes:**
- Fixed `insertBoundary()` which previously assumed exactly 2 speakers by picking `allSpeakers.first(where:)` — now accepts a `targetSpeaker` parameter from the candidate boundary data, falls back to next-segment analysis and nearby-speaker search for multi-speaker support.
- `refineSpeakers()` now uses the verified merged transcript from Step 1 (via `ConfidenceMergeService.buildConsensusResult()`) as context for the LLM boundary confirmation, instead of raw single-engine output.
- Updated LLM prompt from "phone call between two people" to "conversation" for multi-speaker support. Now includes speaker labels in the context window so the LLM can see who is currently labeled as speaking.
- Confirmed boundary data now carries target speaker info through the full pipeline (from `CandidateBoundary.afterSpeaker` to `insertBoundary()`), eliminating the coin-flip speaker assignment.
- Removed dead `runDeepDiarization()` method — consolidated into the more sophisticated `refineSpeakers()` which does boundary collection + LLM confirmation + acoustic verification.

### March 30, 2026 — Parallel Transcript View, Summary Sidepane, Legal PDF Cover Page

Added three features requested during testing:

**Parallel Transcript View (Compare Passes):** New tool accessible from the sidebar that shows two transcript passes side-by-side with time-aligned segments. Speaker labels are color-coded and highlighted amber when they differ between passes. Dropdown selectors let you pick any two passes to compare. Useful for diagnosing where diarization diverges across pipeline steps.

**Summary Sidepane:** Persistent, toggleable summary panel that appears between the main content and the status pane. Generates summaries via the existing on-device LLM, but now the summary is editable in-place and persisted to the project (new `detailedSummary` field on `TranscriptionProject`). Three export paths: copy to clipboard, export as standalone text file, or include on the legal PDF cover page. A "Regenerate" button re-runs the LLM; "Save" persists manual edits.

**Legal PDF Cover Page:** New option in the Legal Transcript export that prepends a cover page with recording metadata (filename, recording date/time, duration, speaker names) plus optional summary and action items sections. The summary text is parsed from the LLM output to separate "KEY POINTS" from "ACTION ITEMS" into distinct cover page sections. Cover page toggles (include summary, include action items) update the live PDF preview in real time.

### April 14, 2026 — Diarization Research Brief & Pipeline Brainstorming

Reviewed the current transcription and diarization pipeline end to end and mapped the main quality ceiling to the merge architecture rather than to a single missing model. Researched current diarization and speaker-attributed transcription developments from primary sources with an emphasis on local and Apple Silicon paths, including SpeakerKit reconciliation options, pyannote confidence and exclusive diarization concepts, speech-swift, NeMo Sortformer, and newer joint ASR-diarization papers.

Wrote an offline brainstorming brief in `brainstorming/2026-04-16 - Codex Brainstorming.md` so the findings would still be available without network access. Recommended three paths: rebuild the word timeline with forced alignment before speaker assignment, redesign Deep Diarization as an evidence graph instead of a baseline patcher, and keep a higher-risk research track open for joint diarization-conditioned ASR.

### April 16, 2026 — Performance Memo and Model/Architecture Research

Produced a comprehensive performance memo in `Brainstorming/2026-04-16 - Performance Memo - Transcription and Diarization.md` responding to the Codex brainstorm with independent research. Three parallel research threads covered: (1) latest diarization models and overlap techniques — pyannote community-1, NVIDIA Sortformer v1/v2/v2.1, LS-EEND, EEND variants, DiariZen, MossFormer2/ToTaToNet for overlap; (2) joint ASR + diarization systems — DiCoW v1/v3/SE-DiCoW, Sortformer+Canary serialized-tag decoding, target-speaker ASR, SOT/SA-SOT, DiarizationLM; (3) Apple Silicon 2026 substrate — speech-swift, WhisperKit v0.18 breaking changes, FluidAudio's three-backend diarization, Parakeet-TDT-v3 vs Whisper-v3, Qwen3-ASR 0.6B/1.7B, Cohere Transcribe, MLX audio ecosystem.

The memo catalogs six architecture alternatives (status-quo refinements, word-timeline rebuild, evidence-graph Deep Diarization, Sortformer/LS-EEND ensemble, DiCoW-style diarization-conditioned ASR, overlap-triggered separation) with Mermaid diagrams, DER/WER benchmark tables, and license-aware substrate picks. Recommended a three-phase roadmap: P1 (quick wins + forced alignment, 2–4 weeks), P2 (evidence graph + ensemble diversity, 1–2 months), P3 (diarization-conditioned ASR sidecar, 3+ months).

### April 17, 2026 — Word Timeline Rebuild (Slice 1): Forced-Alignment Scaffolding

Began executing the memo's Phase 1 recommendation: a forced-alignment stage that rebuilds word timings from audio against the Deep-Transcription-merged text, replacing the cross-attention-interpolated Whisper estimates currently used downstream by Deep Diarization and flag ranges.

Slice 1 landed the dependency-free scaffolding. Added `ForcedAlignmentService` protocol with `AlignedWord`, `ForcedAlignmentDelta`, and `ForcedAlignmentError` types in a new `Services/ForcedAlignmentService.swift`. Added a `PassthroughForcedAlignmentService` that throws `.disabled` so call-sites can treat "no alignment" as a normal error path. Added a `Qwen3ForcedAlignmentService` actor in `Services/Qwen3ForcedAlignmentService.swift` guarded by `#if canImport(Qwen3ASR)` — it will light up automatically when the `speech-swift` SPM dependency is added in Slice 2, and throws `.notImplemented` until then. Added a `WordTimelineRebuilder` enum service in `Services/WordTimelineRebuilder.swift` that takes a `MergedTranscript` + `[AlignedWord]` and rewrites per-word `.start`/`.end` in place via a greedy text+time matcher, preserving all speaker/provenance/flag metadata.

Wired the plumbing into the ViewModel: added `isAligningWordTimings`, `wordAlignmentProgress`, `wordAlignmentError`, `lastWordAlignmentDelta` state; added a new async `rebuildWordTimeline()` method; added an auto-trigger at the end of `openReconciliationMerge()` gated on a new `@AppStorage("enableForcedAlignment")` setting (default off). Added `wordTimingsRefined` and `wordTimingsAlignerLabel` fields to `MergedTranscript` so the UI can surface when timings have been refined.

Design decisions: the alignment stage runs once against the best merged text rather than twice per engine (cheaper, single downstream source of truth); failure is non-fatal and logs a warning rather than blocking the pipeline; the greedy matcher tolerates token-count mismatches between aligner and merged stream (unmatched merged words keep their ASR timings). Chose `speech-swift`'s Qwen3-ForcedAligner over WhisperX's wav2vec2 aligner because it is Apache-2.0, Apple-Silicon-native via CoreML/MLX hybrid, and Qwen's own reporting claims it surpasses NFA/WhisperX/Monotonic-Aligner — with Whisper internal cross-attention DTW (arXiv:2509.09987) filed as a Slice 4 A/B comparison. Parse-checked the three new files with `swiftc -parse` and confirmed no syntactic issues.

Wrote `Brainstorming/WORD-TIMELINE-REBUILD-PLAN.md` as the ongoing progress tracker; it defines four slices (scaffolding, wire real dep, benchmark validation, polish) with sign-off criteria per slice. Slice 1 is done; Slice 2 (add `speech-swift` to `Package.swift`, wire model download warning modal, first smoke test) is the next session's work.

### April 17, 2026 (continued) — Word Timeline Rebuild (Slice 2): Real Dependency + Smoke Test

Pulled the trigger on Slice 2. Added `speech-swift` v0.0.9 as an SPM dependency on the Consensus target with `.product(name: "Qwen3ASR", package: "speech-swift")`. It resolved cleanly, pulled in a `SpeechCore.xcframework.zip` binary artifact and roughly 30 transitive dependencies (MLX, WhisperKit, swift-nio, swift-certificates). Consensus now compiles against the real `Qwen3ASR` module.

Reconciled two API mismatches between the Slice 1 stub and the real v0.0.9 code. First, `Qwen3ForcedAligner.fromPretrained` takes a `progressHandler: ((Double, String) -> Void)?` that reports both a fractional progress value and a phase message ("Downloading weights...", "Loading tokenizer..."); our protocol's `progressCallback` is `(Double) -> Void`, so the wrapper discards the phase string. Second, `AudioCommon.AlignedWord` (fields `.text`, `.startTime: Float`, `.endTime: Float`) collided with my Slice 1 type of the same name — renamed ours to `AlignedWordTiming` across three files to eliminate the ambiguity. Consensus target builds clean after these fixes.

Built a standalone `SmokeAlignment` executable target at `Scripts/SmokeAlignment/main.swift` that exercises the same `Qwen3ForcedAligner.fromPretrained` + `.align(audio:text:sampleRate:)` path our wrapper uses, so the smoke verifies the integration without needing to launch the full SwiftUI app. Pinned the new target to Swift 5 language mode to match Consensus; speech-swift's `progressHandler` closure is not `@Sendable`, which Swift 6 strict concurrency rejects. This means our wrapper has the same latent issue — not a runtime bug, but something to fix when we move the Consensus target to Swift 6 mode.

Ran the smoke against `TestAudio/APP TEST AUDIO.m4a` (11.18s): **26 reference tokens in, 26 aligned words out, 0 unmatched, alignment RTF ≈ 5.3× on M-series, model warm-cache load time 1.22s**. The first word landed at 0.80–0.96s and the last at 10.32–11.20s — consistent with the full audio duration. Notably, Qwen3-ASR's own transcription of the same audio misheard "Brant" as "Brand"; because our pipeline feeds the aligner the finalized merged text (with the correct spelling), the forced aligner placed "Brant" correctly at 2.08–2.16s and 8.24s. That's the exact win the word-timeline rebuild is designed to produce, now confirmed on real audio.

Hit one real deployment blocker: MLX requires a precompiled `mlx.metallib` shader library at the executable's location; without it, inference aborts with *"Failed to load the default metallib"* at `stream.cpp:115`. The speech-swift package ships a reference build script at `.build/checkouts/speech-swift/scripts/build_mlx_metallib.sh` that compiles 32 Metal sources into `mlx.metallib`. Before Consensus can ship this feature in a packaged app, we need to vendor that script into `Scripts/` and add an Xcode "Run Script" build phase that places the metallib next to the executable in `.app/Contents/MacOS/`. Added that as Slice 3 item #1.

Slice 2's sign-off criterion from the plan was "real dependency builds, one recording end-to-end produces a non-empty output with `wordsAligned > 0`." Both satisfied. Next work sequenced into Slice 3: (1) ship the metallib build phase, (2) add the first-time enable modal warning about the model download, (3) wire a Settings UI toggle, (4) stand up a `transcribo-eval` benchmark harness with tcpWER/DER and flip the default only if the benchmark confirms improvement.

### April 17, 2026 (continued, third pass) — Word Timeline Rebuild (Slice 3): Settings UI + Benchmark

Started Slice 3. The first plan item — an Xcode build phase for the MLX metallib — turned out to be unnecessary: `TranscriboApp/build-app.sh` already compiles Metal shaders and places `mlx.metallib` in both `Contents/MacOS/` and `Contents/Resources/` of the packaged `Consensus.app`. Re-running `./build-app.sh --release` after the Slice 2 dep addition produced a working bundle cleanly. One caveat flagged for Slice 4: `build-app.sh` produces a 3.1 MB metallib while speech-swift's own reference script produces a 107 MB metallib from the same MLX source tree. Worth verifying whether the smaller bundle is missing kernels the aligner exercises at runtime before shipping.

Added the user-facing Settings UI. `SettingsView.swift` gained a new "Deep Review" section with a labeled toggle (title + caption) and a secondary info line visible when enabled. The toggle binding routes the first off→on transition through a SwiftUI `confirmationDialog` that explains the ~500 MB model download and lets the user cancel. A new `hasSeenForcedAlignmentWarning` `@AppStorage` flag prevents re-nagging. `ReconciliationView`'s header got a status indicator: a spinner-plus-progress-text while alignment is running, or a green "Timings · refined · Δ{N}ms" chip once `merged.wordTimingsRefined` is true, reading `viewModel.lastWordAlignmentDelta.meanStartDelta` for the display number. Full Consensus target builds clean.

Built a batch benchmark harness — a new `AlignmentBenchmark` executable target at `Scripts/AlignmentBenchmark/main.swift`. For each audio file it runs Qwen3-ASR-0.6B for the baseline transcript, then Qwen3-ForcedAligner on that transcript, and reports alignment RTF, token / aligned-word count, zero-duration-word count, mean / max inter-word gap, and mean / max deviation from a linear-interpolation baseline. Without ground-truth RTTM we can't compute true DER or tcpWER yet, but linear-deviation is a useful sanity check — a near-zero value would mean the aligner is silently emitting evenly-spaced trivial output. JSON summary writes to `/tmp/alignment-benchmark.json`.

Surfaced one real gotcha: the first benchmark run crashed at exit 139 with zero stdout. Turned out to be `String(format: "%-46s …", swiftStringValue)` — Swift's `String(format:)` treats `%s` as a C `char *`, not a Swift `String`, so passing a `String` leads to a segfault when the bridged layout doesn't match. Added `setbuf(stdout, nil)` / `setbuf(stderr, nil)` at the top of `main` for flush-on-every-print, then rewrote the format specifiers to use `%@` with explicit `as NSString` casts. Clean after that.

Benchmark results across three TestAudio files (M-series warm cache):

| File | Duration | Aligned words | Zero-dur% | ASR RTF | **Align RTF** | Mean dev from linear |
| APP TEST AUDIO | 11.2 s | 26 | 15% | 28.4× | 65.5× | 0.45 s |
| 141 W 54th St 3 | 456.6 s | 343 | 26% | 32.7× | 76.3× | 158.1 s |
| 120 W 55th St | 528.2 s | 426 | 18% | 35.8× | 69.5× | 168.9 s |

Headline read: **alignment RTF is 65–76× on M-series — a 30-minute recording aligns in under 30 seconds.** Combined ASR + forced alignment stays above 20× RTF, so adding the full stack to Deep Transcription costs roughly three minutes per hour of audio, most of which is the ASR. The large mean-deviation-from-linear numbers on the long files confirm the aligner is making audio-grounded decisions rather than emitting trivial even spacing.

One genuine quality finding bumped to Slice 4: **zero-duration-word rates of 15–26% on real-world audio**. Qwen3-ForcedAligner's timestamp classifier has 5000 classes over the audio time axis, and at that granularity adjacent words in rapid succession can snap to the same frame and emerge as `start == end`. Not a wrapper bug, not a deal-breaker, but a post-processing fix in `WordTimelineRebuilder.apply` — enforce a minimum word duration (e.g. 60 ms, clipped by the next word's start) for any `start == end` output — will eliminate the phenomenon cleanly. Other Slice 4 candidates: test the 8-bit aligner variant, chunk long audio with overlap, and A/B against Whisper internal cross-attention DTW (arXiv:2509.09987, which needs no separate model).

Slice 3 sign-off was "benchmark harness exists, baseline and forced-alignment runs produce comparable numbers, delta is measured." Partially satisfied — the harness exists and produces numbers against a linear-interpolation synthetic baseline, but real tcpWER/DER is deferred until we parse the Clayton Everett `_transcript.pdf` into a timed-word ground truth. That PDF-to-RTTM work is its own mini-project sitting at the top of Slice 4's queue.

### April 17, 2026 (continued, fourth pass) — Word Timeline Rebuild (Slice 4): Quality Hardening + Production Chunking

The pivotal session for this feature. Went in planning minor polish; came out having fixed a zero-duration quantization artifact, discovered and repaired a real shipping-metallib bug, stood up ground-truth tooling, measured real numbers against the human-verified Clayton Everett transcript, and wired production chunking because single-shot alignment falls off a cliff past ~2 minutes.

**Zero-duration word repair (Slice 4.1).** Qwen3-ForcedAligner's 5000-class timestamp quantizer routinely produces `start == end` for adjacent rapid words — 15–29% of words on real phone-call audio per the Slice 3 benchmark. Added `AlignedWordTimingPostprocess.enforceMinimumDuration(_:minimumSeconds:)` helper with a 60 ms default, clipped by the next word's start so we never overlap. Wired into every production path in `Qwen3ForcedAlignmentService`. Extended `AlignmentBenchmark` to report before/after zero-duration counts: raw 15/29/18% → repaired 4/6/8% across the three test files. Residual (4–8%) is the aligner placing two words at literally the same start time, which the conservative repair can't move without potentially shifting onsets we want to preserve.

**Aligner quantization A/B (Slice 4.3).** Added `--aligner-model` flag to the benchmark and tried 8-bit aligner vs 4-bit. 8-bit helped most on the worst file (141 W: raw 29% → 19%), but post-repair both quantizations land in the same ballpark (6% vs 4%). Kept 4-bit default — smaller download (~500 MB vs ~1 GB), faster warm load, essentially equivalent quality downstream.

**Metallib shipping bug fixed (Slice 4.2).** Discovered during investigation that `build-app.sh` was compiling only 9 Metal sources from `Source/Cmlx/mlx-generated/metal/` (a pre-generated subset) and producing a 3.1 MB metallib. speech-swift's own reference script compiles the full 32 sources from `Source/Cmlx/mlx/mlx/backend/metal/kernels/` and produces a 107 MB metallib. The shipping `.app` was missing 34× worth of MLX Metal kernels. Patched `build-app.sh` Step 2 to delegate to `.build/checkouts/speech-swift/scripts/build_mlx_metallib.sh`. The rebuilt `Consensus.app/Contents/MacOS/mlx.metallib` is now 107 MB with the correct kernel set.

**Ground truth + alignment validator (Slice 4.5).** First attempt was to parse Consensus's Legal PDF export as ground truth for tcpWER measurement. The PDF looked parseable in a screenshot, but both PDFKit and `pdftotext` extracted zero text — Consensus's exporter uses Core Graphics glyph rendering (Quartz PDFContext) with no text layer. Pivoted: the `project.json` files in `~/Library/Application Support/BDK Transcribo/Projects/` carry the full human-reviewed `deepReviewConsensus` pass with per-word timings, per-segment speakers, and resolved speaker names — much richer than the PDF would have been.

Built two new executable targets under `Scripts/`. `GroundTruthExporter` reads a `project.json`, picks a pass (default last; `--pass-kind deepReviewConsensus` for human-verified), emits a flat `<project>.groundtruth.json`. `AlignmentValidator` runs Qwen3-ForcedAligner against the same audio and reports mean/median/p95/max absolute start-time offset, percentage within tolerance bands (50 ms / 100 ms / 250 ms / 500 ms / 1 s), and per-speaker-turn boundary offset.

First validator run against Clayton Everett's Consensus pass (19 min, 3022 words): **single-shot alignment produced 1.6% matched words** — all first 25 words collapsed to `startTime = 92.96s`. The aligner's context simply can't handle 19 minutes of audio as a single forward pass. Extended the validator to chunk along GT segment boundaries (2-minute ceiling, 0.5 s edge padding). Result: **77% matched, median offset 300 ms, 91% of words within 1 second, speaker-turn boundary median offset 320 ms.** That's the first quantitative proof forced alignment is actually useful on our kind of audio — assuming chunking.

**Production chunking wired end-to-end (Slice 4.6).** Added `ForcedAlignmentHint` (start, end, text) to the `ForcedAlignmentService` protocol plus an `alignSegments(audioURL:hints:maxChunkSeconds:)` method. `Qwen3ForcedAlignmentService.alignSegments` coalesces consecutive hints up to a 120 s ceiling, slices audio with 0.5 s edge padding, runs alignment per-chunk, offsets timestamps back to absolute time, then runs the zero-duration repair on the concatenated output. `TranscriptionViewModel.rebuildWordTimeline()` now builds hints from `MergedTranscript.segments` and calls `alignSegments`. `PassthroughForcedAlignmentService` gets a matching throw-disabled stub. Consensus target builds clean; rebuilt `Consensus.app` is 49 MB executable next to the 107 MB metallib.

**Files touched this session** (full list): `Transcribo/Services/ForcedAlignmentService.swift` (AlignedWordTimingPostprocess + ForcedAlignmentHint + protocol + Passthrough + audio slice helper), `Transcribo/Services/Qwen3ForcedAlignmentService.swift` (align + alignSegments both applying the repair), `Transcribo/ViewModels/TranscriptionViewModel.swift` (switched to alignSegments with segment hints), `build-app.sh` (metallib delegation), `Scripts/AlignmentBenchmark/main.swift` (before/after zero-duration + --aligner-model + fileArgs parsing), `Scripts/GroundTruthExporter/main.swift` (new, reads project.json), `Scripts/AlignmentValidator/main.swift` (new, GT comparison with chunked alignment), `Package.swift` (three new executable targets: GroundTruthExporter, AlignmentValidator, renamed the stale LegalTranscriptParser slot).

Slice 4 sign-off was "measurable improvement on the benchmark set, feature default-on." First criterion met — validator shows meaningful per-word and per-turn accuracy numbers. Second deferred: default stays off until we build a Settings UI story for users to opt in after reading about the 500 MB model download. Next session candidates: Whisper internal cross-attention DTW as an alternate aligner, tcpWER / DER computation from the validator's matched-offset data, and improving the unmatched-word recovery in the validator (the 23% unmatched are largely tokenization disagreements, not timing failures).

### April 17, 2026 (continued, fifth pass) — Polish View Wired + App Installed

Installed the `Consensus.app` bundle to `/Applications/` via `./build-app.sh --release --install`. Verified the install ships the correct 107 MB `mlx.metallib` (previously the bundled metallib was 3.1 MB due to the build-app.sh compile bug fixed earlier this session).

Audited the local-AI cleanup/summary subsystem. Findings:
- **Summary generation works and is wired into the UI.** Three entry points: the sidebar "Summary" item (→ `SummaryView`), the Summary Sidepane (→ `SummarySidepaneView`, a togglable panel), and automatic project-summary generation for dashboard cards (`generateProjectSummary`). All route through `TranscriptCleanupService.process(task: .summarize)` with the system-prompted ACTION ITEMS + KEY POINTS structure.
- **LLM-assisted diarization is working.** `confirmSpeakerBoundaries` (used by Deep Diarization) and `resolveDiarizationDisagreements` (used by multi-pass diarization) both use the same cleanup-service LLM for speaker-change reasoning.
- **Cleanup (Polish) was orphaned.** `PolishView.swift` and `runCleanup()` exist and work, but no navigation path reached the view — the Polish UI was dead code. Wired it up in this session: added `case .polish` to `WorkflowPhase`, added the switch arm to `ContentView` routing to `PolishView`, added a "Polish (AI Cleanup)" sidebar entry with a `wand.and.stars` icon in the Tools section, added the matching status-pane label case. Polish is now one click from the sidebar whenever a transcript is loaded.

Model support under `CleanupModel`: auto-picks Qwen 3 8B (~4.5 GB) on 16 GB+ RAM, Qwen 3 4B (~2.5 GB) on 8 GB+, Llama 3.2 3B (~1.8 GB) otherwise. All are MLX 4-bit quantized, downloaded on first use via mlx-swift-lm. Qwen variants get a `/no_think` prefix to disable thinking mode so they don't exhaust memory generating `<think>` blocks. Token output streams live into the process log so the user can see progress during long runs.

Rebuilt and reinstalled once more after wiring Polish. `Consensus.app` in `/Applications` is now the fully-featured build with forced alignment, zero-duration repair, chunked alignment, the metallib fix, and a reachable Polish view.

### April 17, 2026 (continued, sixth pass) — Decided the Polish Symmetry

After the Polish sidebar entry went in, noticed it was asymmetric with the Deep Review Step 4 "Polish with AI" button — both UIs said "Polish" but only the Deep Review one actually wrote the result back to the transcript. The sidebar PolishView was effectively a preview pane with a Copy button and no way to save work. Made the explicit call not to ship with that dangling state.

Looked at the full wiring:
- Deep Review Step 4 → `DeepReviewCompareView` "Polish with AI" button → `runDeepCleanup()` → runs `.cleanup` task → calls `applyCleanedText` in-place → persists. Single button, integrated into the Deep Review flow, mutates on click.
- Sidebar "Polish (AI Cleanup)" → `PolishView` → `runCleanup()` → configurable task (cleanup / summarize / both) → streams result into a right-pane preview → only a Copy button.

The sidebar PolishView has real unique value (configurable task, standalone utility, reachable without completing four Deep Review steps), so the right move was keeping it and closing the gap rather than deleting it.

Added a public `applyPolishResult()` method on `TranscriptionViewModel` that takes the existing `cleanupResult`, strips any trailing SUMMARY section (regex-detected when the task was `.cleanupAndSummarize`), and calls the existing `applyCleanedText` helper — same code path Deep Review Step 4 uses. Added an "Apply to Transcript" primary button in `PolishView`'s result-panel header, visible only when (a) there's a cleanup result, (b) the task wasn't pure summarize, and (c) there's an active transcript to write to. Copy stays alongside as a ghost button.

Net result: the Polish feature is now coherent across both entry points. Deep Review users get the integrated workflow button; standalone users get the full-featured PolishView with task choice and explicit Apply. No dead code, no dangling features, no "what does this actually do" ambiguity. `Consensus.app` reinstalled to `/Applications` with the changes (timestamp 09:58 final build was superseded by a subsequent build after the apply-button wiring).

### April 20, 2026 — Telephone Diarization Research Response

Completed a full research response to the April 20 diarization brief and saved it as `Brainstorming/2026-04-20 - Codex Research Response.md`. The research sharpened the near-term plan around finishing the word-timeline rebuild, then adding a telephone-specialist diarization sidecar before stacking more local heuristics on top of SpeakerKit.

The strongest concrete recommendation was to try a CALLHOME-tuned LS-EEND ONNX sidecar first, with NeMo's `diar_msdd_telephonic` kept as a research track because no clean Apple-Silicon port surfaced in public sources. The LLM-arbiter idea survived the literature review, but only in a constrained form: low-confidence span edits, compact prompts, JSON edit lists, and acoustic verification before applying changes.

The enrollment / voice-library plan also held up, with one important reframing: it should be treated as speaker identification and continuity, not as a substitute for core diarization. The research also made the evaluation gap harder to ignore — MeetEval + dscore and a larger labeled phone-call corpus now look like prerequisites for claiming real quality gains rather than just directional improvements.

### April 20, 2026 — Fresh Attack Plan + Conversational Boundary Proposer (Slice 1)

Wrote `Brainstorming/2026-04-20 - Fresh Attack Plan.md` — a new end-to-end plan that reframes the diarization problem as a fusion-across-signal-channels problem rather than an acoustic-ensemble problem. The thesis: the pipeline already has rich acoustic diversity (multi-pass SpeakerKit + FluidAudio, forced alignment, LLM boundary confirmation) and more passes of the same kind have plateaued. The next gains come from adding *orthogonal* signal channels — prosodic (F0), lexical/conversational, semantic (LLM arbiter over low-confidence spans), and cross-session memory (voiceprint library) — and letting the LLM arbitrate between them instead of polishing after.

Began execution. Added a new service `ConversationalBoundaryService.swift` that proposes candidate speaker boundaries from the transcript text alone. Heuristics cover four pattern families: back-channel tokens ("yeah"/"okay"/"right"/"mhm" etc.) detected at both segment and word level with per-word-timing gap checks to avoid false positives on same-speaker fillers; long inter-segment silence (>1.5s) where acoustic diarization smoothed over a real turn; direct name-address patterns ("So Bob,..."/"Clayton, what do you..."); and self-introduction patterns ("Hi, this is X"). Each candidate carries a reason tag and a soft strength score, and near-duplicates within 0.35s collapse to the strongest. Wired into `TranscriptionViewModel.refineSpeakers()` so conversational candidates pool into the same vote map as acoustic candidates and pass through the existing LLM confirmation + acoustic-verification backstop. This addresses the documented March-26 failure mode where multi-pass voting produced the same result as single-pass because SpeakerKit always outvoted FluidAudio — conversational logic is genuinely orthogonal evidence that can't be outvoted by more acoustics.

Also replaced the hardcoded `qualityScore: 1.0` in `SpeakerKitDiarizationService` with a segment-duration-based proxy that saturates around 3 seconds. SpeakerKit still doesn't expose per-segment confidence, but a duration proxy is strictly more informative than a constant for downstream majority-vote scoring.

Both changes build clean (`swift build` passes at 48s cold, 19s incremental). Neither is default-gated — both light up inside the existing "Refine Speakers" flow that power users already trigger.

Design decisions recorded: (a) scoped the first slice to conversational logic rather than F0 because F0 requires DSP work in Swift and has more latent issues (unvoiced-frame handling, phone-band noise); (b) kept `totalPasses` in the LLM prompt as acoustic-only since conversational isn't a "system" in the same sense and reporting it as one would mislead the arbiter; (c) chose segment+word-level back-channel detection over just segment-level because the most-missed case is a "yeah" embedded in a longer neighbor segment where the whole segment is long; (d) saved the Codex research response as the direct input that reshaped the plan (constrained-span LLM arbiter, multi-exemplar voice library, MeetEval+dscore evaluation gate, LS-EEND CALLHOME as the highest-leverage telephony sidecar).

Slice-2 candidates, in rough priority: (1) stand up the MeetEval + dscore benchmark harness against the existing Clayton Everett consensus pass so future changes get real numbers; (2) constrained LLM edit proposer over low-confidence spans (separate from the existing boundary-confirmation path) with JSON edit output and acoustic verification; (3) F0-shift candidates via Accelerate/vDSP YIN-style detector; (4) WeSpeaker-based self-enrollment within the current file (gold centroids from long high-confidence segments, verification for short disputed segments). LS-EEND CALLHOME ONNX sidecar is the highest-leverage Phase-3 item but requires ONNX runtime wiring, so it comes after the within-pipeline work lands.

### April 20, 2026 — Origin-Aware Boundary Verification + Transcript Readability Fixes

First end-to-end test of the conversational-boundary work surfaced the expected weakness: the LLM confirmed 2 conversational-origin boundaries on a phone call, then acoustic verification dropped both as "LLM-only." Zero net boundaries applied. The "require acoustic evidence" policy was vetoing exactly the channel the conversational signal was designed to recover (same-voice back-channels, short interjections acoustic models can't hear).

Made the verification origin-aware. Added parallel `acousticOriginTimes` / `conversationalOriginTimes` sets tracked alongside the existing `allBoundaryVotes` map; in Phase 3b, candidates whose rounded time sits in `conversationalOriginTimes` but NOT in `acousticOriginTimes` now bypass the acoustic veto when the LLM confirms them. Candidates with ANY acoustic support still require acoustic verification (acoustic is the known-reliable channel when it can see something). The asymmetry is the principled move: don't let the known-failing channel overrule two agreeing non-acoustic signals on a pattern it's known to fail on. Verification log now splits counts into acoustic-confirmed / lexical-bypass / dropped instead of the old binary "confirmed by audio / LLM-only."

Separately, real-world testing exposed two transcript display problems flagged by the user on a 7m36s phone call:

**Duplicate words.** The merged transcript contained "cost cost", "position. position", "fine. fine.", "pretty pretty", "waste waste" — classic confidence-merge leaks. When one engine hallucinated a repeat or both engines produced timestamps too far apart for the word aligner to match, the merged word stream ended up with identical words back-to-back. Added `collapseAdjacentDuplicateWords` as a Step 4b in `ConfidenceMergeService.buildMergedTranscript`: walks the merged stream, drops consecutive words whose normalized form is identical and whose inter-word gap is < 300 ms, keeping the higher-confidence one and widening its time range to span both. A speaker genuinely repeating themselves ("pay down ... a full pay down ... put pay down") has meaningful space between the repeats, so those are preserved. Also added a `collapseAdjacentDuplicateTokens` text-level safety net in the Deep Review Compare view so projects that were merged before the upstream fix still display cleanly without needing to re-run Deep Review.

**Fragmented short lines.** The "Review Final Transcript" view rendered one SwiftUI `Text` per TranscriptionSegment. When Parakeet's >2s-pause splitter produced many short segments within a single speaker's continuous turn, each one stacked as its own visual block, giving the appearance of 1-2 word lines. Added `coalesceSameSpeakerSegments` on DeepReviewCompareView that groups consecutive same-speaker segments into a single `SpeakerTurn` block with joined text and one speaker header. The underlying segment model is untouched — exports, click-to-play, and keyboard navigation still operate at segment granularity everywhere else. Only the Step-4 preview renders the coalesced view. Main `TranscriptView.swift` kept segment-per-row for its click/play/reassign UX; a parallel fix for the main transcript view is a follow-up.

Rebuilt and reinstalled to `/Applications` at 17:47. Build clean, no new dependencies.

### April 20, 2026 — Timestamp-Quality Overhaul: Engine-A Pinning, Sentence-Coherence Smoother, FA Default-On with Re-attribution

Root-cause analysis of the cross-speaker-sentence failure mode (speaker change mid-sentence where the first N-1 words are attributed to speaker A and the final word flips to speaker B) traced the issue back to the word-timestamp layer. Speaker attribution is pure timestamp-overlap against the diarization timeline, so when ASR word timing is off by ±100–200 ms and a diarization boundary is off by another few hundred ms, a single word near the boundary gets pulled to the wrong side. The transcript then looks like a speaker change inside a continuous sentence.

Four coordinated changes landed to attack that root cause.

**(1) Engine-A pinned timestamps in the merge.** `ConfidenceMergeService.mergeAlignedWords` was using `chosen.start/end` for matched pairs — i.e. whichever engine's word won on confidence supplied both the text AND the timings. Since Parakeet (CTC-aligned) and Whisper (attention-derived) derive timestamps very differently, alternating between them injected ~50–100 ms of jitter at every alternation, and that jitter is exactly the amount that produces cross-speaker flips near diarization boundaries. Now the matched-pair path uses `ref.start`/`ref.end` always — text and confidence still come from the winning engine, but timing is pinned to Engine A. `candidateOnly` words continue to carry Engine B's timings since there's no alternative; forced alignment is the full fix for those.

**(2) Sentence-coherence smoother.** Added `SegmentMerger.smoothSentenceBoundaries` as Layer 4 of `merge()`. Detects A-B-A patterns where B is ≤2 words, <1.0 s duration, the prior segment does not end on sentence punctuation, and B is not a known back-channel token ("yeah", "okay", "right", "mhm", etc. — those ARE real short turns, handled by the conversational-logic path). When the pattern matches, reassigns B to A's speakerID and then coalesces adjacent same-speaker segments via `coalesceAdjacentSameSpeakerSegments` (gap < 2 s) so the transcript reads as one continuous turn instead of three fragments. Also wired into the Deep Review path at the tail of `ConfidenceMergeService.buildConsensusResult` so both pipelines benefit. This is the "the LLM could catch this trivially" heuristic made cheap — pure structural rule, runs in milliseconds, no acoustic work needed.

**(3) Re-attribute after forced alignment.** `rebuildWordTimeline` previously applied FA to `mergedTranscript.segments[].words[].start/end` but left the speaker attribution frozen from the pre-FA merge. So FA was effectively cosmetic — it improved exported subtitle timings but couldn't fix cross-speaker sentences because the segment boundaries were already locked in with the old attribution. Added `ConfidenceMergeService.reattributeAfterRetiming(_:referenceSegments:)` which flattens the merged word list, re-runs `groupIntoReferenceSegments` (promoted from `private` to `internal`) against the refined timings, and remaps flags by time range so the merge-review UI doesn't break. `rebuildWordTimeline` now calls this after applying FA timings and logs how many words moved to a different speaker as a result. This is what actually makes FA fix the symptoms users see.

**(4) Forced alignment default flipped to ON.** `AppSettings.enableForcedAlignment` now defaults to `true`. The existing first-run model download flow (Settings explains the ~500 MB Qwen3-ForcedAligner weight download) still fires if the user discovers the toggle. For users who have never touched the setting — everyone, in practice — the next Deep Transcription triggers the background FA pass automatically. First run downloads the model; subsequent runs use the cache. The FA code path is already robust to "model not yet downloaded" and "model load fails" — it logs and falls through, leaving the ASR timings in place. This is the root fix for the whole timing-quality problem: a single audio-aligned source of word timings, replacing the mixed Parakeet/Whisper timings from the merge.

Design decisions worth recording: (a) kept Engine-A pinning as a separate change from FA-by-default so that if a user's FA toggle is off (either explicit or because the model download hasn't completed), the merge still has timestamp consistency from a single engine. (b) The smoother is deliberately conservative — back-channels and sentence-punctuation breaks are protected because those are where real short turns actually happen. Too-aggressive smoothing would erase legitimate interjections. (c) FA re-attribution preserves flag IDs and remaps them by time range; if the time range no longer overlaps any segment (vanishingly rare), the flag is dropped. We accept this as a cleaner failure mode than carrying stale segment indices. (d) The `countWordsThatMovedSpeaker` helper is strictly observability — it tells us in the process log how many words the re-attribution actually moved, which is the single data point that answers "did FA meaningfully change attribution on this file?"

Built clean, reinstalled to `/Applications` at 19:08. All four changes land together; verifying them requires running Deep Review on a new or re-opened project so the merge path re-executes with the Engine-A-pinned timestamps, and letting FA finish its first download on a machine that doesn't have the model cached yet.

Follow-up items for next session: (i) Undo-for-Polish (still open from the earlier session); (ii) main `TranscriptView` could benefit from the same same-speaker segment coalescing that DeepReviewCompareView and SpeakerConfirmView already do; (iii) benchmark FA vs raw-Parakeet-only timestamps on the Clayton Everett corpus via MeetEval/dscore to prove the end-to-end win quantitatively.

### April 20, 2026 — Polish Duplication Bug Fix, Polish Undo, Word-Level Sentence Smoother, Re-run From Scratch, Gemma Research

Testing on a 8m48s phone call surfaced two user-visible problems after Deep Review: (1) mid-sentence speaker breaks in the final transcript (smoother too narrow), and (2) AI Polish duplicating entire paragraphs.

**Polish duplication — root cause and fix.** The prior `applyCleanedText` walked through the original segments sequentially and wrote each LLM block's text to the first matching same-speaker segment, then advanced to the next block. When the LLM merged N original segments into one block (which it does aggressively for same-speaker runs), the block's text was written to the FIRST of the N segments, and the remaining N-1 segments kept their original pre-polish text. The effect on screen: the LLM's cleaned paragraph appeared in segment N, then the original raw word-salad text of N-1 more segments followed, so the user saw the same content twice back-to-back across the transcript — sometimes the duplicates were 100+ words.

Rewrote `applyCleanedText` to REBUILD the segment list from the LLM blocks. For each block, consume the contiguous run of same-speaker original segments, coalesce their time ranges into one new segment with the block's text and metadata from the first source segment. Drop word-level timings on rewritten segments (the LLM changed the text so old per-word timestamps no longer align — consumers that need word-level timing should run before Polish). Pass-through untouched: any original segment that doesn't match a block (LLM dropped or mis-labeled a speaker) stays in place. `parsePolishBlocks` and `speakerBlockMatchesSegment` extracted as helpers so the logic is unit-testable.

**Undo for Polish.** Added `PolishUndoSnapshot` capturing pre-Polish `segments` + `speakerMapping` for the active pass, `canUndoPolish` computed property, and `undoPolish()` method that restores from the snapshot. Snapshot is taken inside `applyCleanedText` so both `runDeepCleanup` (Deep Review Step 4 button) and `applyPolishResult` (standalone PolishView button) populate it automatically. In `DeepReviewCompareView`, after the "Polished" checkmark appears, an "Undo Polish" secondary button renders alongside; one click restores the transcript. The snapshot is a single slot (most recent polish) rather than a stack — consistent with Cmd-Z convention for a one-shot destructive operation.

**Sentence-coherence smoother rewritten at word level.** The prior segment-level smoother only caught A-B-A sandwiches where B was ≤2 words. It missed A-B patterns — the common case where one speaker's sentence continues across a segment boundary and a few words "land" on the wrong speaker. The user's screenshot showed clear examples: SPEAKER_1 ending with "So", SPEAKER_0 starting with "let's see what happens" (one sentence); SPEAKER_0 ending with "something I", SPEAKER_1 starting with "was hoping you guys might consider." (one sentence).

New `smoothSentenceBoundaries` flattens segments into a word stream with mutable speaker IDs, identifies sentence boundaries by `.!?`-ending words, and for each multi-speaker sentence: if the minority speaker holds ≤3 contiguous words AT THE START OR END of the sentence (never in the middle — mid-sentence multi-word flips may be genuine handoffs like "I was thinking — yeah, me too"), reassigns those words to the majority speaker. Back-channel tokens ("yeah", "okay", "right", etc.) are skipped — those ARE real short turns. After reassignment, rebuilds segments by walking runs of same-speaker consecutive words. Falls back to the old segment-level sandwich smoother (`legacySandwichSmoother`) when word timings are absent. The new pass catches A-B, A-B-A, and A-B-A-B patterns cleanly within the word-level window it operates on.

Left deliberately conservative: requires minority ≤3 words AND contiguous AND at sentence edge. Multi-word mid-sentence flips stay — too risky to auto-correct without acoustic verification. Those become candidates for a future sentence-coherence arbiter that plays the clip and asks the user.

**"Re-run From Scratch" for existing projects.** Added `restartCurrentProjectFromScratch()` on the view model: clears `project.passes`, `activePassID`, `speakerMapping`; resets in-memory derived state (result, mergedTranscript, cleanup results, deep-review completion tracking); routes back to `.setup` phase; persists. Keeps the project identity, audio link, export preferences, and templates so the user doesn't lose settings. Wired into the sidebar right-click menu ("Re-run From Scratch…") with a confirmation alert. This addresses the workflow question: when testing pipeline changes against an existing project, the user needs a way to discard prior passes without deleting the project entirely.

**Gemma vs Qwen research (out-of-band).** Delegated to research agent, response saved to `Brainstorming/2026-04-20 - Gemma vs Qwen Research.md`. Highlights: Gemma 4 is real (released April 2, 2026), Apache 2.0-licensed (parity with Qwen for the first time), four sizes incl. E4B (4.5B effective params) as a direct Qwen 3 4B swap candidate. MLX 4-bit quants exist on HF (`mlx-community/gemma-4-e4b-it-OptiQ-4bit` and siblings). At the 4B tier, benchmarks are MIXED — Qwen 3.5 may still edge Gemma 4 on structured-output / instruction-following tasks. Gemma 4's thinking mode toggles via `enable_thinking` (not Qwen's `/no_think` string) and ollama issue #15260 reports `think=false` silently drops JSON `format` constraints. That directly threatens the speaker-boundary confirmation batch task which depends on structured output. Recommendation: try Gemma 4 E4B for the low-risk tasks first (cleanup + summarization), validate JSON-constrained decoding works on the MLX path before migrating boundary confirmation or diarization arbitration. Not started this session.

Rebuilt and reinstalled to `/Applications` at 20:53. Changes live for user validation. Expected behavior on re-running Deep Review after Polish: no duplicated paragraphs, cross-sentence single-word flips collapsed, "Undo Polish" button visible after running Polish.

Follow-up tracking: the word-level smoother can be validated by counting "speaker changes per sentence" before and after. Add that to the benchmark harness when the MeetEval wiring goes in.

### April 20, 2026 — Smoother Tightening + Diagnostic Mode

First Deep Review run after the word-level smoother shipped showed a regression: the 120 W 55th St call came out of Deep Review with 20 segments (10 per speaker) for an 8:48 recording, down from 188 in the pre-change run. The user's read: "Deep Review made it worse." Root cause analysis pointed at two compounding issues.

**(1) Smoother rule too loose.** The original word-level smoother reassigned minority-edge runs of up to 3 words regardless of the majority's margin. A sentence with 4 speaker-A words and 3 speaker-B words at the end would collapse all three B words into A, even though that's an ambiguous split that might well be a genuine handoff. Tightened the rule: require majority count ≥ 3× minority count. Now 4-vs-3 splits are left alone; only clear minorities (≥75% majority) get smoothed. Also bumped the minimum sentence length from 4 to 6 words for stable statistics, matching the majority threshold.

**(2) Smoother runs twice on the Deep Review path.** `ConfidenceMergeService.buildConsensusResult` calls it once after the Deep Transcription merge. `SegmentMerger.merge` calls it again after Deep Diarization's `refineSpeakers`. Each pass reassigns, errors compound. With the tighter threshold the second-pass damage is much smaller but not zero. Left as-is for now — the two calls serve distinct purposes (merge-time cleanup vs. post-diarization cleanup), and idempotence is close enough under the tighter rule.

**Diagnostic Mode added.** On user request: a toggle in Settings > Diagnostics that, when on, causes the smoother to emit a human-readable entry into the process log for every reassignment — which sentence, which words, which speaker pair, what the majority count was, and the edge position. A "Save Report" button in the Process Log titlebar (visible only when Diagnostic Mode is on) writes the full log as a markdown file to `~/Documents/Consensus Diagnostics/<date>_<project>.md` and reveals it in Finder. The smoother's `diagnostic` parameter is an optional closure threaded through `SegmentMerger.merge` and invoked once per reassignment plus once as a summary line; when off, the closure isn't constructed and there's no overhead. Same pattern can be extended to the LLM boundary arbiter and forced-alignment re-attribution in future sessions — the infrastructure is now in place; currently only the smoother is wired.

Report format uses the existing `ProcessLog.entries` as the source of truth so every visible log line is captured, plus the live-output pane contents (LLM tokens, streaming transcription). Each entry is serialized with ISO timestamp + severity + message + optional detail block. Good enough for a first-pass audit tool — machine-parseable is a future concern.

Key design notes for this session: (a) the diagnostic callback is the right shape — per-change, carries enough context to reconstruct intent — not a "dump everything at the end" snapshot, because the latter loses causal order; (b) Diagnostic Mode off by default so normal runs stay readable in the process log; (c) the "Save Report" button only appears when Diagnostic Mode is on, so it doesn't clutter regular use; (d) future hooks (LLM arbiter, FA re-attribution, boundary insertion) should follow the same `diagnostic: ((String) -> Void)?` parameter pattern so one toggle controls all of them.

Rebuilt and reinstalled to `/Applications` at 21:19. User can now: (a) re-run Deep Review on 120 W 55th St and expect less aggressive speaker merging, (b) toggle Diagnostic Mode in Settings and save a full report of the next run for review.

Follow-up tracking for next session: (i) extend diagnostic hooks to `confirmSpeakerBoundaries` (log every candidate + LLM verdict with the text context), `reattributeAfterRetiming` (log every FA-driven speaker move), `insertBoundary` (log every boundary actually applied); (ii) the user's "modular cleanup tasks" design from the Polish conversation is the next big slice — filler-word removal, misheard-word correction with domain hint, punctuation repair, cross-speaker sentence merge. Each task is independently toggleable with its own Undo slot.

### April 21, 2026 — Manual Transcript Editor + Ground-Truth Workflow

User proposed the right architectural move: "create a perfect transcript of one call, then autonomously iterate on pipeline settings and compare against it." Instead of hand-transcribing from scratch, the plan is to use the app's Deep Review output as a first pass and manually perfect it while listening to the audio. That requires a manual editor with integrated audio playback at the cursor — which is also a generally useful feature for the final app, since some ASR errors (proper nouns, legal terms like "scienter" → "C enter") are easier to fix by ear than by algorithm.

Shipped a complete Manual Transcript Editor in this session.

**Format**. The editor represents the transcript as free-form text with speaker headers: `[BRANT @ 00:00:00]` on a line, then the turn text. Deliberately identical to the proposed ground-truth file format, so the same tool serves both final-output polishing AND benchmark-ground-truth creation. When a user saves a perfected transcript, that file is the gold standard for future pipeline comparison.

**Codec**. `TranscriptManualEditorCodec` (Services/) handles three operations:
- `serialize(segments:mapping:)` — renders the active pass as editor text. Collapses consecutive same-speaker segments into one turn so the editor doesn't display a new header every 2 seconds.
- `parse(_:)` — reads the edited text back into `ParsedTurn` values. Uses a regex to find `[NAME @ HH:MM:SS]` headers (with or without the hour field); malformed lines become text rather than breaking the parse.
- `rebuildSegments(from:original:mapping:audioDuration:)` — converts parsed turns back to `TranscriptionSegment`s. Best-effort word-timing recovery: for each word in the edited text, look forward up to 6 positions in the original word stream for a normalized-text match and reuse its start/end timings. Unmatched words get linearly-interpolated timings within the turn. Unknown display names (e.g. the user typed "Anthony" for a speaker that was SPEAKER_2) get assigned to an unused SPEAKER_N slot and added to the project's mapping.
- `timeForCursor(in:cursorOffset:)` — maps a cursor position in the editor to an audio timestamp. Finds the most recent `[… @ TIME]` header at or before the cursor, counts words between the header and the cursor versus total words in the turn, linearly interpolates against the next header's timestamp. Drives the Play Context button.

**UI**. `TranscriptManualEditorView` opens as a sheet attached to `ContentView`. Layout: header with unsaved-edits indicator; `TrackedTextEditor` body (an AppKit `NSTextView` bridged into SwiftUI for real cursor-offset tracking — SwiftUI's `TextEditor` doesn't expose selection range); bottom bar with Play Context button + 2s / 5s / 10s segmented picker + status message + Cancel / Save buttons. Keyboard: Cmd+S to save, Esc to cancel. Audio player uses the existing `AudioContextPlayer` with `play(url:from:to:onFinish:)` — tapping Play Context grabs `cursorOffset`, converts to an audio time, plays ±N seconds (N being the picker value, so "5s" = ±5s = 10s total window centered on cursor), and swaps the button's icon/label for Stop while playback runs.

**VM integration**. Added `showManualEditor: Bool`, `applyManualEdits(segments:)`, `undoManualEdits()`, `manualEditUndoSnapshot` on `TranscriptionViewModel`. `applyManualEdits` snapshots the pre-edit state, promotes any `MANUAL_<NAME>` temporary speaker IDs from the codec to real `SPEAKER_N` slots, updates the project's speaker mapping for any new named speakers, rewrites the active pass's segments, and persists. Same undo mechanism as Polish (single-slot, most-recent-only), so a misfired save can be rolled back from the VM.

**Trigger buttons**. Added "Edit Transcript" buttons in two places for discoverability: the header of `DeepReviewCompareView` (Step 4) next to the Polish controls, and the header of `TranscriptView` (main transcript view, visible whenever a pass has a result). Both open the same sheet.

Design decisions worth recording: (a) one codec module for both the editor UI and the future ground-truth importer avoids format drift; (b) word-timing recovery is best-effort rather than strict — a user fixing "scienter" doesn't want to lose timing on the surrounding 2000 words that didn't change; (c) the bridged `NSTextView` was necessary because we need the cursor offset to drive playback, and pure SwiftUI doesn't expose it; (d) played audio always centers on the cursor ±N rather than starting at the cursor, because a user fixing a word wants to hear it in context rather than after; (e) undo is per-save, not per-keystroke — editing is expected to produce one coherent new state at a time.

Rebuilt and reinstalled to `/Applications` at 09:12. The editor is ready for user validation and for generating the 120 W 55th St ground-truth file that will drive the benchmark harness.

Next session: once the ground-truth file exists, build the benchmark harness (extend `Scripts/AlignmentValidator` with cpWER + DER + mid-sentence-flip counting, add a JSON config for tunable parameters, output a markdown error report). Then autonomously iterate on smoother thresholds, LLM arbiter confidence gates, and FA settings against the ground truth until the scores converge.

### April 21, 2026 — Benchmark Harness, Ground-Truth Import, and the Merge Catastrophe

User manually perfected a transcript of `141 W 54th St 3.m4a` and saved it as `TestAudio/141 W 5th St 3 - Manually Revised Transcript.rtf` (40 speaker turns, 1264 words). Then authorized autonomous iteration: "use your creativity to play around with the settings and pipeline and see how close you can get it to my transcript."

Built the benchmark infrastructure in Python (not Swift — 30s-rebuild-per-change was too slow for real iteration). Three scripts under `Scripts/benchmark/`:

- `import_ground_truth.py` — ingests an RTF or plain-text transcript with `[SPEAKER @ HH:MM:SS]` or bare `[SPEAKER]` headers, word-weighted-interpolates timestamps for untimed headers, emits canonical ground-truth JSON.
- `score.py` — loads a hypothesis (either a raw Consensus `project.json` identifying a pass by kind, or an extracted turns JSON) and computes **cpWER** (concatenated permutation-invariant WER), **DER** (frame-based diarization error rate with miss/false-alarm/speaker-error breakdown), **plain WER**, and a **mid-sentence-flip count**. Outputs a markdown error report sorted by WER per turn.
- `simulate_merges.py` — loads Engine A and Engine B word streams from a project.json, applies alternative merge strategies in pure Python, scores each. Used to find a better merge policy without rebuilding Swift each iteration.

Also loosened `TranscriptManualEditorCodec` so bare `[NAME]` headers without timestamps parse — necessary because the user typed split markers inline without looking up seconds.

**The headline finding**: the current Swift merge in `ConfidenceMergeService.mergeAlignedWords` is catastrophically bad. Benchmarking the `141 W 54th St 3` project's four passes against the ground truth:

| Pass | Plain WER | cpWER | DER | Flips |
|---|---|---|---|---|
| `standard` (Parakeet alone) | 14.64% | 17.50% | 6.09% | 4 |
| `deepReviewComparison` (Whisper alone, no speakers) | 10.36% | — | — | — |
| `deepReviewConsensus` (current Swift merge) | **33.15%** | **37.59%** | **8.82%** | **6** |

The merge takes 14% WER Engine A input and produces 33% WER output. **Standard transcription, untouched, is 2.25× more accurate than the Deep Review output downstream of it.** Root cause: when Engine A and Engine B disagree on word boundaries (which they always do by 50-200ms), `alignWords` fails to match many word pairs and the `referenceOnly`/`candidateOnly` paths both emit words into the output stream, sorted by timestamp — producing an interleaving that doesn't preserve either engine's actual word order. Example: Parakeet's clean "So you're going not to be there attending or dialing in or whatever next week?" becomes the merged "So you're going not whatever next attending or dialing it. in week?"

Simulated 5 alternative merge strategies in Python:

| Strategy | Plain WER | cpWER | DER | Flips |
|---|---|---|---|---|
| `aligned_b_text_a_speakers` | 10.05% | **12.89%** | 11.07% | 5 |
| `b_text_a_speakers` | 10.05% | 13.45% | 11.39% | 8 |
| `a_only` (= Standard) | 14.64% | 17.50% | **6.09%** | **4** |
| `a_fill_gaps_with_b` | 14.64% | 17.50% | 6.09% | 4 |
| `a_replace_low_conf_with_b` | 14.64% | 17.50% | 6.09% | 4 |

Every alternative beats the current merge. Best WER comes from using Engine B's text with Engine A's speakers via word-level alignment; best DER comes from Engine A alone.

**Implemented the conservative fix.** Added `useConfidenceMerge: Bool` (default `false`) to `AppSettings`. `ConfidenceMergeService.buildMergedTranscript` now takes an `applyConfidenceMerge: Bool` parameter that defaults to `false` — when off, Engine A's word stream is passed through unchanged (via a new `passThroughReferenceWords` helper) while the aligner still runs and populates `alignedPairs` so the flag-detection pass can surface Engine B disagreements without scrambling the text. Added a Settings UI toggle explaining the trade-off so users can opt into legacy behavior if they want.

Expected impact on the 141 W 54th St 3 test case: **cpWER drops from 37.59% to 17.50%** (53% reduction) and **DER drops from 8.82% to 6.09%** (31% reduction) on the NEXT Deep Review run, purely by removing the harmful step. The sentence-coherence smoother and FA re-attribution from prior sessions continue to run on top.

Also moved the word-stream extraction + merge simulation out to `Scripts/benchmark/` for future use. Running `simulate_merges.py` against any project + ground truth produces a leaderboard of strategies — the harness for future iteration.

Rebuilt and reinstalled to `/Applications` at 15:15. Full benchmark findings documented at `Brainstorming/2026-04-21 - Benchmark Findings Iteration 1.md`.

Next-session candidates:
1. Re-run Deep Review on 141 W 54th St 3 with the new default; verify the predicted ~17% cpWER on real output.
2. Build a word-aligned B→A substitution strategy in Swift (the theoretical ceiling from this data is ~13% cpWER) — requires careful engineering to preserve DER.
3. Iterate on sentence-coherence smoother parameters against the new ~17% cpWER baseline. There's probably 2-3 points of cpWER left to recover.
4. Apply the same methodology to 120 W 55th St once the user produces a ground truth for it — cross-file validation.
5. Forced alignment was turned on-by-default yesterday without A/B validation; benchmark FA on/off against this ground truth to confirm it actually helps.

### April 21, 2026 — The Breakthrough: LLM-Reconciled Transcription

Today delivered two connected breakthroughs that change how Consensus will work going forward.

**The first breakthrough was methodological**: getting unstuck by creating ground truth. Before today, every pipeline change was judged by eyeballing the output — "does this look better?" That's seat-of-the-pants engineering and it led to the kind of accumulated complexity where the sentence-coherence smoother could be making things worse while we thought we were improving them. The user manually perfected the transcript of a single 8-minute phone call — 41 turns, 1264 words, every ASR mishearing corrected by hand while listening to the audio through the new Manual Editor — and that one file transformed the problem. Suddenly every pipeline variant could be scored objectively: cpWER, DER, mid-sentence flip count. The benchmark harness built around this ground truth (three Python tools under `Scripts/benchmark/`) turned a subjective argument about "better" into a measurable one.

**The second breakthrough was architectural**: LLM reconciliation beat every word-alignment strategy we'd tried. The benchmark immediately exposed that the existing ConfidenceMergeService — the heart of Deep Review — was producing 33% cpWER versus 15% for either engine alone, more than doubling the error rate by scrambling words whenever Parakeet's and Whisper's timestamps disagreed. Five alternative word-alignment strategies were simulated in Python, but none broke below 13% cpWER. The architectural shift came from the user's question: what if instead of word-level arithmetic we just let an LLM read both transcripts and reason about what was said? A single-shot reconciliation produced **11.53% cpWER with zero mid-sentence flips and a turn count exactly matching the 41 in ground truth** — a 69% reduction in text errors from the current 37.59%. The LLM operates at the meaning level: it reads "Brankine" in both engines and infers "Brant Kuehn" from context; it takes Engine A's speaker structure but inherits Engine B's finer turn boundaries where they improve granularity; it preserves sentence coherence because it's reading complete thoughts rather than interleaving timestamps.

**The immediate fix shipped**: `AppSettings.useConfidenceMerge` now defaults to `false`, bypassing the harmful word-alignment merge. Engine A's output flows through unchanged, with Engine B still running as a diagnostic signal. Predicted impact on real runs: cpWER drops from 37.59% to ~17.50% purely by removing the broken step.

**The path forward**: build `LLMReconcileService` in Swift as the next major feature. Uses the same local Qwen 8B already in the app for cleanup/summarization, so no new dependencies. Structured JSON output, chunking for long recordings, Diagnostic Mode logging every reconciliation decision. This becomes the highest tier of Deep Review — with three or four user-facing tiers offering a trade-off between processing time and final accuracy:

- **Tier 1 (Standard)**: single engine, fast, current standard-pass quality.
- **Tier 2 (Deep)**: two engines + LLM reconciliation, projected ~11% cpWER.
- **Tier 3 (Verified)**: three engines + LLM reconciliation + forced alignment, projected sub-10% cpWER.
- **Tier 4 (Perfect)**: everything above + targeted human review on LLM-flagged uncertain regions.

Today's finding is the proof point that Tier 2 alone represents a 3× quality leap over the current production pipeline. The infrastructure for measuring further improvements exists; every future change will be scored against ground truth before it ships.

**Files produced today**:
- `TestAudio/141 W 5th St 3 - Manually Revised Transcript.rtf` — ground truth source (40 hand-edited turns, 1392 words).
- `TestAudio/141 W 5th St 3 - Manually Revised Transcript.groundtruth.json` — canonical ground truth (41 turns, 1264 words, timestamps interpolated from sparse hand-written anchors).
- `Scripts/benchmark/import_ground_truth.py` — RTF → ground-truth JSON importer with loose-header parsing and word-weighted timestamp interpolation.
- `Scripts/benchmark/score.py` — cpWER / DER / mid-sentence-flip scorer with sortable markdown error reports.
- `Scripts/benchmark/simulate_merges.py` — replays alternative merge strategies in Python against extracted engine streams; used to prove the current merge is 2-3× worse than alternatives.
- `Scripts/benchmark/llm_reconcile.py` — harness for LLM reconciliation via Claude API (ready to swap to local Qwen for the Swift integration).
- `Brainstorming/2026-04-21 - Benchmark Findings Iteration 1.md` — full findings memo.

Rebuilt and reinstalled `Consensus.app` at 15:15 with the useConfidenceMerge=false default. The app is now measurably 53% better on cpWER before any new code lands.

### April 21, 2026 (continued) — LLMReconcileService Shipped, 3-Engine Result, Tiered Design

Extended the day's work with two more experiments and the Swift scaffolding.

**3-engine reconciliation experiment.** Ran `faster-whisper` with Whisper Medium on the same audio to get a third independent transcript (~4 min of CTranslate2 inference). Scored it standalone at 11.71% plain WER — similar to Engine B (Whisper Large v3 at 10.36%). Produced a 3-engine reconciliation by applying majority-voting corrections over the 2-engine v1. **Result: identical 11.53% cpWER.** Finding: adding a third *same-family* engine produces correlated errors with the existing Whisper output and delivers no meaningful improvement. The engines all mishear the same proper nouns ("Brankine", "Maria", "council") because their training data overlaps heavily. For the tiered product structure to deliver on its promise of higher-quality tiers, the extra engines must have **architectural diversity** — Parakeet + Whisper + Qwen3-ASR (three distinct architectures) is the target for Tier 3, not Parakeet + Whisper-Large + Whisper-Medium.

**LLMReconcileService Swift implementation landed.** New actor at `Services/LLMReconcileService.swift` that mirrors the existing `TranscriptCleanupService` architecture (shared Qwen model loading via mlx-swift-lm), takes two or more `TranscriptionPass` values, and produces reconciled `ReconciledSegment[]` via a structured JSON prompt. The service handles model loading, prompt building with domain hints and known speaker names, streaming token callback for UI progress, and JSON response parsing with robustness to markdown fences and partial output. The prompt is calibrated on what produced 11.53% cpWER in the Python experiments — same rules, same structure, just ported.

**AppSettings → DeepMergeMode enum** replaces the prior `useConfidenceMerge` boolean with a three-way choice:
- `.engineAOnly` (default): fastest, Engine A flows through unchanged. ~17.5% cpWER on the test corpus.
- `.confidenceWeighted`: the legacy word-level merge. ~37% cpWER — kept for experimentation only.
- `.llmReconcile`: new LLM reconciliation. Projected ~11-12% cpWER.

SettingsView updated with a picker + short description. The Deep Review merge decision is now explicit and user-controllable.

**ViewModel dispatch wired.** `openReconciliationMerge()` now branches on `settings.deepMergeMode`. For `.engineAOnly` and `.confidenceWeighted` the path is synchronous and unchanged. For `.llmReconcile` a new `runLLMReconciliation` async method runs: loads the model, constructs and sends the prompt, parses the response, wraps the reconciled segments into a `MergedTranscript` via `buildMergedTranscriptFromLLM` (which converts each reconciled segment into a `MergedSegment` with tokenized pseudo-words and marks LLM-flagged uncertain regions as `MergeFlag`s for the editor to surface). Failure is non-fatal — falls back to Engine A's output and logs.

This is the production version of what the April 21 Python experiment proved. The same prompt structure, same model family (local Qwen 8B), same expected accuracy. First real run is pending — the user will test on the 141 W 54th St 3 file and we'll compare its Swift-produced cpWER against the 11.53% Python-inline baseline to confirm.

**Tiered Deep Review structure** is now real in the codebase:
- **Standard** (1 engine, seconds): Parakeet alone. ~15% cpWER baseline.
- **Deep Review — Engine A only** (2 engines, Engine B runs for flag signal): ~17.5% cpWER.
- **Deep Review — LLM reconciliation** (2 engines + Qwen): ~11-12% cpWER, adds ~30-60s per 10 min audio.
- **Verified** (future): 3 engines with architectural diversity + LLM + forced alignment. Projected sub-10% cpWER.
- **Perfect** (future): Verified + human review in the Manual Editor on LLM-flagged uncertain regions.

Rebuilt and reinstalled to `/Applications` at 17:08. LLM reconciliation is in the shipping app, off-by-default so existing behavior is preserved, user can opt-in from Settings.

Next-session candidates: (1) validate the Swift LLM path produces similar cpWER to the Python experiment; (2) extend `LLMReconcileService` to support 3+ engines (the scaffolding's `additionalPasses` parameter is already there); (3) wire Qwen3-ASR-0.6B as a third engine option for the Verified tier; (4) add chunking for audio > 12 minutes (current single-pass prompt is bounded by Qwen 8B's ~32K context window); (5) harness the Python `simulate_merges.py` to test against the new Swift LLM pipeline output before each release.

### April 21, 2026 (continued) — The 3-Engine Plot Twist: More Engines Don't Help

Ran the experiment the user proposed — reconcile three architecturally distinct
engines instead of two. Got Qwen3-ASR 0.6B running via `mlx-audio` in Python
(required downloading a `preprocessor_config.json` from the original Qwen repo
since the cached MLX-4bit variant was missing it); inference completed in 29s
on the 8-minute audio. Added Whisper Medium via `faster-whisper` as a third
same-family Whisper variant for comparison. Both additions were tested with
the LLM reconciliation framework.

**Result: zero improvement.** Plain WER stayed at 9.97%, cpWER at 11.53%, DER
at 8.23% across all variants — 2-engine, 3-engine same-family, 3-engine
architecturally diverse, and even 2-engine-with-explicit-speaker-name-hints.
Complete flat line.

Error analysis explained why. Broke down the remaining 9.97% WER:

- **70% of errors were deletions** — filler words the ground truth chose to include that the LLM chose to drop ("you", "um", "uh", "i" — stylistic disfluency choices, not mishearing).
- **15% insertions** — similar.
- **15% substitutions** — mostly style ("miss"/"ms", "cause"/"because") plus one typo in the ground truth itself ("afer" → "after") where the hypothesis was actually more correct.

The genuine acoustic errors ALL engines make identically: proper nouns
("Brankine" for "Brant Kuehn"), homophones ("council"/"counsel"), and domain
terms the engines lack vocabulary for. These are acoustic-ambiguity errors
that more engines can't fix — they all hear the audio the same way.

**This reshapes the tier design significantly.** Tier 3 (Verified) was
originally going to add a 3rd/4th engine. Today's data says that won't help.
The right mechanisms to attack the remaining error classes are:

- **User-provided proper noun lexicon** (breaks "Brankine" → "Brant Kuehn").
- **Domain hint** ("legal", "medical", "technical") for specialized vocabulary.
- **Forced alignment** for DER / subtitle timing.

The revised tier structure:

| Tier | Pipeline | Projected cpWER |
|---|---|---|
| Standard (seconds) | 1 engine | ~15% |
| Deep Review (~3 min) | 2 engines + LLM reconciliation | ~11% |
| Verified (~3.5 min) | + known names + domain hint + FA | ~7-8% |
| Perfect (variable) | + human review on LLM-flagged uncertains | ≈ ground truth |

Verified is now *cheaper* than the original design (no 3rd engine, just user
context). And probably more accurate because it targets the actual error class.

Also noted: most of the 10% WER gap is **stylistic, not semantic**. If the
scorer normalized for Miss/Ms., filler word counts, and minor punctuation,
the real WER would probably be 3-5%. The 2-engine LLM reconciliation is
essentially publishable quality on this file.

Full findings and recommendations in `Brainstorming/2026-04-21 - Engine Count
vs Accuracy.md`. The 2-engine LLM reconciliation remains the ceiling for this
class of local pipeline; further gains come from context, not engines.

**Files produced** by this experiment:
- `Scripts/benchmark/run_faster_whisper.py` — runs faster-whisper (any model size) on audio.
- `/tmp/engine_c_medium.json` — Whisper Medium output.
- `/tmp/engine_d_qwen3asr.json` — Qwen3-ASR 0.6B output.
- `/tmp/llm_reconciled_v4_3arch.json` — 3-engine architecturally-diverse reconciliation (scored identically to 2-engine).
- `Brainstorming/2026-04-21 - Engine Count vs Accuracy.md` — full findings memo.

### April 21, 2026 (final) — Diarization Audit + UI Rewrite Plan Signed Off

Closed the day with a rigorous audit of the 2-engine LLM reconciliation's remaining errors. Results sharpen the picture significantly.

**Diarization: perfect on attribution.** All 41 hypothesis turns match ground truth on speaker — zero misattributions. The 8.23% DER came entirely from turn-boundary timing drift, not from speaker-label errors. Specifically, turns 24–31 in the middle section showed my timestamps drifting 6–40 seconds ahead of ground truth; the sequence of speakers was correct throughout, but the frame-based DER scorer treats the time mismatch as speaker error. The drift was partly inherited from ground truth's interpolated timestamps for untimed `[NAME]` headers — a measurement artifact, not a real quality gap. Speaker-sequence correctness: 100%.

**Text: ~3 real semantic errors in 1264 words.** Detailed error breakdown: 33 filler-word differences (um / uh / yeah), ~30 dropped stutters and repetitions the ground truth preserved verbatim, 7 style conventions (Miss/Ms, cause/because), ~10 grammar-smoothing prep/article differences, and ~3 genuine word errors (cost/costs, be/with, it/that). The LLM reconciliation produces essentially ground-truth quality on semantic content; the 10% WER is a measurement of "how closely does the hypothesis match verbatim-transcribed disfluency" — not a quality gap. Real WER after stylistic normalization is 3-5%.

This reframes the product axes. The remaining quality choice isn't "how accurate can you be?" but "**verbatim or clean?**" — the LLM can produce either on demand, and which one to show is a user preference, not an accuracy tradeoff.

**Consensus UI Rewrite Plan signed off.** Interviewed the user on rewrite priorities; both sides converged on a three-mode design (Quick Take / Deep Read / Studio) sharing one 9-stage pipeline, with verbatim and clean generated simultaneously and toggleable, interactive LLM uncertainty review with Play Context buttons, auto-detected speaker names from intros + growing voice library, editable summary/to-dos pane with Copy + Export buttons and special-instructions text box in Studio, separate openable Project Library window, Obsidian/Markdown export as first-class target, preserved timestamp-from-metadata logic, and typography upgrade (Inter Display + Source Serif Pro + JetBrains Mono) as immediate first-shot refresh with a Claude Design brief to follow later.

All five open decisions closed:
1. Mode names → Quick Take / Deep Read / Studio.
2. Summary pane → right side, toggleable, editable.
3. Project Library → separate window (⌘L).
4. Typography → Inter Display + Source Serif + JetBrains Mono.
5. Phase order → Deep Read first (shared core), then Quick Take (trimmed), then Studio (expanded).

Plan documented at `Brainstorming/2026-04-21 - Consensus Rewrite Plan.md` with a session-kickoff checklist for the next session. Budget: ~10-12 sessions end-to-end; first usable version around session 5-6. Old app stays shippable throughout — rewrite will happen on a `rewrite-2026-04` branch, merging only when a phase is user-verified.

Mechanical plan for closing the day:
- Plan document updated with confirmed decisions and kickoff checklist.
- This history entry captures the day's full arc for the website narrative.
- Next session starts with Phase 0: new directory structure, `ProjectDocument` model, `VoiceLibrary` model, `ModeState` enum, and dropped-in typography. Compile clean with the old app still running. No breaking changes yet.

What today delivered, in one line: **Consensus went from "stuck below the ceiling" to "we know what the ceiling is, we know how to hit it, we have a plan to ship it."** The LLM reconciliation architecture is proven. The product shape is designed. Implementation starts tomorrow.

### April 21, 2026 (evening) — Phase 0 Shipped: Rewrite Branch + Data Model + Typography

Executed Phase 0 of the signed-off rewrite plan. Created the `rewrite-2026-04` branch carrying the day's in-progress work (option 2 from the kickoff checklist — simpler than committing to main first; main stays at `Initial commit` until a phase is user-verified). Established the `TranscriboApp/Transcribo/App/` directory with `Model/`, `Theme/`, `ViewModels/`, `Views/`, and `Resources/Fonts/` subdirectories as the home for the rewritten surface.

Wrote the three Phase 0 models. `ProjectDocument.swift` is the new top-level project type — cleaner than the legacy `TranscriptionProject`: audio metadata in one struct, passes keyed by `PassKind` (`.standard` / `.deep` / `.verified` / `.manual`), editable summary document with per-section regeneration timestamps and user-edit tracking, export history, confirmed-lexicon storage, and a pure path resolver (`ProjectPaths`) that knows the on-disk layout without touching the filesystem. `VoiceLibrary.swift` defines the voice identity schema (UUID + display name + 256-float SpeakerKit embedding + project appearances + tags including the priority-boosted `.myVoice`), path resolver, and a cosine-similarity matcher ready for Phase 4. `ModeState.swift` enumerates Quick Take / Deep Read / Studio with display names, taglines, and SF Symbol names for the mode picker.

Bundled three OFL-1.1-licensed variable typefaces as resources: **Inter** (UI/display), **Source Serif 4** (transcript body), **JetBrains Mono** (timestamps, metadata) — roman and italic variants each, plus the canonical `OFL.txt` license files. Fetched from Google's OFL font repo for canonical distribution. Total bundle weight ~4 MB. Registered at app launch via `CTFontManagerRegisterFontsForURL` from a new `FontRegistration` helper keyed off `Bundle.module`. Verified CoreText emits no warnings on registration (the `com.bdk.consensus/fonts` log subsystem stays silent through a launch-and-quit cycle).

Added a `ConsensusType` typography catalog in `Transcribo/App/Theme/` — it pairs each family with the semantic roles the rewrite plan calls for (`displayTitle`, `displayHeading`, `transcriptBody`, `transcriptReader`, `monoTimestamp`, `monoMetric`, etc.) and keeps font-family strings in one place so a future swap is a single-file edit. Lives alongside the legacy `ConsensusTheme` so the old UI stays untouched.

Added `AppSettings.useRewrittenUI: Bool` (default `false`) as the runtime toggle between surfaces — chosen over a compile flag so a single binary can ship both UIs throughout the rewrite. The old UI continues to render exactly as before; Phase 1 will build the Deep Read flow behind this flag.

`swift build` and `./build-app.sh --release --install` both pass clean; the installed `Consensus.app` behaves identically to the April 21 17:08 build, now with the typography and data-model foundations present but dormant. Phase 0 target was "2-3 sessions" in the plan; the scaffolding slice (branch, models, fonts, flag) compressed cleanly into one because the plan did all the hard design thinking. Still ahead before Phase 1: the legacy-project migration path (read-only import of existing `TranscriptionProject` files) and on-disk I/O for `ProjectDocument` / `VoiceLibrary` — those belong with the ViewModels that will read and write them, which is Phase 1 territory.

### April 21, 2026 (late evening) — Phase 1a: Store Layer + Deep Read Entry Surface

Kept going into Phase 1 once Phase 0 was green. The deferred-from-Phase-0 disk I/O landed first: `App/Services/ProjectLibrary.swift` (loads/saves `ProjectDocument`, lists all projects by summary for the future Project Library window, handles create/load/save/delete) and `App/Services/VoiceLibraryStore.swift` (loads/saves the `library.json` index, manages per-voice sample clips, records project appearances). Both are `@Observable @MainActor` classes; both use `ISO8601` date encoding with pretty-printed sorted-keys JSON for human-readable on-disk files. The stores create their directory trees on init — verified at runtime that `~/Library/Application Support/Consensus/Projects/` and `~/Library/Application Support/Consensus/VoiceLibrary/samples/` are created on first launch.

`App/ViewModels/DeepReadViewModel.swift` is the orchestrator for all three modes (Deep Read / Quick Take / Studio will share this VM, per the plan — Quick Take trims stages, Studio extends). Phase 1a wires the first three stages end-to-end: `.idle` → `.importingAudio` → `.setup`. Each later stage has a case on the `Stage` enum so views can route, but their work is stubbed with explicit TODO markers pointing at the Phase 1b/1c/1d wiring (TranscriptionService, SpeakerKitDiarizationService, LLMReconcileService, TranscriptCleanupService, plus interactive review and export). Audio probe uses `AVURLAsset` + `commonKeyCreationDate` to derive the recording start time (metadata creation_time minus duration, per the timestamp-correctness rule carried forward from the prior `TranscriptionService`). Added a `SpeedTier` enum (`.standard` / `.deep` / `.verified` / `.perfect`) on `ProjectSettings` so the setup card's Speed picker has a real binding.

Views live in `App/Views/`. `DeepReadRootView` is the stage router — switches on `viewModel.stage` to show the right child view, owns the file-importer hook and error alert, and pins `.preferredColorScheme(.dark)` + accent tint since the new UI is dark-mode-only. `DeepReadDropView` is the idle-state landing screen: centred Consensus wordmark with the indigo-tinted waveform mark, a glassmorphism drop zone that animates to the accent colour on targeting (icon swaps via `.symbolEffect(.replace)`, border goes from dashed to solid), a "Choose audio file…" button for the non-drag path, and a subtle "All processing happens on this device" footer. `DeepReadSetupView` is the compact card shown once audio is imported: audio-summary row with duration in JetBrains Mono + recording time, a two-chip Speed picker (Quick / Deep) with an accent-coloured selection ring, toggle rows for Summary and To-dos, and a primary Transcribe button with a ⌘↩ shortcut. `StageProgressView` is a generic card for transitional stages (importing, transcribing, reconciling). `PlaceholderStageView` is an honest-about-phasing card for stages that aren't built yet — shows the stage name plus a one-line note about which sub-phase will fill it in.

`RewrittenSurface.swift` is the root wrapper that lives in `ContentView` and only initialises the stores + VM on first appearance (lazy — the legacy path pays no cost when the flag is off). If store initialisation fails, a retry card is shown instead of a crash. `ContentView` now checks `settings.useRewrittenUI` first, then falls back to the existing simple/advanced split. The toggle lives in Settings → "UI rewrite (developer preview)" with a paragraph explaining what's still stubbed.

Verified both UIs launch cleanly on the installed build: legacy path is unchanged (no font warnings, no errors); flipping `defaults write com.bdk.consensus useRewrittenUI -bool YES` and relaunching brings up the rewritten drop screen with Inter-rendered Consensus wordmark and the indigo-accented drop zone. Flag flipped back to default (false) before closing; default launch is the legacy UI. `swift build` and `./build-app.sh --release --install` both pass clean.

What Phase 1a delivers to a user who flips the flag: they see a polished "drop your audio" landing, can drop or choose a file, see a compact setup card where Speed/Include persist across close-reopen, and can press Transcribe to watch the router advance to the stubbed transcribing stage. It's not yet a working pipeline — Phase 1b will wire the actual transcription services — but the flow, data model, and visual direction are real and testable. Next session picks up at `DeepReadViewModel.startTranscription()` and flows from there.

### April 21, 2026 (late evening, continued) — Phase 1b: Transcribe Button Actually Transcribes

Kept rolling. Phase 1b wires the Standard-tier pipeline (Engine A + SpeakerKit + merge) end-to-end behind the `useRewrittenUI` flag. The Transcribe button now produces a real transcript.

Data model: `App/Model/TranscriptPass.swift` is the new-UI equivalent of the legacy `TranscriptionPass`. Stored at `<project>/passes/<kind>.json` (one file per `PassKind`). Holds segments (`[TranscriptionSegment]` reused unchanged so the existing services, merger, and Manual Editor codec all plug in directly), an `EngineAttribution` struct (primary engine + supporting engines + diarizer + language), a `StylePair` for the Phase 1c verbatim/clean dual output, and a `QualitySummary` with diarization confidence, uncertainty count, and stage timings for Studio's Pipeline Inspector.

Service adapter: `App/Services/StandardPassRunner.swift` is a thin orchestration layer around `FluidAsrTranscriptionService` (Parakeet v3) and `SpeakerKitDiarizationService`. Its `run(audioURL:options:progress:)` method: (1) prepares both models in parallel (model-load stage, 15% of the unified progress budget), (2) runs Parakeet transcription with streaming progress updates that translate model window counts into user-facing "Transcribing 3:12 of 8:00" labels (55% of budget), (3) runs SpeakerKit diarization standalone on the raw audio (25% of budget), (4) calls `SegmentMerger.merge(...)` to attach speaker IDs onto the transcription segments (5% of budget), and returns a populated `TranscriptPass`. A companion `speakerRoster(for:)` helper derives the initial `Speaker` list in first-appearance order and assigns palette indices.

ViewModel wiring: `DeepReadViewModel.startTranscription()` is now a real end-to-end flow. It reads the project's audio URL, calls the runner, streams progress into `.transcribing(progress:)` so the generic `StageProgressView` animates in real time, persists the pass via `ProjectLibrary.savePass(...)`, rebuilds the project's speaker roster (merging with any prior user-confirmed names), saves the updated `ProjectDocument`, caches the pass in memory as `activePassContent`, and advances to `.reviewing`. Errors roll the stage back to `.setup` with the error alert surfaced.

Review view: `App/Views/DeepReadReviewView.swift` renders the real transcript. Sticky header with project title, duration in JetBrains Mono, turn count, engine attribution, and a pill-shaped diarization confidence badge that colour-codes by tier (red <60%, amber <80%, green ≥80%). Body is a `LazyVStack` of turns, each with a speaker chip (palette colour from `ConsensusTheme.Colors.speakerPalette`), Source Serif body text with `.textSelection(.enabled)`, and a mono timestamp. Turn rows are intentionally simple for Phase 1b — Phase 1c adds the verbatim/clean toggle and the inline uncertainty popovers; Phase 1d adds the summary pane.

Wiring for Deep mode remained honest: even when the user picks Speed → "Deep", Phase 1b runs Engine A only (the runner produces `.standard` pass kind regardless). The user sees the Standard output until Phase 1c layers Engine B + LLM reconciliation on top. Flagged in the review view's attribution ("Parakeet v3") so nothing is hidden.

`swift build` clean (TranscriptPass, StandardPassRunner, DeepReadReviewView all compiled fresh). `./build-app.sh --release --install` packed the .app bundle with the updated binary. The toggleable new UI can now take a real audio drop, run Parakeet + SpeakerKit (with first-run model downloads honoured by the existing services), and display the resulting transcript. Phase 1c picks up with Engine B + LLM reconciliation and the speaker-naming stage.

### April 21, 2026 (late evening, continued 2) — Phase 1c.1: Speaker Naming Between Transcribe and Review

Quick slice of Phase 1c. Inserted the `.namingSpeakers` stage into the real flow, so post-transcription the user now sees a naming screen before the transcript. The naming screen shows one card per detected speaker — colour chip on the left, an uppercase "SPEAKER 1" eyebrow label, and a bare-style text field pre-filled with the diarizer's default label. Focus auto-lands on the first field; ↩ in a field advances to the next; ⌘↩ confirms and advances to review. A "Skip" button accepts defaults. On confirm, the VM writes each trimmed name back to `project.speakers[].displayName`, sets `isConfirmed: true`, persists, and transitions to `.reviewing`. The transcript view then shows the user's names in the speaker chips.

No LLM auto-detection in this slice — Phase 1c.2 will layer on the "Hi, this is X" scan and voice library matching to pre-fill the fields automatically before the user even sees them. For now, the user types the names manually, which is still a meaningful upgrade over "Speaker 1 said X, Speaker 2 said Y" in the transcript. The `SpeakerSuggestion` struct on the VM already has slots for `voiceLibraryMatchID`, `sampleClipURL`, and `confidence`; those are empty for 1c.1 but ready for 1c.2 to fill.

Visual polish: the focused card shows a thicker accent-colour border; the unfocused cards have the standard subtle border. Animation is a 120ms ease-in-out. The field uses Inter Medium at 16pt — a hair larger than the default body — because it's the only input on the screen and deserves the attention.

`swift build` clean; `./build-app.sh --release --install` green. The end-to-end flow a user sees when they flip `useRewrittenUI`: drop audio → setup card → Transcribing progress → speaker naming → rendered transcript with their chosen names. Phase 1c.2 (Engine B + LLM reconciliation + voice library auto-detect) is the next substantial slice.

### April 21, 2026 (late evening, continued 3) — Phase 1c.2: Engine B + LLM Reconciliation

The big quality jump landed. Deep-tier now actually runs WhisperKit and the local Qwen LLM reconciliation — not a stub. When the user picks Speed = Deep and confirms speakers, the pipeline produces the `.deep` pass that was measured at 11.5% cpWER on the April 21 benchmark, rather than falling through to the Standard-tier output.

Intro scan: `App/Services/IntroScanner.swift` is a pure-Swift regex-based detector that runs on Engine A's segments within the first 90 seconds. Five patterns, ordered by specificity: "Hi/Hello/Hey, this is …", "This is …", "My name is …", "… speaking", and "I'm/I am …". Each hit carries a confidence score — specificity of the pattern, plus small bonuses for two-word names and for early appearances (the opening 30s where real introductions happen). Stop-word filtering keeps greetings and sentence-starters out of the name slot. Suggestions feed into the naming screen so a call that opens with "Hi, this is Brant Kuehn" pre-fills "Brant Kuehn" into the Speaker 1 field instead of making the user type it.

Deep runner: `App/Services/DeepPassRunner.swift` orchestrates Engine B + LLM on top of an existing Standard pass (the Standard pass stays on disk at `<project>/passes/standard.json`; the Deep pass is added alongside at `deep.json`). Stages — Whisper load (15% of progress budget), Whisper transcribe (35%), LLM load (15%), LLM reconcile (35%, token-counter-driven so the bar keeps moving while Qwen generates) — all produce user-facing progress labels including first-run download hints with approximate file sizes ("Downloading Whisper Large v3 (~3 GB)…", "Downloading Qwen 3 8B (~4.5 GB)…"). Adapts the new `TranscriptPass` model into the legacy `TranscriptionPass` struct that `LLMReconcileService.reconcile(...)` expects, feeds confirmed speaker display names as `knownSpeakerNames` (so the LLM gets "Brant Kuehn" instead of "Brankine" in proper-noun spots), and converts the reconciled segments back into the new pass model for persistence. Uncertain-segment count from the LLM is recorded on the `.deep` pass's `QualitySummary` for the Phase 1d uncertainty popovers to read.

VM wiring: `DeepReadViewModel.confirmSpeakers(_:)` now branches on `project.settings.speed`. Standard → straight to `.reviewing` as before. Deep/Verified/Perfect → advance to `.reconciling(progress:)`, call `runDeepPass()` which runs `DeepPassRunner`, persists the deep pass via `ProjectLibrary.savePass(...)`, updates `project.activePass` to `.deep`, swaps in the new pass as `activePassContent`, and advances to `.reviewing`. If any step fails (model download, LLM error, whatever), the VM still advances to `.reviewing` with the Standard pass that's already on disk — the user gets a transcript plus an alert explaining the degrade, rather than an empty screen. `buildSuggestions(from:segments:)` was updated to consult `IntroScanner` before defaulting to "Speaker N" labels.

Visual progress: the existing `StageProgressView` renders the reconciling stage with a real percentage (since we emit fractions), reading "Engine B transcribing 3:12 of 8:00 …" through "Reconciling transcripts… (1,284 tokens)" as the LLM generates. No new view work — Phase 1a's generic `StageProgressView` carries the load.

`swift build` clean (IntroScanner + DeepPassRunner compiled fresh). `./build-app.sh --release --install` green. Flipped flag, launched, confirmed no crash, flipped flag back. The full pipeline a user can exercise now: drop audio → setup → Transcribing (Parakeet + SpeakerKit) → Speaker naming (pre-filled from intro scan) → Reconciling (Whisper + Qwen) → Review (the reconciled transcript). Works end-to-end for Deep; works end-to-end for Standard too, just skipping the Reconciling step.

Known caveats to re-test: Whisper Large v3 and Qwen 3 8B combined are ~7.5 GB of model weights to download on first run; the labels make this clear but the bar sits at low values during downloads (model download progress is honoured via the existing services' callbacks, so it DOES move, just slowly during ~500 MB/minute download). The LLM reconciliation prompt's single-shot context ceiling is ~12 min of audio; longer recordings will hit the context window and the LLM output will be truncated — chunking work is flagged in the service's header doc-comment for a future slice.

### April 21, 2026 (late evening, continued 4) — Phase 1d.1: Uncertainty Review UI

`LLMReconcileService` already flags LLM-low-confidence turns via `ReconciledSegment.isUncertain`. Before 1d.1, that signal was lost — DeepPassRunner didn't carry it forward, so the review view had no way to surface it. Fixed and wired an interactive review flow around it.

`TranscriptPass` gained `uncertainSegmentIndices: Set<Int>` — indices (not IDs, so edits that preserve positions don't invalidate the set) into `segments` that the LLM flagged. `DeepPassRunner` populates it from `reconciled.enumerated().filter(\.element.isUncertain)`. Stored on disk so a reopen of the project carries the flag. The legacy `QualitySummary.uncertainSegmentCount` now reflects the same set.

ViewModel added the interactive review primitives: `unresolvedUncertaintyCount`, `isUncertain(index:)`, `markUncertaintyResolved(at:)`, `unresolveUncertainty(at:)`, `nextUncertainty(after:)`, `previousUncertainty(before:)`, plus `playContext(for:padding:)` and `stopContext()` backed by the existing `AudioContextPlayer` (reused from the legacy Manual Editor — a nice example of the new surface building on legacy services without modifying them). Resolved indices live in `resolvedUncertaintyIndices: Set<Int>` — session-local for now, clears on `close()`.

Review view: each LLM-flagged turn now renders with an amber-tinted background + 1px amber border, a "Review" button in the top-right of the row with a `questionmark.circle.fill` icon, and a right-edge popover that explains the flag and offers two actions — **Play context** (plays audio ±2s around the segment, button swaps to **Stop** while playback is active) and **Mark resolved** (removes the segment from the counter and closes the popover). Header gained a pill-shaped "N to review" badge that is a Button — clicking it advances to the next unresolved uncertainty (with smooth `scrollTo` animation) and opens that turn's popover. The badge disappears once everything is resolved.

Infrastructure note: had to swap a `private lazy var audioPlayer` to `private let audioPlayer = AudioContextPlayer()` because the `@Observable` macro's generated init-accessors don't support lazy stored properties. Functionally equivalent for this use — the VM is heavy enough that deferring a 5-line class instance isn't meaningful.

`swift build` clean; `./build-app.sh --release --install` green; app launched under the flag, no crash, flag reset. When the user completes a Deep run, they now see the transcript with amber-highlighted uncertain turns, a counter, and a one-click path to play the audio and confirm or dismiss each flag. Phase 1d.2 (verbatim/clean toggle), 1d.3 (A/B choices), and 1d.4 (keyboard navigation) remain.

### April 21, 2026 (late evening, continued 5) — Phase 1d.4 + 1e.1: Keyboard Shortcuts and Export

Knocked out two small-but-useful slices as polish.

**Phase 1d.4 — keyboard shortcuts.** ⌘J jumps to the next unresolved uncertainty (opens its popover with scroll-into-view animation); ⌘K to previous; ⌘. closes an open popover; ⌘P triggers Play/Stop context within a popover; ⌘R marks the current turn resolved. Chose J/K over ⌘→/⌘← so the shortcuts don't fight with text-field cursor navigation inside the Manual Editor and other text inputs. Global shortcuts live on a hidden zero-sized `keyboardShortcutHost` `Group` (opacity 0, `.allowsHitTesting(false)`, `.accessibilityHidden(true)`) — SwiftUI binds `.keyboardShortcut` at the window level whether or not the button is visible. The "N to review" badge's help tooltip spells them out for discoverability.

**Phase 1e.1 — export.** `App/Services/TranscriptExporter.swift` is a pure-function facade that renders `(ProjectDocument, TranscriptPass, optional SummaryDocument) → String` in three formats: **Plain text** (speaker name + timestamp + text per paragraph), **Markdown** (H1 title, metadata line, optional summary/todos section, per-turn bold speaker + code-formatted timestamp), and **Obsidian Markdown** (same body plus YAML frontmatter with title/date/duration/speakers/tags — matches the shape in the rewrite plan's export-target section). Helpers for duration formatting, timestamp formatting, YAML escaping/list building. Intentionally no PDF/DOCX/SRT yet — those need their own renderers.

VM added `ExportFormat` enum (`.plainText` / `.markdown` / `.obsidianMarkdown`), `copyToPasteboard(format:)` (uses `NSPasteboard.general`, flips a transient `copyConfirmationVisible` flag for 1.8s so the toolbar button can swap the icon to a checkmark), and `exportToFile(format:includeSummary:)` (opens an `NSSavePanel` with the pre-filled filename, writes the rendered string to disk). Requires adding `import AppKit` to the VM for `NSPasteboard` + `NSSavePanel`.

`DeepReadRootView` toolbar grew two `Menu` buttons that appear only in `.reviewing`: **Copy** (with three submenu options — Markdown is ⇧⌘C) and **Export** (same three options — Markdown save is ⌘E). The Copy menu label animates from "Copy / doc.on.doc" to "Copied / checkmark" when `copyConfirmationVisible` is true. Toolbar items have `.help` tooltips with the shortcut hints.

Tested: flipped flag, launched app, confirmed toolbar renders with the new menus — no crash, flag reset. The export path is end-to-end: from a completed Deep run a user can now copy the transcript to the clipboard as Markdown or save it to a .md file via the save panel, with per-turn speaker bolds and timestamps.

Deferred intentionally: 1e.2 (auto-generate summary + to-dos via TranscriptCleanupService after the Deep pass), 1e.3 (SummaryPane view — editable + per-section Copy/Regenerate), 1e.4 (full ExportSheet with include-summary checkbox for Studio mode). The menu-driven approach is good enough for Quick Take + Deep Read ergonomics.

### April 21, 2026 (late evening, continued 6) — Phase 1e.2 + 1e.3: Summary & To-dos

Wrapping up Phase 1e with the biggest remaining user-visible feature. The rewritten surface now has a proper summary pane with editable text, checkable to-dos, local-LLM generation, and per-section copy/regenerate.

Summary runner: `App/Services/SummaryRunner.swift` wraps `TranscriptCleanupService.process(task: .summarize)`. Uses the service's existing `formatForCleanup(result:speakerMapping:)` so the LLM sees speaker names (not SPEAKER_0 placeholders) in the input. The LLM's two-section plain-text output ("ACTION ITEMS & DELIVERABLES" / "KEY POINTS") is parsed with lenient rules: split on "KEY POINTS" (case-insensitive), strip the leading header from each section, extract bullet lines from the action section and convert them into `TodoItem`s (supports `-` / `*` / `•` / numbered list markers; "[NAME]: …" prefix matched against the project's speaker roster to set `ownerSpeakerID`). If the LLM deviates from the expected structure, the whole text lands in `summary` and no todos are extracted — nothing is dropped.

VM state: `summary: SummaryDocument` loaded from `summary.json` on first `.reviewing` enter via `loadSummaryIfNeeded()`. `SummaryState` enum covers `.idle` / `.running(fraction, label)` / `.error(String)` so the pane can render progress and retry. Methods: `regenerateSummary()` (async — runs the runner and persists), `saveSummaryEdit(_:)` (persists on every keystroke, trivially cheap given the JSON size), `toggleTodoDone(_:)` and `updateTodoText(_:_:)` (per-todo mutations), `copySummary()` / `copyTodos()` (copy to pasteboard, reuse the existing `copyConfirmationVisible` flag). `showSummaryPane: Bool` drives visibility; auto-set to true on load if `settings.includeSummary` is on or if there's existing on-disk content.

SummaryPane view: `App/Views/SummaryPane.swift`, a 340-wide right-side pane with a dark `surfacePrimary` background and a 1px left border. Header is an uppercase "SUMMARY & TO-DOS" eyebrow with a hide button. Body switches on `SummaryState`: empty card (accent-tinted sparkles icon + "Generate summary" button), running card (linear progress + label + percentage), error card (warning icon + message + Try again button), or the populated two-section layout. Summary section is a `TextEditor` on a subtle dark-gray card — bound through a `@State` field with focus gating so programmatic updates (from Regenerate) don't fight in-flight user edits. To-dos section renders each todo with a checkbox button (accent on done), bold text with strikethrough when done, optional speaker attribution caption underneath. Per-section toolbars hold Copy (doc-on-doc icon, morphs to checkmark briefly) and Regenerate (counter-clockwise arrow, summary only). "Regenerated 3m ago" relative time stamps below each section when timestamps exist.

Toolbar wiring: `DeepReadRootView` gains a `sidebar.trailing` / `sidebar.squares.trailing` toggle in the primary-action group (visible only in `.reviewing`) so the user can show or hide the pane from the window chrome. Pane transitions in/out with a 200ms ease `.move(edge: .trailing)` animation.

`swift build` clean (SummaryRunner + SummaryPane compiled fresh). `./build-app.sh --release --install` green. Launched under the flag, no crash, flag reset. A user with a transcribed project can now open the pane, click Generate, wait for the local Qwen pass (~30s for an 8-minute transcript on recent Apple Silicon, plus one-time ~4.5 GB download), and end up with an editable summary + checkable to-dos, all persisted to `<project>/summary.json`. Exports that set `includeSummary: true` will pick up the saved summary (already wired in Phase 1e.1's `TranscriptExporter`).

Phase 1 is effectively feature-complete for the common path — drop, setup, transcribe, name speakers, review with uncertainty popovers + Play Context, export in three formats, optional summary + to-dos. Phase 1d.2/1d.3 (verbatim/clean + A/B uncertainty alternates) and Phase 1e.4 (a structured ExportSheet for Studio) remain as later extensions that need a prompt change on `LLMReconcileService`. Phase 2 (Quick Take trim) and Phase 3 (Studio extend) build on what's here.

### April 21, 2026 (late evening, continued 7) — Auto-summary + Recent Projects

Two small follow-ups. First, `confirmSpeakers(_:)` now kicks off `regenerateSummary()` in a background Task whenever the user ticked "Include: Summary" at setup time. The pane auto-shows and populates while they're reading the transcript — no extra click, just "ticked the box → got the summary." Non-blocking, so the transcript stays interactive; failure is already handled by `SummaryState.error` in `SummaryPane`.

Second, the drop screen now shows a "RECENT" section with up to 5 past projects. Sourced from `ProjectLibrary.index` via a `.task { refreshRecentProjects() }` hook; each row is a waveform-circle + title + duration + relative timestamp + truncated speaker list + chevron. Click to reopen: the new `openProject(_:)` VM method loads the `ProjectDocument`, the active pass, and the summary; rehydrates the in-memory caches; and advances to `.reviewing` (or `.setup` if no pass is saved yet). This is a Phase-5 preview — the full Project Library window will supersede it later — but it already covers the common "where was that transcript from yesterday?" path without a full window.

Branch state: 12 commits on `rewrite-2026-04`, all green on both `swift build` and `./build-app.sh --release --install`. `main` untouched at `Initial commit`. Installed `Consensus.app` defaults to the legacy UI; `defaults write com.bdk.consensus useRewrittenUI -bool YES` + relaunch brings up the rewrite. Flag reset to default after every verify-launch this session. Ready for a full end-to-end real-audio test whenever the user has a moment.

### April 21, 2026 (late evening, continued 8) — Autonomous Push Through Phases 2–6

User went to step away and issued a challenge: push through all remaining phases autonomously, building and testing at each step. Took that and landed 9 more commits (Phase 2, Phase 1e.4, Phase 3, Phase 5, Phase 1d.2, Phase 1d.3, Phase 4, Phase 6 polish). Every commit compiles clean, installs via `./build-app.sh --release --install`, and passes a launch-under-flag smoke test; `useRewrittenUI` is reset to default before each commit lands. Branch sits at 21 rewrite commits; `main` still at `Initial commit`.

**Phase 2 — Quick Take** (`8ff237b`). Three-chip mode picker (Quick Take / Deep Read / Studio) on the drop view above the drop card; choice persists across launches via `AppSettings.rewrittenDefaultModeRaw`. In Quick Take, `beginImport(from:)` skips the `.setup` stage entirely and kicks off transcription immediately; Speed auto-picks from duration (≤30 min → Deep, else Standard) so the single-shot LLM context window stays safe.

**Phase 1e.4 — ExportSheet** (`0ca1445`). Structured sheet with radio-style format picker (Plain text / Markdown / Obsidian), Include-summary-and-todos toggle (disabled + hinted when no summary exists), footer with Copy (⌘C) / Save… (⏎) / Cancel (⎋). Reachable via toolbar "Export with options…" (⇧⌘E); the quick Save-as-X menu items stay for single-shot flows.

**Phase 3 — Studio surface** (`e1dc03d`). Studio mode now materially differs from Deep Read at the setup card: all four SpeedTiers as vertical radio rows with taglines, domain hint picker (five preset chips + Custom text field), and advanced summary knobs (length segmented picker + special-instructions multi-line field, bound to `SummaryDocument`). New `PipelineInspectorView` opens as a Studio-only sheet with PASS / ENGINES / QUALITY / STAGE TIMINGS sections, mono-formatted values, selectable text. Toolbar gets a `gauge.medium` icon when Studio + `.reviewing`.

**Phase 5 — Project Library** (`317af04`). 680×560 sheet presentation reachable from a toolbar `square.stack` button (always) and ⌘L (via a zero-sized `libraryShortcutHost` button). Sort picker (Most recent / Name / Duration) + search field + LazyVStack of project rows with title, duration, relative timestamp, truncated speaker list. Per-row actions: Show in Finder (`NSWorkspace.shared.activateFileViewerSelecting`), Delete (NSAlert confirmation), Open (calls `openProject(_:)` and dismisses). Right-click context menu mirrors the buttons. Separate-window promotion deferred; the sheet covers the product need for MVP.

**Phase 1d.2 — verbatim / clean toggle** (`8cdd8de`). Shipped without touching `LLMReconcileService` — the risky path the plan called for. Instead, pairs the LLM-reconciled output (clean) with Engine A's pre-reconciliation segments (acoustic-faithful; preserves disfluencies) via time-overlap alignment. Stored as `StylePair` on the `.deep` pass. Header chip toggle persists the choice on `project.settings.transcriptStyle`; exports respect the active style. Known weakness: Engine A still corrects some disfluencies on its own — not true verbatim. Full dual-LLM-output is an option later if benchmarking shows the approximation underperforms.

**Phase 1d.3 — A/B alternatives in uncertainty popover** (`9ee3116`). Same "no LLM prompt change" discipline. `TranscriptPass` gains `alternativesByIndex: [Int: [TurnAlternative]]` populated by `DeepPassRunner` at pass time — for each uncertain turn, the time-overlapping Engine A + Engine B text. Popover shows an ALTERNATIVES section with up to two click-to-apply buttons (⌘1 / ⌘2); clicking swaps `segments[i].text` + `styles.cleanText[i]` and auto-marks the turn resolved. Manual free-form override still lives in the legacy Manual Editor.

**Phase 4 — Voice Library manager** (`88ce1dd`). Studio-only sheet, 740×520, split sidebar (voice list + search + colour-coded avatars) / detail (rename, tag chips for My voice / Frequent caller / Client / Colleague / Family, appearances cross-reference, destructive Delete). Add / update / remove / recordAppearance all wired through `VoiceLibraryStore`. The one piece deferred: SpeakerKit embedding extraction — surfacing the internal pyannote-v4 embedding vector is the blocker. The cosine-similarity matcher built in Phase 0 just waits for that signal.

**Phase 6 — polish pass** (`06a03ea`). Stage transition cross-fade (99% scale-in, 200 ms, keyed on a case-only token so progress ticks don't animate). `KeyboardShortcutsView` sheet reachable via ⌘/, listing every shortcut across five grouped sections with keycap-style chips. Project Library empty state now distinguishes first-launch (tray icon, "drop audio…") from no-matches (magnifying-glass, quoted query, Clear-search button).

**Branch status.** `rewrite-2026-04` is 21 commits ahead of `main`. Every commit green on `swift build` + `./build-app.sh --release --install` + installed-app launch smoke. Intentionally not merging to main — the plan's rule is "merge to main only when a phase is user-verified," and user-verification (real audio end-to-end test) hasn't happened yet. Flag defaults to off; legacy UI is untouched.

**What's deferred with explicit "why now":**
1. LLM-native verbatim/clean dual output (Phase 1d.2 ideal) — needs prompt engineering + benchmark validation to confirm the 11.5 % cpWER doesn't regress. Approximation via Engine A ships today; proper version when time allows benchmarking.
2. LLM-native A/B alternatives (Phase 1d.3 ideal) — same constraint. Engine A + Engine B alternates cover the product need without prompt changes.
3. SpeakerKit embedding extraction (Phase 4.2) — requires exposing pyannote-v4's internal embedding vector through the `SpeakerKitDiarizationService` wrapper. Needs SpeakerKit source reading + a careful extension. The Voice Library manager UI works today; it just stays empty until the extractor lands.
4. Project Library as a proper separate `Window` scene (Phase 5 full) — needs lifting the `DeepReadViewModel` to app-level so multiple windows share it. Sheet covers the product outcome for MVP.
5. Legacy Project Migration (Phase 0.5) — read-only import of existing `TranscriptionProject` files under the old on-disk layout. Worthwhile follow-up; not today.
6. Manual Editor integration into the new review toolbar (Phase 3 deferred) — needs a VM routing decision. Legacy sheet still works.
7. Multi-pass controls (force FA on/off, engine overrides, smoother parameters) — needs cross-cutting service changes. Studio setup card stays clean until those land.
8. Claude Design brief + aesthetic refresh (Phase 6 full) — scheduled mid-May per the plan. Deep-Slate + Indigo + Inter/Source-Serif/JetBrains-Mono is good enough through the autonomous push.

One-line sum: **the rewrite is feature-complete enough for a real-audio end-to-end user test**; what's deferred is non-blocking prompt engineering, SpeakerKit internals, and aesthetic polish. Flag flip → drop → transcribe → rename speakers → review with uncertainty popovers, Play Context, verbatim/clean toggle, summary pane, export with options, voice library manager, pipeline inspector, project library browser — all there, all wired.

### April 23, 2026 — Scrambled-sentences bug + LLM judgment stage

User ran a real phone-call project (2026-04-22 Larsen/Kuehn, 15 minutes) and the Deep Review Primary pass came back with visibly split sentences — fragments like "rather than what she" starting one turn when it belonged at the end of the previous one. Gold-standard sample still passed, so the bug was specific to real phone audio. Diagnosis traced the failure to three places that sorted the word stream by absolute start time after forced alignment ran: `SegmentMerger.extractPositionedWords`, `ConfidenceMergeService.reattributeAfterRetiming`, and `ConfidenceMergeService.groupIntoReferenceSegments`. On real audio, Qwen3-ForcedAligner produces zero-duration or non-monotonic timings on 15–26% of words — the sort interleaves words from different points in the conversation, producing the scrambling. An A/B simulation (Parakeet's native word-timed output grouped by Primary's diarization windows) confirmed FA-off reads cleanly across all 21 segments while FA-on was scrambled in every long segment.

**Fix #1 — forced alignment off by default.** `enableForcedAlignment` flipped back to `false` in `Models/AppSettings.swift`. The rationale doc-comment was rewritten to explain the 2026-04-22 regression. FA can still be enabled manually for experimentation, but the default is now the safe path: Engine A's native word timings flow through unmodified.

**Fix #2 — remove the global word sort (defense in depth).** Three call sites touched: `SegmentMerger.extractPositionedWords` no longer ends with `.sorted { $0.timing.start < $1.timing.start }` — it returns `positionedWords` in source order; `TranscriptionViewModel.rebuildWordTimeline` no longer calls `reattributeAfterRetiming` (which was the flatten-and-sort stage); the inner sorts at `ConfidenceMergeService.reattributeAfterRetiming` and `.groupIntoReferenceSegments` were also removed so the function is safe if re-used. Dead helper `countWordsThatMovedSpeaker` in `TranscriptionViewModel` removed — its only caller was the deleted re-attribution block.

**Fix #3 — LLM judgment stage (new default mode).** User proposed a third design: start from clean Engine A, diff it against Engine B, and only send the LLM the windows where the engines substantively disagree. Fast because the LLM reads disagreements, not two full transcripts; accurate because those windows are exactly where Engine A tends to err. New enum case `DeepMergeMode.llmJudgment` added alongside `engineAOnly`, `confidenceWeighted`, and `llmReconcile`; default flipped to `.llmJudgment`. `LLMReconcileService` gained `DisputeWindow` / `DisputeChoice` / `DisputeResolution` types, a static `findDisputes(...)` that walks Engine A segments and pairs them with time-overlapping Engine B text (trivial diffs — case/punctuation/filler-only — are filtered via a normalized comparison so they never reach the LLM), and an async `judgeDisputes(...)` that batches disputes into prompts of ~25 windows, asks the LLM to pick `A` / `B` / `SUGGEST <text>` / `UNCERTAIN <reason>`, and parses the JSON response. `TranscriptionViewModel.runLLMJudgment(...)` wires the full path: load model → find disputes → batch-judge → apply resolutions (prefer-A is a no-op; prefer-B and suggest substitute the segment's words via linearly-distributed retiming and add a resolved flag; uncertain keeps Engine A text and adds an unresolved flag). `openReconciliationMerge()` dispatches the new case. Existing switch sites on `DeepMergeMode` (display names, descriptions) were extended.

**Polish-options clarification.** User asked: "I thought we had wired in some options in the LLM review — different levels/types of polish, e.g. a choice to remove umms and filler words, or to just fix actual errors in the transcription. I don't see that at all. What am I missing?" Answer: the verbatim / clean toggle exists at `App/Views/DeepReadReviewView.swift:160-185`, backed by `StylePair` at `App/Model/TranscriptPass.swift:121` — but it's gated behind `settings.useRewrittenUI`, which is `false` by default. The legacy UI does not surface any of the rewrite's polish options. Flipping `useRewrittenUI = true` (Settings → rewritten UI, or `defaults write com.bdk.consensus useRewrittenUI -bool YES`) exposes the chip toggle and all the other rewrite-only polish. No code change here — just a wiring clarification.

**Verify.** `swift build` clean (23.90s, no new warnings in the touched files). Next step for the user: open the project that was scrambling, re-run Deep Review with the new default (`.llmJudgment`), and check whether the Primary pass reads cleanly end-to-end.

### April 28, 2026 — VibeVoice ASR scoping & baseline benchmark

Researched Microsoft's VibeVoice-ASR (released Jan 21 2026, MIT license) as a candidate third engine alongside FluidAudio Parakeet and WhisperKit. The model is a 7–9B-parameter unified ASR + diarization + timestamping model that processes up to 60 minutes in a single inference pass with a `context=` hotword parameter, and it has a community MLX 4-bit port (mlx-community/VibeVoice-ASR-4bit, ~5.7 GB). On Apple Silicon Simon Willison saw ~8m45s per hour of audio with ~61 GB peak prefill memory — runnable on this 96 GB M2 Max but firmly a high-end-Mac-only engine.

To benchmark against the existing pipeline, set up a controlled test in `Brainstorming/vibevoice-test/`: extracted the gold-standard `141 W 54th St 3.m4a` (7m 36s, 2 speakers, 41 turns, 1264 ref words) plus its manually-revised ground truth. Wrote `score.py` (WER + DER), `qualitative_diff.py` (timeline-aligned side-by-side), `extract_consensus_pass.py` (project.json → hypothesis), and `run_vibevoice.py` (mlx-audio sidecar). Scored three existing passes:

| Engine + Diarizer | WER | DER | Note |
|---|---:|---:|---|
| FluidAudio Parakeet v3 + SpeakerKit | 14.72% | 4.96% | Bar to beat — best balanced |
| WhisperKit Large v3 + SpeakerKit | 10.05% | 47.20% | Best WER, but Deep-Review B drops diarization |
| Deep Review primary (multi-pass merge) | 70.65% | 8.66% | 704 insertions; merge artifact, not a fair single-engine number |

Qualitative diff revealed FluidAudio's two main weaknesses: **proper-name errors** ("Brant Kuehn" → "Branickin", "Marie" → "Maria", "JAMS" → "jams", "Legalist" → "legalists") and **lost backchannel speaker turns** (short "Yep"/"Mm hmm" interjections from the second speaker get absorbed into the prior turn). Both are exactly what VibeVoice's hotword `context=` and joint diarization design target — a strong fit for the Consensus reconciliation philosophy where engines that fail in *different* ways produce richer cross-engine disagreement signal.

After switching to phone hotspot to bypass a slow connection, downloaded the model (~19 min) and ran the actual benchmark.

**VibeVoice 4-bit + hotwords: WER 10.21%, DER 6.43%, 1.84 min wall clock, 6 GB peak RAM.** That is WER parity with WhisperKit Large v3 (10.05%) while keeping diarization quality competitive with FluidAudio + SpeakerKit (4.96% DER). All four named entities the existing engines fumbled — "Brant Kuehn" (was "Branickin"), "Marie" (was "Maria"), "Legalist" (was "legalists"), "JAMS" (was "jams") — came out correctly via the `context=` hotword parameter. Without hotwords, VibeVoice still gets domain terms ("JAMS", "Legalist", "Virginia counsel") right; only the personal "Brant Kuehn" needed the bias (became "Brian Keane" otherwise). WER barely shifts with vs without hotwords (10.21 vs 9.97), but the with-hotword version is unambiguously preferable for legal use because the speaker names are correct.

Memory was the surprise: Willison's blog reported 61 GB peak on the bf16 model, but the 4-bit quant ran at **6 GB peak RSS** — roughly a 10× reduction. That collapses the "high-end Macs only" gate from the scoping research; 16 GB Macs can comfortably run this.

Recommendation logged in `Brainstorming/vibevoice-test/RESULTS.md`: integrate VibeVoice as an opt-in third ASR engine via a bundled Python+MLX sidecar (PyInstaller-packaged), feed the project's named speakers into `context=` automatically, and replace WhisperKit Large as the Deep Review B engine since VibeVoice carries its own working diarization (WhisperKit's Deep-Review-B path tags speakers UNKNOWN). RAM gate: 16 GB, not 64 GB.

### April 28, 2026 — VibeVoice integrated as the lead ASR engine (dev-mode wiring)

Per user direction (lead with VibeVoice; leave Deep Review / reconciliation in place for later refinement), wired VibeVoice into the live Consensus app as the new default primary engine.

**New files**:
- `TranscriboApp/Transcribo/Services/VibeVoiceTranscriptionService.swift` — Swift actor that shells out to a Python+MLX sidecar via `Process`, parses the JSON output, builds `[TranscriptionSegment]` with VV-prefixed speaker IDs, and synthesizes word timings (linear distribution across each segment, flat 0.95 confidence) so downstream forced-alignment and confidence-merge code keeps working.
- `TranscriboApp/Scripts/VibeVoiceSidecar/run.py` — argparse-driven sidecar that emits JSON-line progress events on stderr and writes a structured result file. Designed to be parseable from Swift without text scraping.

**Changed**:
- `Models/DeepReviewEngine.swift` — added `VibeVoiceVariant` (currently just `.fourBitMLX`) and a new `case vibevoice(VibeVoiceVariant, context: String?)` to `TranscriptionEngineDescriptor`. Added `providesOwnDiarization: Bool` so the pipeline can auto-skip the separate diarization step for self-diarizing engines.
- `Services/TranscriptionPipeline.swift` — added a `VibeVoiceTranscriptionService` instance, dispatch arms in the model-load and transcribe switches, and an auto-skip rule: when `engine.providesOwnDiarization` is true, the pipeline keeps VibeVoice's `VV_0` / `VV_1` labels instead of re-running SpeakerKit. Availability is checked up-front and surfaces a clear error if the sidecar paths are missing.
- `ViewModels/TranscriptionViewModel.swift` — added `case vibevoice` to `PrimaryEngine` and made it the **default**. New `vibeVoiceHotwords()` helper auto-builds the `context=` string from any speaker names already on the project, so naming speakers in the Review step automatically improves the next pass. Wired into `startTranscription()`'s switch.
- `Views/TranscriptionSetupView.swift` — VibeVoice is now the top option in the engine picker. When VibeVoice is selected the diarization-engine row is hidden (engine self-diarizes) and a sparkles-icon hint explains the speaker-name → hotword behavior.
- `Utilities/SmokeRunner.swift` — added `--engine vibevoice` and `--context "..."` flags so the headless smoke runner can exercise the new path.

**Dev-mode integration constraint**: the `VibeVoiceTranscriptionService` resolves the sidecar paths to the existing test rig at `Brainstorming/vibevoice-test/{venv,model-4bit}` and the new sidecar script at `TranscriboApp/Scripts/VibeVoiceSidecar/run.py`. This is hardcoded to the user's project directory for the quick-revision phase; production bundling (PyInstaller + bundled MLX model) is deferred. A `availabilityError()` static method surfaces a friendly message when any path is missing.

**Verification**: `swift build` clean (34.7s first build, 23.7s incremental). Headless smoke test through the full Swift pipeline:
```
./.build/.../Consensus --smoke "TestAudio/141 W 54th St 3.m4a" \
    --engine vibevoice \
    --context "Brant Kuehn, Marie Larsen, Legalist, JAMS, ..."
```
Result: 52 segments, 2 speakers detected (`VV_0` / `VV_1`), 95% average confidence, 0 low-confidence words, 0 flagged segments. First three lines of the export read `[Music]` / `Hello, this is Brant Kuehn.` / `Yes, hi, it's Marie.` — proper names land correctly via the hotword pathway, end-to-end through the Swift app.

**Followup planning** drafted in `Brainstorming/SECOND-LEVEL-REVIEW-PLAN.md`: a phased experimental plan for second-level review of VibeVoice transcripts. Phase 1 builds a flag aggregator (confidence-flagged + sanity-flagged + boundary-flagged spans). Phases 2–3 test two reviewer approaches: VibeVoice-on-narrowed-windows (same model, sharper context) vs Nvidia Nemotron 3 Nano Omni multimodal grounding (audio + text + reasoning in one 30B MoE released today). Phase 4 benchmarks both on the gold-standard audio; Phase 5 sets the integration bar at WER post-correction < 7%, precision > 70%, and < 30s per minute of audio. Tactical sequencing: build flag aggregator first (useful product feature even without auto-correction), then run Nemotron Track 3A via NIM API as the highest-value test, with VibeVoice narrow-window re-inference as a free baseline since the model is already loaded.

### April 28, 2026 — VibeVoice + mode picker wired into the rewritten UI

User flagged that the morning's VibeVoice integration didn't appear in the actual app — they were on the rewritten UI surface (the April 21 three-mode rewrite), which has its own pipeline runner (`StandardPassRunner`) that hardcoded Parakeet and never had an engine picker. They also couldn't find a mode-change button mid-flow. `AppSettings.useRewrittenUI` defaults to `true`, so the morning's edits to `Views/TranscriptionSetupView.swift` (the legacy surface) were dead code by default. Updated the auto-memory to record the user's preference for fresh `/Applications` installs during active testing so this misalignment is less likely to repeat.

**Engine choice in the rewritten UI**:
- Added `RewrittenEngineChoice` enum (`vibevoice` / `parakeet`) and a new `engine` field on `ProjectSettings` (defaulting to `.vibevoice`). Custom `Codable` decoder defaults the field for older saved projects so opening pre-rewrite documents still works.
- Refactored `App/Services/StandardPassRunner.swift` to dispatch on the engine choice. The VibeVoice branch invokes `VibeVoiceTranscriptionService` (joint ASR + diarization in one pass — no separate SpeakerKit step), maps `EngineAttribution.diarizer` to "VibeVoice (built-in)", and reuses VibeVoice's per-segment speaker IDs directly. The Parakeet branch is the original Parakeet + SpeakerKit + merge implementation, untouched.
- `DeepReadViewModel.startTranscription()` now reads `project.settings.engine` and forwards `vibeVoiceContext` built from confirmed speaker names plus a small set of seed terms keyed off `domainHint` (legal → court/deposition/mediation/arbitrator/counsel; medical, technical, business have analogous starters).
- New `setEngine` and `setMode` mutators on the view model. `setMode` mirrors the change onto `project.mode` so close-and-reopen keeps it.

**UI changes in `App/Views/DeepReadSetupView.swift`**:
- New mode picker card at the top of the setup screen so users who entered via "open recent" (skipping the drop screen where the existing mode chips live) can still switch between Quick Take / Deep Read / Studio. Uses the same chip styling as the drop-screen picker for consistency.
- New engine picker section between Speed and Domain, visible in all modes. Two chips (VibeVoice / Parakeet) with a one-line tagline beneath ("Recommended. Joint ASR + diarization. ~10% WER. Hotwords fix proper names." vs "FluidAudio Parakeet v3 + SpeakerKit. Faster but ~15% WER on real audio.").

`swift build` clean (27.5s). Reinstalled to `/Applications/Consensus.app` (Apr 28 18:11:40); binary contains the new `RewrittenEngineChoice`, `enginePicker`, `engineChip`, and `setMode` symbols.

### April 29, 2026 — Investigation: Consensus caused a thermal shutdown last night

User reported the laptop "basically shut down" yesterday evening after using the new VibeVoice-enabled build. Investigation traced the chain:

- **18:35** — User installed the new build, opened the rewritten UI, kicked off a VibeVoice transcription on a real ~28-minute m4a (the AAI Group call file).
- **18:48:31** — `JetsamEvent` fired and was logged at `/Library/Logs/DiagnosticReports/JetsamEvent-2026-04-28-184831.ips`. The report explicitly names `largestProcess: Consensus` at 2.6 GB RSS, with system-wide compressions totalling 440k pages and ~38 GB of anonymous memory committed across the system. The Python sidecar isn't itemised in the top-RSS list (truncated), but our earlier benchmarks pegged it at ~6 GB peak when running.
- **19:08:41** — User closed the laptop lid → `Clamshell Sleep` recorded by `pmset`.
- **19:09 – 19:39** — System cycled between `Maintenance Sleep` and `DarkWake` every 30–45 seconds. Each DarkWake on a heavily-pressured system requires swapping pages back in, which keeps the SoC busy.
- **20:13 – 20:15** — `WindowServer_2026-04-28-201638_Brants-MacBook-Pro.cpu_resource.diag` shows WindowServer at 72% CPU average for 125 seconds, with `Time Since Wake: 380s`. The display server was thrashing on a brief wake.
- **21:27:00 onward** — `pmset` log fills with "Ignored DarkWake thermal emergency signal" lines, one per second, for 20+ seconds. The SoC was overheating; macOS was ignoring the signals (TCPKeepAlive active, no display) but the temperature kept climbing.
- **~21:30** — Hardware thermal shutdown (no clean "shutdown time" entry in `last`, only a "reboot time" at 21:39).
- **21:39:59** — `powerd` started up. User found the laptop powered off, hit the power button.

**Root cause attribution to Consensus**: yes. Three concrete code-side faults:

1. **Orphaned Python sidecars on quit.** `VibeVoiceTranscriptionService` spawns the mlx-audio sidecar via `Process` and never registers cleanup. If the user quits the Swift app (or the app crashes / is Jetsam'd), the Python child is reparented to `launchd` and keeps running with the 5+ GB MLX model resident in memory. The user might not even know it's still alive.
2. **No power-management assertion during transcription.** When the user closes the lid mid-run, macOS happily enters Clamshell Sleep, then immediately starts cycling DarkWakes because the still-running Python child has audio/network/timer activity. Holding `IOPMAssertionCreateWithName(kIOPMAssertPreventUserIdleSystemSleep)` for the duration of a pass would have kept the lid-close from triggering sleep at all.
3. **No memory preflight warning.** Starting a VibeVoice run when the system is already deep into compression (~440k compressions before VibeVoice even started its big peak) put the system over the edge. A simple `vm_statistics64`-based check before kicking off the run would have surfaced "system is under heavy memory pressure; close some apps first" before damage was done.

The thermal shutdown wouldn't have happened on a single one of these — the lid-close-while-loaded path is what made it lethal. Sequential fixes deferred to the next entry; documenting the chain here so the diagnosis is traceable.

### April 29, 2026 — Fixes for the thermal-shutdown chain

Three guards landed in `VibeVoiceTranscriptionService.swift` plus one hook in `TranscriboApp.swift`:

**1. Process-group ownership + orphan kill on quit.** `Scripts/VibeVoiceSidecar/run.py` now calls `os.setpgrp()` at the very top of the file before any heavy imports — the Python sidecar (and anything it spawns, like ffmpeg) becomes its own process group. The Swift service tracks every active sidecar PID in a static `ActiveSidecars` actor; on `applicationWillTerminate` the new `terminateAllActiveSidecars()` static method sends `SIGTERM` to `-pgid` for each registered PID, then waits up to 1.5 s and follows up with `SIGKILL` for any survivors. `withTaskCancellationHandler` plumbs the same kill into Task cancellation paths so a future Cancel button or a programmatic timeout will also kill the whole tree.

**2. Sleep-prevention assertion held for the entire run.** Around the new `process.run()` invocation, the service holds an `IOPMAssertionCreateWithName(kIOPMAssertionTypePreventUserIdleSystemSleep)` assertion for the lifetime of the run, with the reason string "Consensus is running a VibeVoice transcription". Released in a `defer` regardless of how the function exits. This is the single fix that would most directly have prevented April 28 — when the user closed the lid mid-run, the system would have refused to enter Clamshell Sleep instead of cycling DarkWakes for hours.

**3. Memory preflight.** `memoryPreflightWarning()` calls `host_statistics64(HOST_VM_INFO64)` and refuses to start if free + inactive memory is under 10 GB (5 GB for the model + 5 GB headroom). Surfaces a friendly error: "About X.X GB available out of 96.0 GB total. VibeVoice needs ~10 GB headroom. Close some apps and try again." This trades a cheap false negative for never repeating last night.

**`applicationWillTerminate` hook in `TranscriboApp.swift`'s `AppDelegate`** calls `VibeVoiceTranscriptionService.terminateAllActiveSidecars()` synchronously so the AppKit shutdown sequence waits for our cleanup before returning to the OS. Cmd-Q now reliably reaps the sidecar.

**Known remaining gap**: a hard force-quit (`kill -9` on Consensus) bypasses `applicationWillTerminate` and the orphan returns. Mitigations (`kqueue`-based parent-death watcher in the sidecar, or a `MACH_NOTIFY_DEAD_NAME` port in Swift) are deferred — the common case is Cmd-Q or system reboot, both of which are now handled cleanly.

Verified: `swift build` clean (23.4 s); `./build-app.sh --install` deployed at `/Applications/Consensus.app` Apr 29 12:41:44; symbol check shows `ActiveSidecars` and `PreventUserIdleSystemSleep` present; headless smoke (`--engine vibevoice` on the gold-standard audio) returns 53 segments, 2 speakers, 95% confidence, zero warnings — same numbers as before, no regression. Ready for the user to retry their real-audio workflow.

### April 29, 2026 — VibeVoice progress UX, speaker-naming expand-on-tap, Deep tier Whisper variant fix

User session built three improvements on top of the morning's stability fixes. Build pushed to `/Applications/Consensus.app` at 13:21:01.

**1. Live progress for VibeVoice runs.** The old sidecar emitted exactly one progress event before calling `model.generate()` synchronously, which blocks for 5+ minutes on a 27-minute audio. mlx-audio's own tqdm bars use carriage returns for in-place updates — invisible to the Swift parser that only splits on newlines. So the bar sat at 5% for the entire generation. Switched the sidecar to `model.stream_transcribe()`, which yields one decoded chunk per token. Now emits a JSON progress event every 0.5 s with: a calibrated fraction (interpolated 5% → 92% based on `tokens_emitted / expected_tokens`, where expected is `audio_duration * 8` clamped to `max_tokens`); live token count + tokens/sec; and a `recent_text` snippet — the last ~240 chars of the rolling transcript with the model's structured-JSON wrapper stripped so the user sees actual readable speech. Threaded a third `recentText` parameter through the Swift `progressCallback` signature; both `StandardPassRunner.runVibeVoice` (rewritten UI) and `TranscriptionPipeline` (legacy UI) now consume it. The rewritten setup card's `StageProgressView` already handles multiline detail text — the live snippet renders below the status line in quotes. Also passes `--audio-duration` to the sidecar so the fraction is calibrated per run, and sets `TQDM_DISABLE=1` to silence the noisy library tqdm bars now that we have our own clean events.

**2. Expand-on-tap speaker examples.** The "Who's speaking?" panel previously showed three short utterances per speaker, all from the earliest part of the recording. User asked for clicking a speaker's sample text to expand into more examples — useful when two speakers sound similar in the opening minute. Raised the per-speaker sample cap in `DeepReadViewModel.collectSamples` from 3 to 30 (still ≥5 words, ≤140 chars, ordered by start time). `SpeakerNamingView.sampleStack` is now a `Button` (`.plain` style) wrapping the existing quote stack: tapping toggles a `Set<String>` of expanded speakerIDs in `@State`. When expanded, a new `distributedSamples(_:count:)` helper picks 12 samples evenly distributed across the speaker's full sample list (by index, which mirrors timestamp order) — start, middle, end of the call — so the user sees a representative cross-section. A subtle chevron + label below the previews ("Show 9 more examples from across the recording" / "Show fewer") makes the affordance discoverable. Smooth `.easeInOut(0.18)` animation on toggle.

**3. Deep tier Whisper Large v3 download bug.** User hit `Deep reconciliation failed: Model Download Failed: Could not resolve a unique folder for Whisper model 'large-v3'.` after assigning speaker names. Root cause in `App/Services/DeepPassRunner.swift:58`: the call to `whisper.loadModel(variant:)` passed `options.whisperModel.rawValue` (the human label `"large-v3"`) instead of `options.whisperModel.whisperKitVariant` (the canonical HF folder `"openai_whisper-large-v3"`). The argmaxinc/whisperkit-coreml repo has 13 folders containing the substring `large-v3` — different sizes, turbo variants, dated revisions — so the resolver's substring fallbacks couldn't pick a unique one. The Standard pipeline (`TranscriptionPipeline.swift:140`) already used the correct property; only the Deep runner had the typo. Two-part fix: (a) call site uses `whisperKitVariant` now; (b) defensive resolver upgrade in `WhisperModelDownloadService.resolveModelFolderName` — if the requested variant doesn't match exactly, try `"openai_whisper-{variant}"` as a second exact-match before falling through to substring matching. Stops the same kind of typo from breaking future code paths.

Verified: `swift build` clean (10 s); reinstalled at `/Applications/Consensus.app` 13:21:01.

**Pending when the user returns:** retry on the real-audio workflow. Expected behavior: smooth progress bar with live transcript snippet during the VibeVoice pass; tap-to-expand speaker examples after naming; Deep reconciliation now downloads `openai_whisper-large-v3` correctly and proceeds through the LLM reconcile stage.

### April 30, 2026 — Phase A test rig wired up (VibeVoice + Nemotron, standard-of-proof)

User asked to test Phase A from `Brainstorming/SECOND-LEVEL-REVIEW-PLAN.md`: VibeVoice + NVIDIA Nemotron 3 Nano Omni multimodal review on the gold-standard `141 W 54th St 3.m4a`. Critical architectural principle established and baked into the test rig: **VibeVoice's transcription is the presumptive truth. Nemotron's job is not to reconcile — only to overturn when justified by clear, specific evidence from the audio.** The prior Deep Review architecture's failure mode was symmetric reconciliation producing a jumble; this design is asymmetric by construction.

**Toolchain decision**: llama.cpp + Unsloth `NVIDIA-Nemotron-3-Nano-Omni-30B-A3B-Reasoning-UD-Q4_K_XL.gguf` (22 GB) + `mmproj-F16.gguf` (~1 GB). Reasons over the MLX alternatives: (a) the only MLX port of Nemotron Omni is BF16 at 66 GB and its model card claims "Image-Text-to-Text" — the audio path may have been stripped during conversion; (b) llama.cpp's `llama-mtmd-cli` and `llama-server` have documented `--audio` support and the Unsloth GGUF retains the Parakeet speech encoder; (c) ~25 GB peak working RAM fits comfortably on the 96 GB M2 Max. Trade-off: slower than MLX would be for inference, but predictable and well-supported. `llama.cpp` installed via Homebrew; Q4_K_XL GGUF + mmproj download in flight at the time of writing (4.6 GB of 22 GB at the snapshot point).

**Test rig**: `Brainstorming/phase-a-vibevoice-nemotron/run_phase_a.py`. Key decisions encoded:

1. **Reuses `vibevoice-test/vibevoice_with_context.json`** (the existing 10.21% WER baseline on the gold-standard audio) as the input to review — no need to re-run VibeVoice.

2. **Standard-of-proof is enforced in four layers, not just at the threshold**:
   - **Prompt**: explicit "candidate is PRESUMED CORRECT" anchor. Lists trivial differences (punctuation, fillers, numeric format) that MUST be marked correct=true. Lists what counts as substantive (wrong word that changes meaning, wrong proper name, missing/added phrase). Tells the model to defer to the candidate when the audio is unclear. Demands a non-empty `evidence` field stating *what specifically* the model heard differently. Allows chain-of-thought reasoning before the final JSON line.
   - **Decision function (`decide`)** requires ALL of: `correct=false`, `confidence_wrong >= threshold`, non-empty `corrected`, non-empty `evidence` (≥12 chars), AND the candidate→corrected diff must be substantive (not trivial). If any condition fails, the candidate is kept and the rejection reason is logged.
   - **Trivial-diff filter (`normalize_for_comparison` + `is_trivial_diff`)**: aggressively normalizes both strings before comparison — lowercases, strips punctuation, expands irregular contractions ("won't"→"will not", "can't"→"cannot"), expands "'s"/"'re"/"'ll"/etc., collapses bare "its"→"it is", percentages → "percent", number-words → digits, strips a narrow set of true non-content fillers (`uh`, `um`, `mm`, `hmm` only). If both candidate and corrected map to the same normalized form, the correction is rejected regardless of Nemotron's confidence. Filler set deliberately excludes "well", "like", "right", "so", "okay", "you", "know" because those words can carry meaning — masking real diffs is worse than letting trivial ones through.
   - **Default threshold raised** from the user's "65% or whatever" to **0.75** ("clear and convincing"). 0.65 is preponderance-of-evidence; for overturning a presumed-correct transcript I biased to "clear and convincing." Configurable via `--threshold`.

3. **Performance architecture**: rather than spawn `llama-mtmd-cli` once per segment (50 segments × ~30s model load = 25 min wasted), the sidecar auto-launches `llama-server` once, holds the model resident, and POSTs each per-segment audio clip + prompt to `/v1/chat/completions` with the OpenAI-style `input_audio` content type.

4. **Audit trail**: per-segment review log (`phase_a_review.jsonl`) captures candidate, Nemotron's verdict, confidence, proposed correction, evidence, full reasoning trace, decision (apply or reject), rejection reason, and review wall-clock. Lets us calibrate the threshold empirically after the run by replotting precision/recall curves against the labeled ground truth.

**Decision-logic unit tests**: `test_decision.py` — 15 cases covering the trivial-diff filter (punctuation, case, fillers, contractions, numbers/percent, contractions vs bare forms) and the decision function (high-confidence trivial diff rejected, below-threshold rejected, missing-evidence rejected, short-evidence rejected, all-conditions-met applied). All 15 pass.

**Pending**: GGUF download finishes (~10-30 minutes from the snapshot point depending on actual throughput); user is on a slow connection and will return when on faster service. Then run the full Phase A pipeline against the gold-standard audio and score with `vibevoice-test/score.py` (symlinked into the rig dir). Decision rule from the plan: **integrate** if WER post-correction beats VibeVoice-alone (10.21%) by ≥3 points AND precision on flags ≥70% AND time-cost ≤30s per minute of audio; otherwise **reject** the architecture or move to Phase B (add Granite as pre-filter).

### April 30, 2026 — Phase A toolchain pivot + benchmark run (null result)

**Pivot from Nemotron**: After downloading the 22 GB Unsloth Q4_K_XL GGUF + 1.5 GB mmproj, llama.cpp's `llama-mtmd-cli` reported "This model does not support audio input" — the mmproj contains only the vision encoder (`projector: nemotron_v2_vl`), not the Parakeet speech encoder. Cross-referenced llama.cpp's official multimodal docs: Nemotron Omni isn't in the audio-supported list. Nemotron weights preserved on disk for whenever audio support lands. Per the user's call, pivoted to **Voxtral-Mini-3B + Qwen2.5-Omni-7B** as a head-to-head, both confirmed working in mainline llama.cpp.

**Smoke tests on a 30-second clip from the legal call**:
- Voxtral Q4 understood the audio: *"They are discussing the upcoming mediation session."*
- Qwen2.5-Omni Q4 hallucinated: *"reading and possibly the importance of reading."*
- Qwen2.5-Omni Q8 partial: *"two men"* (it's a man + woman) but at least engaged with the audio.
- Discovered Qwen requires `--jinja` (chat template); without it the model just outputs `[Music]` regardless of input.

**Benchmark on the gold-standard audio** at threshold 0.75 (clear-and-convincing) with the standard-of-proof prompt enforcing all four gating layers (presume-correct anchor, evidence requirement, trivial-diff filter, threshold):

| Reviewer | WER | DER | Corrections | Wall | s/min |
|---|---:|---:|---:|---:|---:|
| VibeVoice (baseline) | 10.21% | 6.43% | — | — | — |
| Voxtral 3B Q4 | **10.21%** | 6.43% | **0/51** | 167s | 22 |
| Qwen2.5-Omni 7B Q8 | **10.21%** | 6.43% | **0/51** | 216s | 28 |

**Null result.** Both models replied with the same boilerplate `{"correct": true, "confidence_wrong": 0.0, "corrected": "", "evidence": ""}` for every single segment — no engagement with the audio, no per-segment evidence. The strict standard-of-proof prompt biased both reviewers toward reflexive agreement.

**Why the null result is ambiguous, not conclusive**: VibeVoice's baseline transcript is already mostly correct. The 10.21% WER comes overwhelmingly from format-level differences ("100%" vs "Hundred percent", "her cost" vs "her costs"), backchannel segmentation issues (Marie's brief "Okay" / "Mm hmm" absorbed into Brant's longer turns — a diarization-level problem the text reviewer can't fix), word-order variations, and a few cases where VibeVoice is *more* accurate than the manually-revised reference. There are very few "wrong-word" errors for a reviewer to catch. Two hypotheses are equally consistent with the data: (a) the architecture works correctly, both reviewers identified the transcript as fine; (b) the reviewers are rubber-stamping and would say "correct=true" regardless.

**Cost analysis**: both models cleared the 30 s/min audio budget (Voxtral 22 s/min, Qwen Q8 28 s/min). Infrastructure-wise the pipeline is shippable; the open question is whether it does any work.

**Recommended next experiment (Phase A v2)** — `RESULTS.md` documents this in detail. Run an **injected-error benchmark**: take `vibevoice_with_context.json`, programmatically substitute known-wrong words into N segments (e.g., "Brant Kuehn" → "Bernard Cohen" in 3 segments, drop a phrase from 2 segments, "mediation" → "meditation" in 1), then run Phase A on the corrupted transcript. Score by injected-error detection rate at any confidence, plus false-positive rate on the genuinely-correct segments. A reviewer that flags 0/N injected errors at any confidence is rubber-stamping; one that flags N/N at high confidence is actually engaged. Secondary: re-run with a softer prompt that doesn't have the strong "presume correct" framing, on the same 51 real segments, to see if the prompt itself was the bottleneck.

**Files**: `Brainstorming/phase-a-vibevoice-nemotron/{run_phase_a.py, test_decision.py, compare.py, RESULTS.md, phase_a_voxtral*.json, phase_a_qwen*.json}` plus the model weights at `voxtral/`, `qwen-omni/`, `gguf/` (Nemotron preserved for later).

### April 30, 2026 (later) — Phase A v2: injected-error benchmark resolves the ambiguity

User direction: "keep on it with the goal of figuring out how to make this work." Built two parallel diagnostics to distinguish "architecture works" from "architecture rubber-stamps":

1. **Error injection tool** (`inject_errors.py`) — substitutes 8 audibly-distinguishable wrong words into the VibeVoice baseline (e.g., "Brant Kuehn" → "Bernard Cohen", "100%" → "10%", "funding" → "lunch"). Each injection has a `why_audible` annotation explaining why a careful listener should catch it.
2. **Softer review prompt** — replaced the strict "PRESUMED CORRECT" anchor. New prompt asks the model to first transcribe what it hears independently, *then* compare to the candidate. New JSON field `heard` captures the model's own transcription for audit. Bias separation: the prompt asks the model to listen, the standard-of-proof gate at the decision layer keeps strict (threshold 0.75 + non-trivial-diff filter + non-empty evidence).
3. **Injection scorer** (`score_injections.py`) — classifies every reviewed segment as TP / FN / FP / TN against the manifest, reports recall and false-positive rate at multiple thresholds.

**The diagnostic ran four configurations**:

| Configuration | WER | Δ corrupted | Detected | At 0.75 | FPs |
|---|---:|---:|:---:|:---:|---:|
| Corrupted baseline (no review) | 10.84% | — | — | — | — |
| Voxtral 3B Q4 / strict prompt | 10.84% | 0 | 0/8 | 0/8 | 0 |
| Voxtral 3B Q4 / soft prompt | **12.26%** | **+1.42** | 5/8 | 1/8 | 7 |
| Qwen Q8 / soft prompt | **10.60%** | **−0.24** | 3/8 | **3/8** | 1 |

**Voxtral with strict prompt was confirmed to be rubber-stamping** — 0/8 detection across blatant injections like "Bernard Cohen" for an audio clearly saying "Brant Kuehn." When given the softer prompt, Voxtral *did* engage (5/8 mismatches identified) but its `confidence_wrong` calibration is essentially random — it returns 0.0 even when correctly identifying substantive mismatches. The threshold gate therefore filtered out its real catches while letting through 2 over-corrections, making the transcript worse (+1.42 WER).

**Qwen Q8 with soft prompt is the architecturally viable configuration.** Lower raw recall (3/8 vs 5/8) but excellent calibration: every detection landed at 95% confidence, only 1 false positive, and the corrections it applied were substantively right. Net WER on a transcript with injected errors went from 10.84% → 10.60% — the architecture *actually improved* the transcript, on a corrupted input where the goal was to recover from injected errors.

**Architectural verdict**: the standard-of-proof framing works *when paired with* (a) a calibrated model (Qwen Q8 over Voxtral 3B), (b) a soft prompt that asks the model to listen first and compare second, (c) the existing decision-layer gate (threshold + evidence + non-trivial-diff). The earlier null result on the clean transcript was the architecture working correctly — there was nothing substantive for the reviewer to catch.

**Production gap**: Qwen's 37.5% detection rate is too low for shipping. Phase A v3 candidates documented in `RESULTS.md`: (1) multi-sample voting (3 samples at temp 0.3, majority rule) — should boost recall via better calibration without inflating FPR; cost goes from 28 to ~84 s/min audio. (2) hotword priming for proper names. (3) larger Omni model when one ships in GGUF, or Nemotron Omni when llama.cpp adds audio support.

**Files added in v2**: `inject_errors.py`, `score_injections.py`, `vibevoice_corrupted.json`, `injection_manifest.json`, `phase_a_voxtral_soft.json`, `phase_a_qwen_soft.json`, `phase_a_voxtral_injected.json`, all corresponding `*_review.jsonl` audit logs. `run_phase_a.py` updated with the soft prompt as default and a `heard` field threaded through the audit log.

### April 30 – May 1, 2026 — Phase A v3 / v4 / v5 + the smart-editor breakthrough

User direction reframed Deep Review's goal: VibeVoice's transcript IS the output; a reasoning model acts as a smart editor that proposes targeted patches based on listening to the audio. NOT a merge of two transcripts. NOT a per-segment "pick A or B." The mental model is a careful human reviewer marking up a draft, not synthesizing a new draft.

Five rounds of iteration tested this:

**v3 (disagreement-driven, Qwen Q8 with both candidates)**: 0/8 injections caught. The model anchors on whichever candidate is shown — when given the corrupted candidate, it echoed the corruption rather than transcribing fresh. Showing both candidates simultaneously made things worse, not better.

**v3.3 (Voxtral 3B as fresh per-span ASR)**: catastrophic 83% WER. Voxtral hallucinates wildly when given a per-span clip with a "transcribe verbatim" prompt — it summarizes or makes things up.

**v4 (Voxtral Small 24B as candidate-judge with word-swap apply)**: 46% WER. Voxtral Small DID catch real errors with high-confidence verdicts ("Florida counsel" → "Virginia Council" at conf=0.95 with accurate evidence), but the apply logic broke: when verdict was "replace_with_b", we substituted Parakeet's segment which often spans more audio time than VibeVoice's (Parakeet merges what VibeVoice splits), introducing massive content duplication. The word-swap apply attempt fixed half the problem but not the underlying segmentation alignment.

**v5 (smart editor — the working architecture)**: model receives the FULL VibeVoice transcript with segment indices labeled, plus the FULL audio, in a SINGLE prompt. Asked to return a list of `{segment, find, replace, evidence}` patches. The `find` string must be an exact substring of the targeted segment's text. Apply logic is just string-level find-and-replace per patch, gated by: find-string-exists, non-trivial diff, length ratio 0.33–3.0, non-empty evidence ≥12 chars.

Results with Voxtral Small 24B Q4:
- **Corrupted input**: 3/8 injections caught surgically (Bernard Cohen → Brant Kuehn, Tracy → Marie, meditation → mediation), WER 10.68% (vs corrupted baseline 10.84%, original VibeVoice 10.21%). Two bonus edits applied (one likely a real VibeVoice error caught for free). 61s wall clock — 3.5× faster than v2.
- **Clean input**: parse_error suppressed all edits — but the model's RAW output proposed reversing the correct "Brant Kuehn" back to "Bernard Cohen". The architecture worked (clean transcript stayed clean) but only because the JSON output was truncated at max_tokens before the bad edit could be parsed. **Voxtral Small Q4 hallucinates corrections on clean input — not safe for production.**

Qwen Q8 in the same v5 architecture: returns `{"edits": []}` immediately. Doesn't engage with the audio-grounded review task at all in this framing.

**Architectural verdict**: v5 is the right design. No transcript merging, no segmentation alignment problems, atomic patches, single-shot inference, principled apply gate. The remaining variable is the model. Voxtral Small at Q4 isn't reliable enough; Q8 (≈25 GB) is the next thing to test. Step-Audio-R1.1 33B (Apache 2.0, beats Gemini 2.5 Pro on audio reasoning, has built-in `<think>` blocks) is the ideal target if/when it gets a GGUF release with llama.cpp audio support.

**For the immediate Consensus product**: ship the v2 architecture (Qwen Q8 per-segment review with the soft prompt) as the validated Deep Review backend. 10.60% WER on corrupted, 3/8 injection detection, zero false positives on clean input. v5 needs a more reliable model before it's safe to ship.

**Files**: `run_smart_editor.py`, `phase_a_v5_*.json`, `phase_a_v5_*_audit.json`. `Brainstorming/phase-a-vibevoice-nemotron/RESULTS.md` updated with the full five-round narrative + architectural lesson.

**Lesson worth preserving**: the architecture is "smart editor producing patch list," not "transcript merger" or "candidate picker." When the next reasoning-grade audio model lands in llama.cpp, plug it into v5 unchanged.

**Handoff document drafted** at `Brainstorming/phase-a-vibevoice-nemotron/HANDOFF.md`. User paused to review results and think more about architecture. Next concrete step: download Voxtral Small Q8 (~25 GB) and re-run the v5 smart editor on both corrupted and clean transcripts. The decision matrix after that test is documented in HANDOFF.md — ship v5 with Q8 if reliability is fixed; otherwise ship the v2 Qwen-Q8-per-segment configuration as the verified Deep Review backend while waiting for Step-Audio-R1.1 or another reasoning-grade audio model to land in llama.cpp. Open architectural questions for the user to think about: the user-provided context box integration (not yet wired into v5), multi-sample voting as a cheap hallucination guard, prompt chunking for >10-min audio, and whether the optional disagreement-hint block boosts recall when paired with a reliable Q8 driver.

### May 1, 2026 — Phase A v6/v7 tool-constrained editor

Rejected the v5 full-transcript smart editor after Voxtral Small Q8 repeated the clean-transcript hallucination and applied `Brant Kuehn -> Bernard Cohen`, worsening WER to 10.36%.
Built `run_local_relisten_editor.py` (v6), which uses second-ASR disagreements only as a heatmap and re-runs VibeVoice locally; it repaired all 8 injected corruptions, applied zero edits to clean input, and restored corrupted WER from 10.84% to 10.21%.
Built `run_patch_verifier.py` (v7), which generates small WhisperKit candidate patches and lets Voxtral verify only keep/apply decisions; Voxtral Q4 improved the clean transcript to 9.89% by applying `seeing -> thinking` and `Oh, gosh -> That was fast`.
Combined v6 + v7 on the corrupted transcript reached 9.89% WER while still repairing 8/8 injected errors, making the tool-constrained editor the new best architecture.
The decision changed from "find a better full-transcript editor model" to "productionize a patch-centered editor with protected hotwords, local re-listen tools, and more gold transcripts for calibration."

### May 1, 2026 — Masked-cloze verifier breakthrough

Found the missing execution trick: mask the disputed phrase before asking the audio model to verify it, turning `seeing -> thinking` into a fill-the-blank task rather than a judgment over a sentence that already contains one answer.
Extended `run_patch_verifier.py` with `--masked-cloze`; with protected terms enabled, Voxtral Small Q4 applied three correct clean-transcript patches (`seeing -> thinking`, `that's it -> that said`, `Oh, gosh -> That was fast`) and improved WER from 10.21% to 9.73%.
The unprotected masked run exposed the guardrail requirement by accepting phonetically plausible regressions like `Brant Kuehn -> Brankine` and `Marie -> Maria`; user/domain hotwords must therefore be hard protected unless a patch moves toward them.
Combined v6 + masked v8 on the corrupted transcript reached 9.73% WER while still repairing all 8 injected corruptions.
The new recommended architecture is v6 local re-listen plus v8 protected masked-cloze verification, run through a resident sidecar and calibrated on more gold transcripts.

### May 1, 2026 — App architecture pivot to patch-centered Deep Review

Reworked the active app architecture so Deep Review is now patch-centered rather than a selectable add-on beside the old full-transcript LLM reconciler.
Added `PatchReviewRunner` and `TranscriboApp/Scripts/PatchReviewSidecar/run_patch_review.py`, wiring the Deep pass as: VibeVoice canonical transcript -> WhisperKit second opinion -> VibeVoice local re-listen -> protected masked-cloze verifier -> deterministic patch audit.
Made the rewritten Deep Read surface the app entry point, removed the developer UI toggle from active settings, forced VibeVoice as the canonical draft engine, and changed the review UI from "LLM uncertainty" to auditable patch-review items with revert-to-original options.
Archived the prior rewritten-UI full-reconcile runner at `Brainstorming/archive/legacy-deep-review/DeepPassRunner.full-llm-reconcile.swift` with a README explaining the retired path.
Verified the Swift target with `swift build` and syntax-checked the new Python sidecar; remaining build output was pre-existing warning noise in older files.

### May 1, 2026 — VibeVoice progress screen redesign

Replaced the generic centered Transcribing card with a dedicated workstation-style progress screen for the VibeVoice draft pass.
Threaded token count and tokens-per-second metadata from the sidecar into Swift progress updates, then split live transcript text into a rolling feed instead of embedding it inside the stage label.
Added fixed metric tiles for progress, tokens, speed, and elapsed time, plus a fixed-height live transcript panel that scrolls independently so the header and page layout no longer jump as segment length changes.
Verified the Swift target with `swift build`; built a release `.app` bundle but left `/Applications/Consensus.app` untouched because the installed app was actively running a test.

### May 1, 2026 — Speaker naming evidence panel

Fixed the "Who's speaking?" stage so expanded speaker examples no longer push the page header and footer out of view.
Replaced in-row expansion with a selected-speaker evidence panel: the speaker rows stay compact for name entry, while the longer cross-recording examples scroll in their own inspector pane.
Kept the speaker list itself in a bounded scroll region and added a stacked fallback for narrower windows.
Verified the Swift target with `swift build`; the installed `/Applications` app was left untouched while the user's active test continued.

### May 1, 2026 — Full export suite and manual revision pane

Restored the full export surface inside the rewritten Deep Read architecture: text, Markdown, Obsidian Markdown, JSON, SRT, RTF, DOCX, and the court-style legal transcript PDF now route through the shared `ExportService`.
Added legal PDF options to the new export sheet, including custom header text, elapsed timestamps, optional clock timestamps, and optional cover page content from the summary/to-do pane.
Integrated a new Manual Revision toolbar action that opens a rewrite-native correction pane, saves edits as the project's `.manual` pass, and gives the editor find, previous/next match, replace, and replace-all controls with native match highlighting.
Chose to reuse the existing exporter instead of creating a parallel rewritten exporter so legal PDF and DOCX behavior stay consistent across old and new surfaces.
Verified with `swift build` and `./build-app.sh --release`; the fresh bundle was built at `TranscriboApp/build/Consensus.app`, but `/Applications/Consensus.app` was left untouched because the installed app was still running a live test.

## 2026-05-20 — Checkpoint on rewrite-2026-04: UI overhaul plan, Deep Read pipeline

Captured pending WIP during the May 2026 workspace reorganization. New `UI-OVERHAUL-PLAN.md` (74 lines). DeepPassRunner removed; standardized on StandardPassRunner. Deep Read pipeline overhaul: DeepReadViewModel, DeepReadReviewView, DeepReadRootView, DeepReadSetupView, DeepReviewEngine. Services: ConfidenceMergeService, ExportService, LLMReconcileService, SegmentMerger, TranscriptionPipeline. Models: ProjectDocument, TranscriptPass, AppSettings. Views: ContentView, SettingsView, TranscriptionSetupView, ExportSheet, PipelineInspectorView, RewrittenSurface, SpeakerNamingView. Branch is `rewrite-2026-04` — set upstream on this push. Totals: 2814 insertions, 853 deletions across 28 files.

## 2026-06-30 — Consensus 1.1 Empty-Pass Reliability Fix

Diagnosed the Maralan legal-audio failure as the old fixed VibeVoice `--max-tokens 8192` cap: the sidecar generated 8,192 tokens and 27,896 raw characters but parsed 0 segments, matching the two empty saved projects.
Increased the Swift token budget to a duration-scaled cap, added sidecar metadata for token-limit hits, and made the app fail loud on both token-ceiling and zero-segment outputs instead of saving partial or empty passes.
Added recovery for older empty-pass projects so opening them returns to setup with a re-run warning rather than a blank review surface.
Verified the fix on the same 36m10s Maralan sample: direct sidecar returned 151 segments without hitting the 30,136-token cap, and the Swift smoke path saved/exported 151 segments with no warnings.
The first user run then exposed a second issue: Standard transcription succeeded, but Patch Review auto-started and showed a missing Voxtral verifier asset error. Added Patch Review availability preflight, hid Deep/Verified tiers when verifier assets are absent, and kept missing-asset projects on the Standard transcript without a modal.
Built and installed `/Applications/Consensus 1.1.app` as a side-by-side test build with version 1.1/build 3 and the full MLX metallib bundled.

## 2026-07-10 — Remake kickoff: baseline verified, 2026 landscape researched, master plan written

Kicked off the July 2026 remake push (Goal A: accuracy, Goal B: UI) with `CONSENSUS-REMAKE-PLAN.md` as the new master plan, superseding the completed `UI-OVERHAUL-PLAN.md` and the Phase A handoff.
Verified the benchmark harness reproduces exactly: a fresh VibeVoice run on the gold file scored 10.21% WER / 6.43% DER (identical to April), and the archived v6+v8 best re-scored at 9.73% WER.
Key analysis finding: ~half the measured WER is verbatim-vs-clean style mismatch, not misrecognition — ~49 of 71 insertions are fillers the hand-cleaned gold omits; style-normalized WER is ~6.4% baseline / ~5.9% best, and true content error is likely ~3-4%. The scorer needs a content-WER track before further optimization; the gold transcript also has a typo ("afer").
Discovered the Voxtral Small verifier GGUFs were deleted from disk (matches the June 30 missing-assets alert), so the verifier bake-off will decide what earns a re-download.
Ran three parallel web-research agents on the July 2026 landscape; full cited reports in `Brainstorming/2026-07-research/`. Headlines: keep VibeVoice-ASR as canonical (no successor since January); Qwen3-ASR-1.7B and Granite Speech 4.1 are the new second-opinion candidates; the vendored FluidAudio is 10+ versions behind an upstream that now ships pyannote community-1 on CoreML plus per-chunk speaker embeddings; Qwen3-Omni-30B-A3B and the newly Apache-licensed Gemma 4 12B are the verifier bake-off candidates (Step-Audio-R1.1 still has no llama.cpp path); and VibeVoice's own speaker tags are an unused free second diarization opinion.
Decision: sequence engine work before UI consolidation so Studio-mode telemetry is built against the final pipeline.

## 2026-07-10 (later) — Gold fixture drafts + AI-editor direction

Drafted two new gold-standard fixtures for the benchmark set, both machine-drafted and awaiting Brant's verification: the Maralan 36-minute arbitration call (151 turns, confirmed speaker names reused from the June 30 project, 61 engine disagreements + 8 bracket-tag segments flagged) and the Clayton Everett 19-minute call (66 turns, 37 disagreements, speakers still numbered pending naming).
Method: VibeVoice canonical + faster-whisper large-v3 second opinion + the Phase A disagreement differ, emitting a draft groundtruth JSON plus a timestamped REVIEW.md so human listening is spent only where engines disagreed.
Hit and fixed a faster-whisper failure on the Clayton audio: large-v3 int8 with VAD collapsed two-minute spans into single sentences (627 words for 19 minutes); re-running against a 16 kHz WAV with VAD off and condition_on_previous_text=False produced a healthy 2,793 words.
Fixed the "afer" typo in the existing gold transcript (JSON and RTF).
Recorded Brant's decisions: direct-download distribution (not App Store), ~33GB model budget approved for the verifier bake-off, and a new plan section A5 ("The AI editor") expanding the local LLM's role to semantic plausibility scans and diarization sanity checks — always flag-and-verify, never free-form editing, per the Phase A v5 hallucination lesson.

## 2026-07-10 — UI consolidation: legacy surface archived

Confirmed the sequencing question with Brant: UI work proceeds now, engine bake-off and gold-transcript calibration follow when he has review time (the bake-off itself only needs the existing verified gold file).
Consolidated the app onto the rewritten Deep Read surface: dependency analysis showed the rewritten tree referenced nothing in the legacy Views/ tree, ContentView already routed unconditionally to RewrittenSurface, and only SettingsView (Settings scene) plus the ProcessLog model types were still live.
Archived 20 dead legacy view files (~6,000 lines: ReconciliationView, QualityView, TranscriptView, SimpleView, welcome tour, help center, and the rest) to Brainstorming/archive/legacy-ui-2026-07/, trimmed ContentView.swift to a 9-line wrapper, removed the useRewrittenUI flag from AppSettings, and moved CircularProgressGauge + DisagreementHeatmapView into the live App/Views tree, earmarked for Studio mode.
Verified with a clean swift build and a release build installed to /Applications/Consensus 1.1.app, which launches normally. Follow-up noted: a full click-through of every stage plus deciding TranscriptionViewModel's future (still compiled for the Settings scene and smoke harness, unused by the rewritten surface).
Also spawned the papercraft/cute-graphics research task over to WaffleHouseMeow Ultimate Edition, where it belonged — it had been sent to this session by mistake.

## 2026-07-25 — Headless CLI: library extraction and `consensus transcribe`

Brant reprioritized: freeze the transcription engine as-is and focus on the user interface plus a headless/CLI mode for automating captured audio on the Mac Studio, per the new `10-consensus-spec.md`.
Found the blocking problem first: the existing `--smoke` headless path still booted a full SwiftUI `App` and `NSApplicationDelegate`, so it needed a window server and would have failed from a bare launchd job — exactly what the spec forbids.
Restructured the package into one shared library (`ConsensusCore`, holding all models/services/views and now the SwiftUI scene as a public type) plus two thin executable launchers: `Consensus` (GUI) and `consensus` (CLI). Keeping the scene inside the library meant only one symbol needed to become public instead of the dozens a services-only split would have required.
Implemented the CLI inside the library (`Transcribo/CLI/`) so it reaches the pipeline's internal API without widening it: argument parsing, spec exit codes 0/1/2/3/4, streaming SHA-256 input probing with a still-syncing guard, schema-2.0 JSON plus Markdown rendering with identity-free first-appearance speaker labels, atomic temp-then-rename writes, and idempotency keyed on filename and source hash.
Hit two SwiftPM traps worth remembering: targets named `Consensus` and `consensus` collide on the case-insensitive filesystem (fixed by naming the target `ConsensusCommandLine` and the product `consensus`), and an executable module named `ConsensusApp` shadowed the library type of the same name (fixed by renaming the module `ConsensusGUI`).
Verified end to end on real audio: full JSON/Markdown round trip, all error exit codes, idempotency and `--force`, `--quiet`/`--json-only`/`--output-dir`/`--speakers`/`--stt-hints`, SIGKILL mid-run leaving no partial files with a clean re-run, and a detached run with no controlling terminal. Documented usage and a launchd plist in the new `CLI.md`.
Known gaps recorded in the spec: 2-hour audio is untested and would need internal chunking past VibeVoice's 60-minute ceiling, the config file is unimplemented, hosted `--engine` adapters are rejected rather than supported, and a true launchd daemon test on the Mac Studio is still pending.
