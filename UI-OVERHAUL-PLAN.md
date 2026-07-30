# Consensus UI/UX Overhaul — Implementation Plan

> **SUPERSEDED (July 10, 2026):** All phases below are complete. Active planning has moved to `CONSENSUS-REMAKE-PLAN.md` (accuracy roadmap + UI consolidation + three-mode redesign). This file is kept as the historical record of the March 2026 theme overhaul and its addenda. The "Future Studio Concept: Observability Dashboard" section below is carried forward as Goal B2/Studio in the new plan.

BDK Transcribo is being renamed to **Consensus** and receiving a comprehensive UI/UX overhaul to move from a "utility" aesthetic to a "high-end workstation" feel (similar to Linear or Raycast). The hallmark feature is Deep Review (multi-model reconciliation).

---

## June 30, 2026 Addendum: VibeVoice Empty-Pass Regression on 36-Minute Legal Audio

**Status:** COMPLETE (June 30, 2026)

Bug investigation reopened for `TestAudio/2026-06-26 - Maralan - Arbitration Settlement and Legalist Funding Resolution.m4a` after the installed `/Applications/Consensus.app` created empty Standard passes.

Findings so far:
- The audio itself validates as normal AAC voice audio: 36m10s, mono, 22.05 kHz, ~33 kbps.
- The installed app is still the May 1 `1.0` bundle, predating the duration-scaled VibeVoice token-budget and fail-loud empty-pass guard currently present in the working tree.
- Two saved projects for the Maralan file (`821BFDB0-B08C-4616-8489-5A3BB55510CF` and `DDCEF8CE-303E-4658-B280-02194F6AAE1D`) have `passes/standard.json` with `segmentCount: 0`, confirming the failure is an app/sidecar parse path rather than a bad source file.
- Direct sidecar reproduction with the old `--max-tokens 8192` cap generated 8,192 tokens in 336.5s, produced 27,896 raw text characters, and parsed 0 transcript segments.
- Direct sidecar verification with the new duration-scaled `--max-tokens 30136` budget generated 12,431 tokens in 450.8s, did not hit the token limit, and parsed 151 transcript segments.
- App-level Swift smoke on the same Maralan audio passed: 36m10s duration, 151 segments, 3 detected speakers, 95% word confidence, 95% diarization quality, no warnings, and TXT/JSON exports written.

Completed work:
- Increased the Swift-provided VibeVoice token budget from the old short-recording cap to a generous duration-scaled budget.
- Added sidecar metadata for `max_tokens` and `hit_token_limit`.
- Added Swift guards that reject token-limit hits and zero-segment parses before any pass is saved.
- Added empty-pass recovery when opening older broken projects.
- Built and installed `/Applications/Consensus 1.1.app` with `CFBundleShortVersionString = 1.1`, `CFBundleVersion = 2`, and the full 102 MB `mlx.metallib` bundle.

Decision note:
- The test build will install side-by-side as `Consensus 1.1.app` while keeping the bundle executable and project library path unchanged. Changing the support-directory name would make the build look "fresh" but hide the existing projects; preserving `~/Library/Application Support/Consensus` makes this a true reliability test against the same local state.
- Token-limit handling now fails loud as well as empty-output handling. A recovered partial parse is not enough for success if the sidecar hit `--max-tokens`, because that state can silently save an incomplete transcript.
- Existing broken projects now recover through setup instead of opening a blank review surface. If a saved pass has zero segments, Consensus 1.1 warns that it came from an older empty-pass build and asks the user to re-run transcription.

Follow-up from first Consensus 1.1 user run:
- The Standard VibeVoice transcript succeeded on the Maralan file, but the app then auto-started Patch Review and showed a missing-model alert because the optional Voxtral Small verifier assets were not present locally.
- Consensus now treats Patch Review as unavailable unless its sidecar, VibeVoice model, Voxtral model/projector, `llama-mtmd-cli`, and `ffmpeg` all exist. When unavailable, new/reopened projects are normalized to Standard speed, Deep/Verified tier choices are hidden, and confirming speakers stays on the Standard transcript without a modal.
- Decision: prefer a polished Standard transcript over a scary degraded-mode alert. Downloading or bundling the verifier assets remains a separate Studio/Deep Review setup task.

## May 1, 2026 Addendum: Transcribing Progress Screen

**Status:** COMPLETE (May 1, 2026)

The VibeVoice transcription stage now uses a dedicated workstation-style progress screen instead of the generic centered progress card. The title, status strip, progress rail, and metric tiles have fixed regions so the page no longer jumps when streaming transcript text changes length.

Completed work:
- Threaded VibeVoice sidecar token count and tokens-per-second metadata into Swift progress updates.
- Split live transcript output out of `StageProgress.label` and into a bounded rolling feed owned by `DeepReadViewModel`.
- Added separate metric tiles for progress, total tokens, speed, and elapsed time.
- Added a fixed-height live transcript panel that scrolls independently as VibeVoice emits text.

---

## May 1, 2026 Addendum: Speaker Naming Evidence Panel

**Status:** COMPLETE (May 1, 2026)

The "Who's speaking?" stage no longer expands long dialogue examples inside the speaker row. Rows stay compact for name entry, and the larger cross-recording sample set opens in an inspector-style evidence panel with its own scroll view.

Completed work:
- Replaced row expansion state with a selected speaker evidence pane.
- Kept the speaker list in a bounded scroll region so the header and footer remain reachable.
- Added a right-side evidence panel on wider windows, with a stacked fallback on narrow windows.
- Kept preview samples compact and moved long dialogue review into independently scrolling sample cards.

---

## May 1, 2026 Addendum: Export Suite + Manual Revision Recovery

**Status:** COMPLETE (May 1, 2026)

The rewritten Deep Read surface now restores the full export surface from the legacy app instead of limiting the user to three text formats. The manual editor is also integrated into the new review toolbar, with a dedicated correction pane and native find/replace controls.

Completed work:
- Promoted export handling back to the shared `ExportFormat` / `ExportService` path so Deep Read can save text, Markdown, Obsidian Markdown, JSON, SRT, RTF, DOCX, and legal transcript PDF.
- Added Legal PDF controls to the new export sheet: header text, elapsed timestamps, optional clock timestamps, and optional cover page content from the summary/to-do pane.
- Added quick toolbar export paths for Legal PDF, Markdown, Obsidian Markdown, and plain text while keeping the full "Export with options" sheet.
- Added a "Manual Revision" review-toolbar action that opens a rewrite-native editor and saves corrections as the project's `.manual` pass, so every export format uses the revised transcript.
- Added find, previous/next match, replace, and replace-all controls backed by a native text view that highlights and scrolls to the active match.

Decision note:
- A separate rewritten exporter would have moved faster in the short term, but it would have duplicated the court-style PDF and DOCX logic. Reusing the shared export service keeps legal PDF behavior consistent across old and new surfaces and makes future export fixes land once.

---

## Future Studio Concept: Observability Dashboard

**Status:** BACKLOG IDEA (May 1, 2026)

Studio mode should eventually include a "work in progress" observability cockpit for hobbyist/power users who enjoy watching the local AI pipeline operate. This should feel like a native workstation dashboard, not a generic debug log.

Candidate metrics:
- **Run health:** current stage, elapsed time, real-time factor, stage timings, patch counts, accepted/rejected edit counts.
- **Engine throughput:** VibeVoice tokens/sec, WhisperKit seconds processed/sec, patch verifier calls/minute, context/token counts where available.
- **Process health:** app RSS, sidecar RSS, available memory/headroom, memory-pressure warnings, active child process IDs.
- **Thermal health:** use official `ProcessInfo.thermalState` as the shippable baseline; investigate whether direct CPU/GPU temperature can be exposed safely as a developer-only adapter.
- **Compute estimates:** prefer honest tokens/sec, audio real-time factor, and model/runtime stats over pretending to know true hardware FLOPs; FLOP estimates can be derived/labeled if useful.
- **Review trace:** show the patch-review chain as it happens: candidate patch, audio window, second-opinion source, local re-listen text, masked-cloze options, model choice, confidence, public rationale, guardrail result, and final apply/reject reason. Do not expose raw hidden chain-of-thought; summarize the model's reasoning as auditable evidence and decision notes.

Design direction:
- Surface this as a Studio-only dashboard, likely adjacent to or replacing the current Pipeline Inspector.
- Use compact metric tiles, small time-series strips, a process/event log, and a patch-review timeline with expandable evidence cards.
- Keep it read-only and nonessential: it should deepen trust and enjoyment without making Quick Take or Deep Read feel technical.
- Name the reasoning surface something like "Review Trace" or "Patch Audit" rather than "chain of thought," so it is clear the app is showing a product-safe explanation/audit trail rather than private model internals.

Open implementation questions:
- Which telemetry can be gathered without private APIs or elevated privileges?
- Should deeper metrics come from Swift directly, sidecar JSON progress events, or a separate local telemetry sampler?
- Can we sample frequently enough to feel alive without adding measurable overhead during ML inference?
- How much of the raw model response should be retained for Studio auditability, and when should the app store only a short public rationale to avoid misleading users with uncalibrated hidden reasoning text?

---

## Phase 0: Rename (Low Complexity)

**Goal:** Replace all user-visible references to "BDK Transcribo" with "Consensus." Update internal identifiers where appropriate.

**Files to change:**

| File | What changes |
|---|---|
| `Views/ContentView.swift` | `"BDK Transcribo"` fallback title becomes `"Consensus"` |
| `Views/WelcomeTourView.swift` | "Transcribo" and "BDK Transcribo" strings |
| `Views/HelpCenterView.swift` | Path reference `BDK Transcribo` |
| `Services/DemoProjectFactory.swift` | Demo text "BDK Transcribo" |
| `Services/ProjectStore.swift` | Application Support directory name — use dual-path lookup (check new path first, fall back to old) |
| `TranscriboApp.swift` | Struct name (optional but keeps consistency) |
| `Package.swift` | Package name, target name |
| `CLAUDE.md`, `PROJECT_HISTORY.md` | Documentation references |

**Migration strategy for ProjectStore:** Check both `"Consensus"` and `"BDK Transcribo"` paths in Application Support. Prefer new path. If only old path exists, use it (don't move files — avoid data loss risk). New projects always save to new path.

**Status:** COMPLETE (March 16, 2026)

---

## Phase 1: Design System Foundation (High Complexity — Everything Depends on This)

**Goal:** Create a centralized design system. Without this, later phases scatter hardcoded colors/fonts throughout the codebase (the current anti-pattern).

### New Files to Create

**1. `Theme/ConsensusTheme.swift`** — Central namespace:
- `Colors` struct:
  - `background`: Deep Slate (#0F1419 or similar midnight blue)
  - `surfacePrimary`: Slightly elevated surface (#1A1F26)
  - `surfaceSecondary`: Card-level surface (#232A33)
  - `accent`: Indigo (#6366F1)
  - `accentSubtle`: Indigo at 15% opacity (for backgrounds)
  - `textPrimary`: White at 90% opacity
  - `textSecondary`: White at 60% opacity
  - `textTertiary`: White at 35% opacity
  - `border`: White at 8% opacity (1px card borders)
  - `confidenceGreen`: #34D399
  - `confidenceAmber`: #FBBF24
  - `confidenceRed`: #F87171
  - Difference tint colors (aligned, punctuation, speaker, text, missing)
- `Fonts` struct:
  - `body`: SF Pro (system default)
  - `mono`: SF Mono for timestamps, confidence %, metadata
  - `heading`: SF Pro semibold/bold
  - `caption`: SF Pro at smaller sizes
- `Spacing` struct: xs(4), sm(8), md(12), lg(16), xl(24), xxl(32)
- `Radius` struct: sm(6), md(8), lg(12), xl(16)

**2. `Theme/ConsensusCardStyle.swift`** — ViewModifier:
- `.ultraThinMaterial` background
- 1px border (`ConsensusTheme.Colors.border`)
- Rounded corners
- Replaces all `GroupBox` usage
- Variants: `.consensusCard()` and `.consensusCard(labeled: "Title")`

**3. `Theme/ConsensusButtonStyles.swift`** — Custom ButtonStyles:
- `ConsensusPrimaryButtonStyle`: Indigo filled, white text
- `ConsensusSecondaryButtonStyle`: 1px indigo border, indigo text
- `ConsensusGhostButtonStyle`: Plain text, hover highlight

### Existing Files to Modify

| File | What changes |
|---|---|
| `TranscriboApp.swift` | `.preferredColorScheme(.dark)` on WindowGroup, `.tint(ConsensusTheme.Colors.accent)` |
| `AppSettings.swift` | Add `@AppStorage("colorScheme")` for future light mode toggle |
| `Views/Components/SpeakerBadge.swift` | Use theme colors, SF Mono for badge text |
| `Views/Components/SegmentRow.swift` | SF Mono for timestamps, theme fonts for body |

### Key Decisions

- **Dark mode enforcement:** `.preferredColorScheme(.dark)` at WindowGroup level. A Settings toggle can override later.
- **Glassmorphism:** `.ultraThinMaterial` with `RoundedRectangle` clip and 1px stroke. The codebase already uses `.regularMaterial` in two places.
- **GroupBox replacement:** Every `GroupBox` (6 instances across 3 views) becomes a `ConsensusCard`. Must support labeled and unlabeled variants.
- **No asset catalog:** The app is an SPM executable, not .xcodeproj. All colors defined in code, which suits the centralized theme approach.

### Watch Out For
- `ReconciliationView` has a hardcoded `.background(Color.white.opacity(0.82))` on TextEditors that will look wrong in dark mode. Must replace with theme token.
- Several views use raw `.blue`, `.green`, `.secondary` etc. — all need to be replaced with `ConsensusTheme.Colors` references.

**Status:** COMPLETE (March 16, 2026) — ConsensusTheme.swift, ConsensusCardStyle.swift, ConsensusButtonStyles.swift created. Dark mode + indigo accent applied at WindowGroup level. SpeakerBadge and SegmentRow updated to use theme. Build verified.

---

## Phase 2: Sidebar & Navigation Refactor (Medium Complexity)

**Goal:** Grouped project list by date, metadata badges, animated transcription indicator.

### Files to Modify

| File | What changes |
|---|---|
| `Views/ContentView.swift` | Major refactor of `SidebarView` and `ProjectLibraryRow` |
| `Models/TranscriptionProject.swift` | Add `isReconciled` / `hasConsensus` to `TranscriptionProjectSummary` |
| `Services/ProjectStore.swift` | May need to expose additional summary data |

### Work Items

1. **Date grouping:** Group `projects` by `updatedAt` into "Today", "Yesterday", "Last Week", "Older" sections using `Section` headers in the sidebar `List`.

2. **Metadata badges (new components):**
   - `ConfidencePill`: Capsule colored by confidence tier (red/amber/green), showing percentage
   - `StatusBadge`: Checkmark for reconciled, warning for needs review
   - Requires `TranscriptionProjectSummary` to expose reconciliation status

3. **Pulse animation:** When `viewModel.pipeline.isRunning`, apply `PhaseAnimator` or repeating animation to the "waveform" icon in the Transcribe sidebar row.

**Status:** COMPLETE (March 16, 2026) — Full sidebar rewrite with date-grouped projects (Today/Yesterday/Last 7 Days/Older), StatusBadge (Reconciled/Needs Review/Draft), ConfidencePill (color-coded capsule), pulse animation via phaseAnimator, all themed with ConsensusTheme. Added `hasConsensus` and `hasMultiplePasses` to TranscriptionProjectSummary.

---

## Phase 3: Quality Dashboard Overhaul (Medium-High Complexity)

**Goal:** Circular progress gauges and disagreement heatmap.

### Files to Modify

| File | What changes |
|---|---|
| `Views/QualityView.swift` | Replace metric cards with gauges, add heatmap |

### New Components

1. **`Views/Components/CircularProgressGauge.swift`**
   - Custom drawing via `Circle().trim(from:to:)` with three-tier coloring
   - Red (0-60%), Amber (60-80%), Green (80-100%)
   - Replaces the top three metric cards (Word Confidence, Segment Confidence, Diarization Quality)

2. **`Views/Components/DisagreementHeatmapView.swift`**
   - Horizontal bar representing full audio duration
   - Color-coded segments at disagreement timestamps
   - Uses `Canvas` for drawing
   - Data source: `PassComparisonSummary.disagreements` (already exists with `start`/`end`/`kind`)
   - Goes at top of comparison section

### Additional Work
- Replace all `GroupBox` with `ConsensusCard`
- Apply SF Mono to all percentage and numeric values
- Keep remaining six metric cards as themed numeric displays

**Status:** COMPLETE (March 16, 2026) — Created CircularProgressGauge (three-tier arc gauge with SF Mono value labels) and DisagreementHeatmapView (GeometryReader-based proportional timeline with color-coded segments and legend). Rewrote QualityView.swift: replaced all GroupBox with .consensusCard(), replaced top metric cards with CircularProgressGauge row, added DisagreementHeatmapView to comparison section, themed all fonts/colors/spacing with ConsensusTheme. Build verified.

---

## Phase 4: Reconciliation Workspace Redesign (High Complexity — Largest Phase)

**Goal:** Unified diff view, keyboard-first navigation, floating audio controller.

### Files to Modify

| File | What changes |
|---|---|
| `Views/ReconciliationView.swift` | Near-complete rewrite of layout and interaction |
| `ViewModels/TranscriptionViewModel.swift` | Keyboard shortcut handlers |
| `Services/AudioContextPlayer.swift` | Floating controller support |

### Work Items

1. **Unified scroll + diff view:**
   - `aligned` rows: single dimmed text block spanning full width
   - Rows with differences: word-level inline diff (red/green highlighting)
   - Eliminates three-column table header
   - Becomes a single scrolling document with inline diff annotations
   - The `ReconciliationDiffHighlighter` and `HighlightedTranscriptText` components already exist — reuse and adapt

2. **Keyboard-first navigation (via `.onKeyPress`, macOS 14+):**
   - `[1]` = Use Left (reference pass)
   - `[2]` = Use Middle (candidate pass)
   - `[Enter]` = Confirm block
   - `[Up/Down]` = Navigate between disagreement rows
   - `[Space]` = Play context audio
   - Show shortcuts as subtle tooltips when a block is focused

3. **Floating audio controller:**
   - `safeAreaInset(edge: .bottom)` overlay
   - Play/pause, current position, scrubber
   - "Play Context" button (auto-rewind 5 seconds — logic already exists in viewModel)
   - Remains visible during scroll

### Risk
- The `ComparisonBlockRow` is 230+ lines and needs a near-complete rewrite
- Consider keeping old view as `ReconciliationView_Legacy.swift` during development for A/B testing
- The `ReconciliationDraft` and `ReconciliationRow` models do NOT need to change

**Status:** COMPLETE (March 16, 2026) — Complete rewrite of ReconciliationView from 4-column table to unified single-column diff stream. Aligned blocks now render as compact dimmed cards (speaker + text). Disagreement blocks expand with side-by-side source panels, inline diff highlighting, and an editable consensus editor. Created FloatingAudioController component (safeAreaInset bottom bar) with play/stop, timestamp display, and keyboard shortcut hints. Added full keyboard navigation: [1] Use A, [2] Use B, [Space] play/stop context, [Up/Down] navigate rows, [Return] jump to next unresolved disagreement. All colors/fonts/spacing use ConsensusTheme tokens. Updated ReconciliationSourceChoice display names from "Left"/"Middle" to "Reference"/"Candidate". Added solid diff tint colors to ConsensusTheme. Build verified.

---

## Phase 5: Export Suite Enhancement (Medium Complexity)

**Goal:** Live PDF preview, document inspector sidebar.

### Files to Modify

| File | What changes |
|---|---|
| `Views/ExportView.swift` | Add preview pane and inspector sidebar |
| `Services/ExportService.swift` | Expose `buildLegalPDF` for preview (already returns Data) |
| `Models/TranscriptionProject.swift` | Add `caseNumber`, `matterName`, `attorneyName` to `ProjectExportPreferences` |
| `ViewModels/TranscriptionViewModel.swift` | Wire new metadata fields into export preferences |

### Work Items

1. **Live PDF preview:**
   - When Legal PDF is selected, show `PDFView` (from PDFKit) in a split pane on the right
   - Generate PDF using existing `buildLegalPDF`, display the result
   - Debounce regeneration (500ms after last field edit) to avoid lag
   - Run `buildLegalPDF` on background actor for long transcripts

2. **Document Inspector sidebar:**
   - Fields: Case Number, Matter Name, Attorney Name
   - Stored in `ProjectExportPreferences` (Codable — new fields must be `String?` with nil defaults for migration safety)
   - Passed through to `LegalPDFOptions` for header inclusion

3. **Apply theme:** Replace `GroupBox`, card styling, SF Mono for format metadata.

**Status:** COMPLETE (March 16, 2026) — Themed ExportView with ConsensusTheme: format cards use accent/border tokens, GroupBox replaced with .consensusCard(), export button uses ConsensusPrimaryButtonStyle. Added live PDF preview using PDFKit: when Legal PDF is selected, an HSplitView shows a PDFView on the right with the generated PDF. Preview regenerates on option changes with 500ms debounce for header text edits. PDF generation runs on Task.detached to avoid blocking the main thread. Document inspector fields (case number, etc.) deferred to a future session as they require model migration.

---

## Phase 6: Polish Pass (Low-Medium Complexity)

**Goal:** Apply design system to all remaining views not touched in earlier phases.

### Files to Modify

| File | What changes |
|---|---|
| `Views/TranscriptionSetupView.swift` | Theme cards, fonts, drop zone styling |
| `Views/TranscriptView.swift` | Theme speaker panel, SF Mono timestamps |
| `Views/AudioDropZone.swift` | Themed colors for drop zone border and background |
| `Views/HelpCenterView.swift` | Replace `.regularMaterial` with theme materials |
| `Views/WelcomeTourView.swift` | Theme step cards, update styling |
| `Views/SettingsView.swift` | Dark mode form styling, add color scheme toggle |

**Status:** COMPLETE (March 16, 2026) — Applied ConsensusTheme to all remaining views. TranscriptionSetupView: replaced GroupBox with .consensusCard(), themed model picker and speaker steppers with mono fonts. AudioDropZone: replaced raw .blue/.secondary with accent/textMuted/accentMuted tokens, themed loaded-file card with surfacePrimary background. TranscriptView: themed header with mono timestamps, speaker panel with surfacePrimary background, SpeakerRenameCard uses surfaceSecondary + border. HelpCenterView: replaced .regularMaterial with .ultraThinMaterial via .consensusCard(), replaced raw .blue/.orange/.green/.indigo tints with theme colors, updated reconciliation help text to match new "Use A"/"Use B" keyboard shortcuts. WelcomeTourView: replaced raw .blue/.green/.orange/.purple tints with theme colors (accent, confidenceGreen, confidenceAmber, diffSpeakerSolid), replaced .regularMaterial with .ultraThinMaterial + border, themed all text with ConsensusTheme.Colors, added background color. SettingsView: updated About section with "Consensus" app name. Build verified.

---

## Complete File Manifest

### New Files (7)
```
Theme/ConsensusTheme.swift
Theme/ConsensusCardStyle.swift
Theme/ConsensusButtonStyles.swift
Views/Components/CircularProgressGauge.swift
Views/Components/DisagreementHeatmapView.swift
Views/Components/ConfidencePill.swift
Views/Components/FloatingAudioController.swift
```

### Modified Files (22)
```
TranscriboApp.swift
Package.swift
Models/AppSettings.swift
Models/TranscriptionProject.swift
ViewModels/TranscriptionViewModel.swift
Views/ContentView.swift
Views/TranscriptionSetupView.swift
Views/TranscriptView.swift
Views/QualityView.swift
Views/ReconciliationView.swift
Views/ExportView.swift
Views/SettingsView.swift
Views/HelpCenterView.swift
Views/WelcomeTourView.swift
Views/AudioDropZone.swift
Views/Components/SegmentRow.swift
Views/Components/SpeakerBadge.swift
Services/DemoProjectFactory.swift
Services/ProjectStore.swift
Services/ExportService.swift
Services/AudioContextPlayer.swift
CLAUDE.md
```

---

## Estimated Timeline

| Phase | Sessions | Dependencies |
|-------|----------|-------------|
| Phase 0: Rename | 1 | None |
| Phase 1: Design System | 1-2 | Phase 0 |
| Phase 2: Sidebar | 1 | Phase 1 |
| Phase 3: Quality Dashboard | 1-2 | Phase 1 |
| Phase 4: Reconciliation | 2-3 | Phase 1 |
| Phase 5: Export | 1-2 | Phase 1 |
| Phase 6: Polish | 1 | Phase 1 |
| **Total** | **8-12** | |

Phase 0 must be first (rename affects every file, creates merge conflicts if deferred). Phase 1 next (every visual change depends on it). Phases 2-5 can be done in any order after Phase 1, but Sidebar (2) is recommended next since it's the always-visible navigation surface. Phase 6 last as cleanup.

---

## Design Reference

### Color Palette
- Background: Deep Slate (#0F1419)
- Surface Primary: #1A1F26
- Surface Secondary: #232A33
- Accent: Indigo (#6366F1)
- Accent Subtle: Indigo at 15% opacity
- Text Primary: White at 90%
- Text Secondary: White at 60%
- Text Tertiary: White at 35%
- Border: White at 8%
- Confidence Green: #34D399
- Confidence Amber: #FBBF24
- Confidence Red: #F87171

### Typography
- Body: SF Pro (system)
- Monospace: SF Mono (timestamps, percentages, metadata)
- Headings: SF Pro Semibold/Bold

### Visual Language
- Glassmorphism: `.ultraThinMaterial` + 1px border + rounded corners
- No heavy shadows (1px borders instead)
- Cards replace all GroupBoxes
- Indigo accent for primary actions and AI-generated highlights
- Dark mode enforced at WindowGroup level
