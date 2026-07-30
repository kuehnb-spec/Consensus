# Consensus — Simple Mode Design

## Date: March 25, 2026

## Concept

Consensus has two modes: **Simple** (light theme, minimal UI) and **Advanced** (dark theme, full workstation). The mode toggle persists across launches. The goal is that a non-technical user can drop a file and get a transcript without making any decisions, while a power user retains full control over every parameter.

---

## Simple Mode

### Visual Identity

- **Light theme** — warm white backgrounds, dark text, same indigo accent
- **No sidebar** — single-screen vertical flow, no navigation phases
- **No numbered steps** — just the current state and the next action
- **Minimal chrome** — large type, generous spacing, clear hierarchy

### Theme Tokens (Light)

| Token | Value | Notes |
|---|---|---|
| `background` | #F5F5F7 | Warm white (Apple HIG light) |
| `surfacePrimary` | #FFFFFF | Pure white cards |
| `surfaceSecondary` | #F0F0F2 | Subtle card backgrounds |
| `textPrimary` | #1D1D1F | Near-black |
| `textSecondary` | #6E6E73 | Medium gray |
| `textTertiary` | #AEAEB2 | Light gray |
| `accent` | #6366F1 | Same indigo — the brand anchor |
| `border` | black 8% | Subtle dividers |
| `confidenceGreen` | #34D399 | Same as advanced |
| `confidenceAmber` | #FBBF24 | Same as advanced |
| `confidenceRed` | #F87171 | Same as advanced |

The accent color stays identical so the app feels like Consensus in both modes. Speaker badge palette works on both light and dark backgrounds (already tuned for dark — may need slight saturation adjustment for light).

### User Flow

The entire simple mode is a single vertical screen with three zones:

```
┌─────────────────────────────────────────────┐
│                                             │
│   [Drop audio file here]                    │  ← Zone 1: Input
│   or Browse...                              │
│                                             │
├─────────────────────────────────────────────┤
│                                             │
│   Transcript text with speaker labels       │  ← Zone 2: Result
│   Inline speaker rename fields              │
│   (scrollable)                              │
│                                             │
│   ┌─ Flagged region ──────────────────┐     │
│   │ "litigation" vs "mitigation"  [A][B]│    │
│   └───────────────────────────────────┘     │
│                                             │
├─────────────────────────────────────────────┤
│                                             │
│   Status: "Ready to export"                 │  ← Zone 3: Actions
│   [Export]  [Verify Accuracy]               │
│                                             │
└─────────────────────────────────────────────┘
```

**Zone 1: Input** — Drop zone or file info (once loaded). Collapses to a thin bar showing filename + duration after transcription starts.

**Zone 2: Result** — Empty until transcription completes, then shows the full transcript as a continuous readable document. Speaker labels appear inline with rename-on-click. If verification has been run, flagged regions appear inline (same as the new reconciliation view).

**Zone 3: Action Bar** — Always visible at the bottom. Shows exactly what you can do right now:

| State | Action Bar |
|---|---|
| No file loaded | (empty or "Drop an audio file to start") |
| File loaded, not transcribed | **[Transcribe]** |
| Transcribing | Spinner + "Transcribing... 42%" + **[Cancel]** |
| Transcript ready | **[Export]** + **[Verify Accuracy]** |
| Verification running | Spinner + "Running second engine..." + **[Cancel]** |
| Merge complete, flags exist | **[Export]** + "N spots to review" |
| All flags resolved | **[Export]** (primary, prominent) |
| Exporting | Spinner + "Exporting..." |
| Export complete | "Saved to Desktop" with checkmark |

### What's Auto-Selected in Simple Mode

| Setting | Simple Mode Behavior |
|---|---|
| Transcription model | Auto-select based on hardware (large-v3 if 32GB+ RAM, medium if 16GB, small if 8GB) |
| Language | Auto-detect |
| Min/max speakers | Auto-detect (0, 0) |
| Diarization engine | SpeakerKit (best default) |
| Export format | Legal PDF + plain text to Desktop |
| Deep Review engine | Parakeet v3 (best default) |
| Legal PDF header | Auto-generated from filename + date |
| Polish/cleanup | Not offered (keep it simple) |

### What's Hidden in Simple Mode

- Sidebar navigation
- Model/engine picker
- Speaker count range controls
- Language selector
- Quality metrics (gauges, heatmaps, scores)
- Process log
- Pass history and pass comparison
- Export format grid (uses defaults)
- Legal PDF header customization
- Clock time / elapsed time toggles
- Diarization engine choice
- Summary tool
- Help center (replaced by inline hints)

---

## Advanced Mode

Everything that exists in the current app. The full dark-themed workstation with all controls, metrics, configuration, process log, and pass management.

---

## Mode Toggle

### Placement

A pill toggle in the **window toolbar** (top-right):

```
[ Simple | Advanced ]
```

Or a keyboard shortcut: **Cmd+Shift+S** ("Switch mode").

### Behavior

- Mode persists in `AppSettings` across launches
- Switching modes does NOT lose state — the same project stays open
- If switching from Advanced to Simple mid-workflow, the simple view picks up wherever you are (shows transcript if one exists, shows flags if verification was run)
- If switching from Simple to Advanced, all the detailed views become available with full data

### First Launch

New users see Simple mode by default. The welcome tour mentions that Advanced mode exists ("For full control over models, quality metrics, and export options, switch to Advanced mode in the toolbar").

---

## Implementation Plan

### Approach: Separate View Hierarchy (Option B)

Rather than adding conditionals throughout existing views, build a single `SimpleView.swift` that's a purpose-built minimal UI sharing the same `TranscriptionViewModel`. ContentView checks the mode and renders either:

```swift
if appSettings.isSimpleMode {
    SimpleView()
} else {
    NavigationSplitView { SidebarView() } detail: { ... }
}
```

This keeps the simple view clean and purpose-designed, without cluttering the advanced views with mode checks.

### Files to Create

| File | Purpose |
|---|---|
| `SimpleView.swift` | Single-screen simple mode layout |
| `SimpleDropZone.swift` | Light-themed audio drop zone |
| `SimpleActionBar.swift` | Bottom action bar with context-aware buttons |
| `ConsensusTheme+Light.swift` | Light theme color tokens |

### Files to Modify

| File | Change |
|---|---|
| `ContentView.swift` | Mode switch in body |
| `AppSettings.swift` | `isSimpleMode: Bool` preference |
| `ConsensusTheme.swift` | Add `static func colors(for mode:)` or environment-based theming |

### Dependencies

- Finalized verification pipeline (so simple mode can auto-run it)
- Finalized export defaults (so one-click export works)
- Tested merge quality on real transcripts

### Build Order

1. Light theme tokens
2. `SimpleView.swift` (layout + zones)
3. Mode toggle + AppSettings persistence
4. Auto-selection logic (model based on RAM, etc.)
5. One-click export to Desktop
6. Polish and transitions

---

## Open Questions

- Should simple mode have a project library at all, or just always work on "the current thing"? Leaning toward no library — drop a file, get a transcript, export, done. If you want to manage projects, switch to Advanced.
- Should the mode toggle be visible in simple mode, or accessed via menu bar only? If it's too prominent, it might confuse simple-mode users. If it's too hidden, power users won't find it.
- Should simple mode support opening existing projects, or only new transcriptions? If someone opens Consensus from a project file (future: double-click .consensus file), it should work in either mode.
- What happens to the window title in simple mode? Currently shows the project name. In simple mode, maybe just "Consensus" or the audio filename.
