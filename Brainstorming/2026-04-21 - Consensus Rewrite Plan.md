# Consensus Rewrite Plan

**Date:** April 21, 2026
**Author:** Claude Opus 4.7 (drafted with user)
**Status:** SIGNED OFF by user on April 21, 2026. All open decisions resolved (see bottom). Ready to execute starting with Phase 0 in the next session.

## Why a rewrite

Three things came together this week that make a UI rewrite the right next move, not premature:

1. **We know the pipeline architecture.** LLM reconciliation produces 11.5% cpWER with 100% speaker accuracy on the benchmark — essentially publishable quality on two-engine input. More engines don't help. The right levers are context (speaker names, domain, proper nouns) and interactive refinement (LLM-surfaced uncertainties).
2. **We know what the product shape should be.** Tiered depth of processing; verbatim vs. clean as a free toggle; summary + to-dos in an editable pane; interactive speaker naming and proper-noun confirmation.
3. **The current app is a palimpsest of experiments.** Workflow redesigns layered on workflow redesigns, three different reconciliation services, a mix of views written against old assumptions. It works, but it's heavy. Starting fresh on the UI (on top of the proven pipeline) lets us ship a focused, coherent product.

The **pipeline code** stays — `TranscriptionService`, `LLMReconcileService`, `SegmentMerger`, `ForcedAlignmentService`, `SpeakerKitDiarizationService`, `TranscriptCleanupService`. What changes: the ViewModels, the Views, the flow through them, the data model for projects.

## The three modes

Each mode exposes a progressively wider control surface over the same underlying pipeline. All three share the same project data model, same LLM services, same manual editor, same voice library.

### Quick Take

"Drop and get out." Drops an audio file → runs the recommended pipeline → shows a clean transcript. Zero configuration screens.

Flow:
1. Drop audio.
2. System picks the pipeline tier based on audio length (≤30 min → Deep Review with LLM; >30 min → Standard).
3. Progress indicator (single-line: "Transcribing… / Reconciling… / Naming speakers…").
4. After transcription + initial reconciliation, a compact panel appears with auto-detected speaker names — user confirms or corrects (Speaker 1 → Brant, Speaker 2 → Marie), one click per speaker.
5. LLM refines the transcript using names, surfaces any remaining uncertainties inline (max 5, picked by highest impact).
6. User skims, resolves uncertainties with Play Context buttons, taps Export.
7. Default export: Legal PDF + Markdown to Desktop.

No tier choice. No style choice (always uses Clean + auto-detect Verbatim available on toggle). No summary/todos by default (can toggle on from Options menu).

### Deep Read

"Tell me what you want." Between Quick Take and Studio — has the key choices but doesn't expose every knob.

Flow:
1. Drop audio.
2. A compact setup card appears:
   - **Speed**: *Quick* (no LLM, Standard tier, ~1 min) OR *Deep* (LLM reconciliation, ~3 min for 10 min audio). Default: Deep.
   - **Include**: checkboxes for Summary, To-dos. Default: off.
3. Transcription + diarization run with the expected-length progress bar.
4. **Speaker naming screen** appears after initial transcription — user names the detected speakers (auto-filled from "Hi, this is X" intros and from the voice library).
5. LLM reconciliation runs with names + optional voice-library match + domain hint (auto-inferred or asked).
6. **Interactive review** — uncertainties appear inline as highlighted spans with popovers; a counter badge (e.g. "3 to review") lets the user jump between them. Each popover has A / B choice buttons and a Play Context button with 2s / 5s / 10s selector. User can skip, accept either option, or type a manual override.
7. User can freely toggle between Verbatim and Clean views of the same transcript.
8. If Summary/To-dos were enabled, the side pane populates with editable text. Prominent Copy button on each.
9. Export — with a checkbox for "Include summary and to-dos in exported transcript."

### Studio

"Give me every knob." Everything above plus:

- Explicit **tier picker**: Standard / Deep Review / Verified / Perfect, with projected cpWER and processing time.
- **Advanced summary options**: length (*High-Level* / *Brief* / *Detailed*) and a special-instructions text box passed to the LLM.
- Per-project **domain hint** dropdown (legal, medical, technical, business, general, or free-text).
- **Voice library manager**: list all known voiceprints, rename, merge duplicates, delete.
- **Pipeline Inspector**: diagnostic panel showing which pipeline stages ran, their time + output, and which signal channels (acoustic, lexical, LLM) contributed to each speaker decision.
- **Manual Editor** on demand (already built).
- **Process Log** visible on demand (already built).
- **Diagnostic Mode** toggle (already built).
- **Multi-pass controls**: force FA on/off, choose Engine A & B models, override smoother parameters.

## The shared flow (same pipeline, three surfaces)

All three modes flow through the same eight-stage pipeline. The modes differ only in which stages are interactive vs. automatic.

| Stage | What happens | Quick Take | Deep Read | Studio |
|---|---|---|---|---|
| 1. Import | Audio validated, project created, recording time derived from metadata | silent | silent | visible, editable |
| 2. Standard transcription | Engine A (Parakeet) transcribes; SpeakerKit diarizes | progress dot | progress bar | process log |
| 3. Engine B | Whisper transcribes in parallel (for Deep tier) | silent | progress dot | verbose log |
| 4. LLM reconciliation | Qwen 8B reconciles A+B using speaker names + domain | progress dot | progress bar with streaming | full LLM output visible |
| 5. Speaker naming | User confirms auto-detected names | inline card | dedicated screen | dedicated screen + voice library |
| 6. LLM refinement | Second pass using speaker names & domain hint | automatic | automatic | visible, skippable |
| 7. Interactive review | User resolves LLM-surfaced uncertainties | max 5 inline highlights | all uncertainties + counter | all + quality panel |
| 8. Summary / todos | Optional LLM summary + to-do extraction | off by default | opt-in checkboxes | length picker + special instructions |
| 9. Export | PDF / Markdown / DOCX / plain text | one-click Legal PDF to Desktop | format picker + include-summary checkbox | full export matrix |

## Key design specifications

### Verbatim vs. Clean (simultaneous generation)

The LLM reconciliation prompt produces **two** versions of each turn in a single pass (one prompt, two structured outputs). The user toggles between them with a button in the transcript header. The choice is remembered per-project. Either can be exported independently.

Why both at once: the incremental compute cost is small (one LLM pass instead of two prompts), and the UX win is magical — no regeneration, instant switching.

### The LLM question loop

After initial reconciliation, the LLM produces a list of uncertainty items:
- **Text uncertainty**: "In turn 12, did the speaker say 'scienter' or 'center'?" Options: A/B + manual entry.
- **Speaker confirmation**: "I'm 70% sure the voice at 03:24 is Marie, but it could be an unidentified third speaker. Confirm?" Options: Marie / Unknown speaker / Different known speaker.
- **Proper noun spelling**: "'Anthony' or 'Antony'? 'Kirby' or 'Kerby'?" Options: A/B + manual + "add to project lexicon" checkbox.

Each item renders inline in the transcript as a highlighted span with a popover. The popover includes:
- The uncertain text in context (3 words before and after).
- The options (buttons).
- **Play Context** button with a 2/5/10s selector — plays audio around the moment.
- Skip / Dismiss.

A persistent counter ("3 to review") in the transcript header tracks progress. Keyboard: ⌘→ to jump to next unresolved, ⌘← for previous, ⌘1/⌘2 to pick option A/B.

After the user resolves (or skips) all items, a **second LLM pass** runs with the confirmed answers baked into the prompt. This produces the final reconciled transcript.

Batching: LLM returns all questions at once per pass. We don't stream individual questions as they arise.

### Speaker naming + voice library

**Auto-detection**: on the first transcription pass, a lightweight LLM scan looks for "Hi, this is X" / "Hello, my name is X" / "X speaking" patterns in the first ~90 seconds and pre-fills speaker names.

**Voice library**: stored at `~/Library/Application Support/Consensus/VoiceLibrary/`. Each entry has:
- UUID
- Display name
- Sample clip path (2-5 second WAV extracted from the first confident segment)
- Speaker embedding (256-float vector from SpeakerKit's internal embedding model)
- Projects in which this voice has appeared
- User-tagged: "my voice" / "frequent caller" / "client" / "colleague" / etc.

**During transcription**: after diarization, each detected speaker is compared to the library by cosine similarity on embeddings. Matches above a threshold auto-fill. "My voice" (user-tagged) gets highest priority.

**Speaker naming screen**: presented after Stage 5 in the flow. Shows each detected speaker with:
- A 3-second audio sample (Play button).
- The auto-suggested name (with confidence indicator).
- A text field to type / change.
- A "Save to voice library" checkbox (default on when name is new).

### Summary & to-dos pane

Right-side pane, togglable from a button in the transcript header. Layout:

```
┌─────────────────────────┐
│ SUMMARY              ⟳ │  <- regenerate button
│ ┌─────────────────────┐ │
│ │ Editable text area   │ │
│ │ (generated + user    │ │
│ │  edits)              │ │
│ └─────────────────────┘ │
│ [ Copy ] [ Export .txt ]│
├─────────────────────────┤
│ TO-DOS               ⟳ │
│ ┌─────────────────────┐ │
│ │ - [ ] Task 1 (Brant) │ │
│ │ - [ ] Task 2 (Marie) │ │
│ │ - [ ] ...            │ │
│ └─────────────────────┘ │
│ [ Copy ] [ Export .md  ]│
└─────────────────────────┘
```

**Editable**: user can modify freely. Changes persist.
**Regenerate** (per-section): re-runs LLM on the same transcript. Preserves user edits unless they confirm overwrite.
**Copy**: full content of that section to clipboard.
**Export .txt / .md**: section as a standalone file.

In Studio mode, an additional row appears above Summary:
- **Length**: High-Level / Brief / Detailed (segmented control).
- **Special instructions**: expandable text box ("Focus on financial commitments" / "Write in a casual tone" / "Exclude small talk").

At export time, a single checkbox in the export panel: "Include summary and to-dos." If on, the transcript export file gets the summary and to-dos appended.

### Project Library window

A separate window (not a sidebar). Accessible from:
- File menu → "Project Library" (⌘L)
- Toolbar icon in the main window
- Keyboard shortcut ⌘L to toggle open/closed

Layout: a clean list/grid view. Each project row shows:
- Name (audio file name or custom title)
- Date + duration
- Speaker names (chips with the voice-library colors)
- Quality tier badge
- Auto-generated one-sentence summary
- Status (In progress / Verified / Exported)

Sort: Most Recent / Name / Duration. Filter: by speaker, by tier, by date range.
Actions: Open / Share / Show in Finder / Delete / Duplicate / Re-run from Scratch.

### Project model

Simplified versus the current structure. Each project on disk:

```
~/Library/Application Support/Consensus/Projects/<UUID>/
  project.json         - metadata, speaker mapping, settings
  audio.m4a            - (soft link to the user's file, with a copy fallback)
  passes/
    standard.json      - first-pass Parakeet
    deep.json          - LLM-reconciled (the one users see by default)
    verified.json      - if Studio ran higher tier
    manual.json        - user-edited version (if any)
  summary.json         - editable summary + todos + user instructions
  exports/             - history of exported files
```

Single active pass at a time; others retained for comparison. Verbatim and Clean are two fields on the same pass — not separate passes.

### Export targets

All modes support: Legal PDF, plain text, Markdown, DOCX, SRT/VTT.
New (from this rewrite): Markdown with Obsidian-compatible frontmatter.

Markdown/Obsidian export shape:
```markdown
---
title: Call with Marie Larsen
date: 2026-04-21
duration: 7m 36s
speakers: [Brant Kuehn, Marie Larsen]
tags: [consensus/transcript, legal, consultation]
---

# Call with Marie Larsen — 2026-04-21

## Summary
...

## To-dos
- [ ] ...

## Transcript

**Brant Kuehn** 00:00:02
Hello, this is Brant Kuehn.

**Marie Larsen** 00:00:04
Yes, hi, it's Marie.
```

### Timestamp correctness (EXTRA POINT A)

Preserve the current fix: recording start time = `audio metadata creation_time − audio duration`. The metadata's `creation_time` represents when the recording FILE was finalized (i.e., end of recording), so we subtract duration to get the start. Fallback to filesystem creation date only if the container metadata is missing.

Keep this logic in the new `TranscriptionService.recordingStartTime()` static method exactly as it is.

### Visual identity direction

**Immediate**: keep the Deep Slate + Indigo accent language, but upgrade typography. Move to a high-end typeface stack:
- **Display/UI**: SF Pro → [Inter Display](https://rsms.me/inter/) or [Geist](https://vercel.com/font) for a more editorial feel
- **Body transcript**: SF Pro → [Source Serif Pro](https://github.com/adobe-fonts/source-serif) or [Charter](https://en.wikipedia.org/wiki/Charter_(typeface)) — a serif reads better for long transcripts
- **Monospace**: SF Mono → [JetBrains Mono](https://www.jetbrains.com/lp/mono/) or [Berkeley Mono](https://berkeleygraphics.com/typefaces/berkeley-mono/) for timestamps and metadata

The typeface change alone will make the app feel 2x more considered. Everything else can stay the same visually until we do the Claude Design brief.

**Later**: write a Claude Design brief capturing the product's personality (precise, editorial, privacy-first, quietly powerful) and commission a visual refresh. Target mid-May.

## Implementation phases

**Phase 0 — Fresh branch + data model refactor** (2-3 sessions) — **SCAFFOLDING COMPLETE, April 21, 2026 (evening)**
- [x] `rewrite-2026-04` branch created from main's working tree (option 2 from kickoff: carry April 21 breakthrough work onto the branch; main stays at Initial commit).
- [x] New `Transcribo/App/` directory structure (`Model/`, `Theme/`, `ViewModels/`, `Views/`, `Resources/Fonts/`).
- [x] `ProjectDocument.swift` — new top-level project type with `AudioAsset`, `Speaker`, `PassKind`, `ProjectSettings`, `ProjectLexicon`, `ExportEntry`, `SummaryDocument`, and a pure `ProjectPaths` resolver.
- [x] `VoiceLibrary.swift` — voice identity schema (UUID + display name + 256-float embedding + tags incl. `.myVoice`), `VoiceLibraryPaths`, and cosine-similarity matcher.
- [x] `ModeState.swift` — Quick Take / Deep Read / Studio enum with display metadata.
- [x] Typography dropped in: Inter, Source Serif 4, JetBrains Mono (all OFL 1.1 variable fonts, roman + italic, license files bundled). Registered at app launch via `FontRegistration`. Typography catalog in `ConsensusType`.
- [x] `AppSettings.useRewrittenUI: Bool` (default false) — runtime toggle between legacy and new UI.
- [x] `swift build` and `./build-app.sh --release --install` both pass clean. Installed `Consensus.app` unchanged in behaviour.
- [ ] Legacy-project migration path (read-only "Legacy Project" import for existing `TranscriptionProject` files on disk) — deferred to Phase 1 prep, lives with the ViewModel layer.
- [ ] On-disk load/save for `ProjectDocument` and `VoiceLibrary` — deferred to Phase 1 prep, lives with the ViewModel layer.

**Phase 1 — Deep Read end-to-end** (3-4 sessions) — **1a + 1b COMPLETE, April 21 evening**
- [x] **Phase 1a**: store layer (`ProjectLibrary`, `VoiceLibraryStore`), `DeepReadViewModel` skeleton, idle→setup stages wired, `DeepReadRootView` (stage router), `DeepReadDropView` (polished drop target), `DeepReadSetupView` (Speed/Include card), `RewrittenSurface` (root wrapper with lazy VM init), `useRewrittenUI` toggle in Settings. All behind the `useRewrittenUI` flag; legacy UI unchanged.
- [x] **Phase 1b**: `TranscriptPass` model type, `StandardPassRunner` (Parakeet + SpeakerKit + merge adapter), `startTranscription()` runs the real Standard-tier pipeline end-to-end, pass persisted to `<project>/passes/standard.json`, speaker roster built with palette indices, `DeepReadReviewView` renders the transcript with speaker chips, Source Serif body, JetBrains Mono timestamps, and a diarization confidence pill.
- [~] **Phase 1c**: *(1c.1 done)*
  - [x] **1c.1**: `SpeakerNamingView` shows after transcription; user confirms or renames speakers; names persist on `project.speakers` with `isConfirmed`. Skip and Continue (⌘↩) buttons. Speaker chips use palette colours.
  - [x] **1c.2**: `IntroScanner` (regex-based "Hi, this is X" / "My name is X" / "X speaking" detection) pre-fills naming suggestions from the Standard pass. `DeepPassRunner` wraps WhisperKit + `LLMReconcileService` to produce the `.deep` pass on top of the Standard pass when Speed ≥ Deep; confirmed names feed in as `knownSpeakerNames`; `.deep` is persisted and becomes `project.activePass`. Fails gracefully to the Standard pass with an alert if the deep run errors. Voice library match still pending (Phase 4).
- [~] **Phase 1d**: *(1d.1 done)*
  - [x] **1d.1**: Uncertainty popovers (LLM-flagged turns are amber-highlighted; clicking Review shows a popover with Play Context and Mark Resolved actions; header shows "N to review" badge that jumps to the next unresolved uncertainty). `AudioContextPlayer` reused from the legacy Manual Editor. Resolved state is per-session (cleared on project close).
  - [ ] **1d.2**: Verbatim/clean toggle — requires extending `LLMReconcileService`'s prompt to produce both in one pass, stored as `StylePair` on TranscriptPass.
  - [ ] **1d.3**: A/B choice + manual override in the uncertainty popover — requires the LLM to surface per-turn alternatives, not just an `isUncertain` flag. Biggest prompt change.
  - [x] **1d.4**: Keyboard shortcuts in the review view — ⌘J (next uncertainty), ⌘K (previous), ⌘. (close popover), ⌘P (play/stop context, within popover), ⌘R (mark resolved, within popover). ⌘J/⌘K use J/K rather than arrow keys to avoid clashing with text-field cursor navigation; discoverable via the "N to review" badge's tooltip.
- [~] **Phase 1e**: *(1e.1 done)*
  - [x] **1e.1**: `TranscriptExporter` (plain text, Markdown, Obsidian Markdown with YAML frontmatter). Toolbar adds **Copy** menu (⇧⌘C for Markdown) and **Export…** menu (⌘E for Markdown, Save Panel). Appears only in `.reviewing` stage so there's no naked export affordance before a transcript exists.
  - [x] **1e.2**: `SummaryRunner` wraps `TranscriptCleanupService.process(task: .summarize)` and parses its two-section output ("ACTION ITEMS & DELIVERABLES", "KEY POINTS") into a structured `SummaryDocument`. To-do extractor is tolerant of bulleting style and resolves "[NAME]: …" prefixes against the project's speaker roster. Persists to `<project>/summary.json`.
  - [x] **1e.3**: `SummaryPane` — right-side pane in the review view. Editable summary text (auto-persist on edit), checkable/editable to-dos, per-section Copy, section-level Regenerate, "Regenerated 3m ago" timestamps. Empty-state card with a single Generate button. Running-state card with progress bar + token counter. Error-state card with Retry. Toolbar toggle (sidebar icon) when in `.reviewing`; auto-shown when `settings.includeSummary` or the project has existing summary content on disk.
  - [x] **1e.4**: `ExportSheet` — sheet-based structured export UI with radio-style format picker (Plain text / Markdown / Obsidian), `Include summary & to-dos` toggle (disabled + hinted when no summary exists), and footer actions (Copy / Save…). Toolbar **Export** menu gains an "Export with options…" entry (⇧⌘E) that opens the sheet; quick "Save as X…" items still live at the bottom of the menu for speed.
- Plan-defined views, status column:
  - [x] `DeepReadSetupView` · [x] (generic) progress view · [ ] `SpeakerNamingView` · [ ] full `TranscriptReviewView` (basic version shipped) · [ ] `UncertaintyPopover` · [ ] `SummaryPane` · [ ] `ExportSheet`
- VM: `DeepReadViewModel` — shared orchestrator for all three modes. Stage machine covers all eight flow states; 1c/1d/1e unstub the later stages.

**Phase 2 — Quick Take** (1 session) — **DONE, April 21 evening**
- [x] Mode picker chips on the drop view (Quick Take / Deep Read / Studio) with icon, label, and tagline; selection persists across launches via `AppSettings.rewrittenDefaultModeRaw`.
- [x] `beginImport(from:)` branches on mode: Quick Take skips the `.setup` stage entirely and kicks off transcription immediately (zero configuration screens per the plan). Deep Read + Studio still land on the setup card.
- [x] Speed auto-picks from audio duration for Quick Take — `.deep` for ≤30 min (fits inside the single-shot LLM context), `.standard` otherwise.
- [x] Summary + to-dos default to off for Quick Take.
- [ ] Export to Desktop as Legal PDF + Markdown by default (deferred; needs PDF renderer in Phase 1e.4+).
- [ ] Max-5 uncertainty cap in Quick Take (deferred polish).

**Phase 3 — Studio** (2-3 sessions) — **partial ship, April 21 evening**
- [x] Studio setup card: all four SpeedTier rows (Standard / Deep / Verified / Perfect) in vertical stack with tagline and radio affordance, instead of Deep Read's two-chip picker.
- [x] Domain hint picker: General / Legal / Medical / Technical / Business chips + a "Custom…" text field for free-form domains. Wired through `DomainHint.custom(String)`.
- [x] Advanced summary knobs when `includeSummary` is on: length segmented picker (High-level / Brief / Detailed) bound to `SummaryDocument.length`, and a multi-line "Special instructions" text field bound to `SummaryDocument.specialInstructions`.
- [x] Pipeline Inspector: `gauge.medium` toolbar button in Studio mode opens a sheet with PASS / ENGINES / QUALITY / STAGE TIMINGS sections, timings sorted by canonical pipeline order with mono-font values, all text selectable.
- [ ] Manual Editor + Process Log + Diagnostic Mode integration (deferred — the legacy views still work; integration into the new toolbar needs a routing decision).
- [ ] Multi-pass controls (force FA on/off, engine model overrides, smoother parameter overrides) — deferred, needs cross-cutting service changes.

**Phase 4 — Voice library** (1-2 sessions)
- Auto-detect from "Hi, this is X" via a small LLM scan of the first 90s.
- SpeakerKit embedding extraction for library storage.
- Match-on-transcription.
- Voice Library manager view (Studio only).

**Phase 5 — Project Library window** (1 session)
- Rip out the current sidebar list. Replace with an openable window.
- Filters, sort, project cards.

**Phase 6 — Polish + Claude Design brief** (ongoing)
- Animations, loading states, empty states.
- Write Claude Design brief and iterate on aesthetic refresh.

## What happens to the current app during the rewrite

The current main branch stays shippable throughout. I'll do the rewrite on a `rewrite-2026-04` branch and merge to main only when a phase is user-verified. At any point, you should be able to install the current Consensus.app without interrupting your workflow on real calls.

Existing projects get a **Legacy Projects** section in the new Project Library, read-only. They can be opened for reference but new work goes through the new flow.

## What I'm NOT touching

- `TranscriptionService`, `FluidAsrTranscriptionService`, `WhisperModelDownloadService` — ASR pipeline stays.
- `SpeakerKitDiarizationService`, `DiarizationService` — diarization stays.
- `LLMReconcileService` — just built; stays.
- `SegmentMerger`, `ConfidenceMergeService`, `ForcedAlignmentService`, `Qwen3ForcedAlignmentService`, `TranscriptManualEditorCodec` — all stays.
- `TranscriptCleanupService` — stays, used for summaries and the LLM question-generation.
- Benchmark harness at `Scripts/benchmark/` — stays and becomes more important (every phase should be benchmarked against ground truth before shipping).

## Confirmed decisions (April 21, 2026)

1. **Mode names**: ✓ **Quick Take / Deep Read / Studio**.
2. **Summary pane placement**: ✓ right side, togglable, editable, per-section copy/export.
3. **Project Library**: ✓ separate openable window (⌘L), not a sidebar.
4. **Typography pairs**: ✓ **Inter Display** (or Geist) for UI + headings, **Source Serif Pro** for transcript body, **JetBrains Mono** (or Berkeley Mono if licensing allows) for timestamps/metadata.
5. **Phase ordering**: ✓ Deep Read first (Phase 1), Quick Take trimmed from it (Phase 2), Studio extended from it (Phase 3).

## Session kickoff checklist

The next session should begin by running through this checklist before writing any code:

1. **Read this plan document top to bottom** to rebuild context.
2. **Read the latest April 21 PROJECT_HISTORY entries** — the two breakthrough entries, the 3-engine-plot-twist entry, and the rewrite-kickoff entry. They contain the findings that justify the new architecture.
3. **Decide on branching strategy**:
   - Option A: create a `rewrite-2026-04` branch, do all work there, merge to main when Phase 1 is user-verified. **Preferred** — keeps shipping app stable.
   - Option B: do it in-place on main. Simpler, but risks breaking the shipping app while the rewrite is in progress.
4. **Phase 0 concrete tasks (first coding session after checklist)**:
   - Create new directory `TranscriboApp/Transcribo/App/` for rewritten ViewModels + Views.
   - Create `ProjectDocument.swift` as the new top-level project model (replacing the current sprawling `TranscriptionProject`).
   - Create `VoiceLibrary.swift` model + on-disk storage layout.
   - Create `ModeState.swift` enum (`.quickTake`, `.deepRead`, `.studio`).
   - Drop in **Inter Display** and **Source Serif Pro** as bundled fonts (check licensing — both should be OFL / free for commercial use).
   - Leave old ViewModels and Views in place; do NOT remove anything yet. The old app still needs to build and ship while the rewrite happens.
   - Add a compile flag or `AppSettings.useRewrittenUI: Bool` so we can ship the old + new side by side during development.
5. **Do NOT start Phase 1 coding until Phase 0's data model is stable.** Phase 0 should compile clean with the old app still working.

## Budget / pacing

Original estimate: ~10-12 sessions end-to-end; first usable version at session 5-6.
Rough session allocation:
- 1 session: Phase 0 (data model + typography + branch).
- 3-4 sessions: Phase 1 (Deep Read end-to-end).
- 1 session: Phase 2 (Quick Take).
- 2-3 sessions: Phase 3 (Studio).
- 1-2 sessions: Phase 4 (Voice library).
- 1 session: Phase 5 (Project Library window).
- 1-2 sessions: Phase 6 (Polish + Claude Design iteration).

Between sessions, the user will test with real calls and flag anything that needs adjustment. Benchmark harness (`Scripts/benchmark/`) runs before every merge to main to confirm the rewrite hasn't regressed pipeline quality.
