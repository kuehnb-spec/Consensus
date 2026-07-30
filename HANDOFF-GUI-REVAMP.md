# Handoff: Consensus GUI revamp

Written **2026-07-30** for a fresh session working in `~/Projects/Consensus` on the Mac Studio. Everything below was verified on 2026-07-30 unless marked otherwise. Read this before `UI-OVERHAUL-PLAN.md` — parts of that plan are stale, and this says which.

## Home base: the Mac Studio

As of 2026-07-30 the Studio (`brantkuehn.local`, Tailscale `100.90.27.116`) is the canonical place to build and develop Consensus. It is always on, Brant remotes into it, and the PADD capture pipeline that consumes the CLI already runs there.

Verified on the Studio 2026-07-30, building merged `main` in a clean clone:

- Full **Xcode.app** installed, `xcode-select -p` → `/Applications/Xcode.app/Contents/Developer`
- **Swift 6.3.3** (`swiftlang-6.3.3.1.3`), target `arm64-apple-macosx26.0`
- ✅ **The CLI builds clean**: `swift build -c release --product consensus` → a 50 MB binary in ~191 s
- ❌ **The GUI product does not link under SwiftPM** — see below. This is the first thing the revamp has to solve.

The MacBook Pro was the previous dev machine and produced the v2.0.0 CLI release. It is being retired as a build host.

### The GUI build is broken under SwiftPM — start here

> **RESOLVED (2026-07-30, later the same day):** the real cause was the
> case-collision "related trap" below, not SwiftUICore. The GUI and CLI
> product staging directories (`Consensus.product/` vs `consensus.product/`)
> are the same path on APFS, so a full `swift build` linking both at once
> corrupted one link — that is what produced the missing `_ConsensusGUI_main`
> / `_ConsensusCommandLine_main` symbols. The SwiftUICore line is only a
> warning (the MacBook shipped working app bundles from plain SwiftPM
> executables for months). Fix: the GUI product is renamed `ConsensusApp`
> (`build-app.sh` stages it into the bundle as `Consensus`; the CLI keeps its
> deployed `consensus` product name). A full `swift build` now completes and
> the GUI binary launches on the Studio. No `.xcodeproj` needed.

A plain `swift build` (no `--product`) fails at the link step:

```text
Undefined symbols for architecture arm64:
  "_ConsensusGUI_main", referenced from:
      _main in command-line-aliases-file
ld: warning: Could not parse or use implicit file '…/SwiftUICore.framework/…/SwiftUICore.tbd':
    cannot link directly with 'SwiftUICore' because product being built is not an allowed client of it
```

This is the standard SwiftPM limitation: **SwiftUICore is only linkable from a real app bundle target**, not from a bare SwiftPM executable product. There is currently **no `.xcodeproj` or `.xcworkspace` in the repo**, so there is no supported path to build the app today.

This was invisible until now because the release script only ever builds the CLI — `Packaging/build-release.sh` runs `swift build -c release --product consensus`, which never touches the `Consensus` GUI product. The last successful GUI binary in `.build` on the Studio is dated **June 15**, predating the CLI split.

Resolving this is prerequisite work for the revamp. The likely fix is an Xcode app target (a checked-in `.xcodeproj`, or an Xcode-native app wrapper around the existing library targets) so the GUI links as an app bundle while the CLI keeps building via SwiftPM.

**Related trap: the filesystem is case-insensitive.** `Package.swift` declares two products, `Consensus` (GUI) and `consensus` (CLI). On the Studio's APFS these collide — the existing `.build/debug/Consensus` and `.build/debug/consensus` are the *same* 76 MB file. The package already renamed the *target* to `ConsensusCommandLine` for this reason, but the *product* names still collide. Expect confusing results from building both in one directory; build them separately, or rename a product as part of the revamp.

## Repository state

`main` (`69c23f8`) is canonical as of 2026-07-30. Until that day it was **not** — the shipped v2.0.0 CLI lived only on an unmerged `wip/macbook` branch. That merge is now done and pushed.

Branches:

| Branch | What it is |
|---|---|
| `main` | Canonical. Contains the app **and** the headless CLI. |
| `wip/macbook` | Merged into main. Historical. |
| `wip/studio` | **Not merged.** Auto-captured Studio working tree. See below — it holds real work. |
| `rewrite-2026-04` | Older, untouched. |

### Architecture, post-merge

The v2.0.0 work **split the package into a core library plus launchers**. This is the single most important thing to understand before touching the UI, because it moved files:

- Reconciliation UI is no longer `Views/ReconciliationView.swift` — that file was **deleted** by commit `ddb341c` ("Headless CLI + UI consolidation"). The equivalent now lives under `TranscriboApp/Transcribo/App/` as `Views/DeepReadRootView.swift`, `Views/PipelineInspectorView.swift`, `ViewModels/DeepReadViewModel.swift`, `Model/TranscriptPass.swift`, `Services/PatchReviewRunner.swift`, plus `Models/ReconciliationModels.swift`.
- `TranscriboApp/Transcribo/Views/` now holds only `ContentView.swift`, `SettingsView.swift`, and `Components/`.
- `FluidAudio is vendored`: `Package.swift` uses `.package(path: "Vendor/FluidAudio")` and those 317 files are tracked in git, so the repo is self-contained and builds without fetching that dependency.

Two front ends over one core: the SwiftUI app, and the `consensus` CLI. **They share the same pipeline code**, so a change to core behavior affects both. The CLI is what the PADD pipeline calls; breaking it silently breaks Brant's capture loop.

## What is stale in `UI-OVERHAUL-PLAN.md`

That document (June 3, 16 KB) is still the right *design intent* — "high-end workstation feel, similar to Linear or Raycast," with Deep Review as the hallmark feature. Use it for direction. But it predates the CLI split, so:

- **Its file map is wrong.** Phase 0's table points at `Views/ContentView.swift`, `Views/WelcomeTourView.swift`, `Views/HelpCenterView.swift`, `Services/DemoProjectFactory.swift`, `Services/ProjectStore.swift`, `TranscriboApp.swift`. Verify each path against the current tree before editing; several moved under `App/`.
- **Phase 0 (the rename) is still unfinished.** `README.md` alone still says "BDK Transcribo" 8 times and refers to a `~/Projects/BDK-Transcribo/` path that no longer exists. The app bundle checked into the repo is still `BDK Transcribo.app`.
- It assumes the UI is the only consumer of the pipeline. It is not — see the CLI note above.

## `wip/studio` — unresolved, and it contains real work

The Studio's uncommitted tree was auto-captured to this branch, so **nothing is lost**, but it was never merged because it conflicts with the refactor. Do not discard it without a decision. What it actually changes, relative to its own starting point (`f7dd012`):

| Change | Verdict |
|---|---|
| `TranscriptionProject.swift` — `hasTranscript` now requires non-empty segments, not just a non-nil pass | **Genuine bug fix.** Worth keeping regardless of anything else. |
| `TranscriptionPipeline.swift` — adds `guard !segments.isEmpty` | **Genuine bug fix**, pairs with the above. |
| `FluidAsrTranscriptionService.swift` — `initialize(models:)` → `loadModels()`, `transcribe` now threads a `TdtDecoderState` | API migration for a **newer FluidAudio (0.15.3)** |
| `Package.swift` — remote FluidAudio `.upToNextMinor(from: "0.15.3")` | The upgrade driving it |
| `TranscriptCleanupService.swift` — drops unused bindings, `displayName(for:)` loses its `?? "UNKNOWN"` | Warning cleanup + API adaptation |
| `Brainstorming/2026-06-16 - Benchmark Recovery and Model Research.md` | Studio-only; absent from main. Preserve. |
| `AGENTS.md`, `CLAUDE.md`, `PROJECT_HISTORY.md` | Diverged; reconcile by hand |

**Brant's decision (2026-07-30): do this work as part of the GUI revamp, not before it.** Both items below are in scope for the revamp session; they were deliberately left un-merged so they get handled with attention rather than as a merge side-effect.

### Task A — forward-port the two bug fixes

> **DONE, with a correction (2026-07-30):** the two hunks described below are
> not actually present on `origin/wip/studio` — its `hasTranscript` is still
> `activePass != nil` and its `TranscriptionPipeline` has no empty-segments
> guard. What main already had (from the June 30 empty-pass work) covers the
> live path: `VibeVoiceTranscriptionService` rejects zero-segment parses,
> `TranscriptionViewModel` guards empty results, and the CLI refuses to write
> an empty pass. The one genuinely missing piece — legacy
> `TranscriptionProject.hasTranscript` treating an empty pass as a transcript
> — is now fixed on main. Task B (FluidAudio strategy) remains open.

Independent of everything else, and worth doing early since they are small and correct. Retrieve them with:

```bash
git diff f7dd012 origin/wip/studio -- \
  TranscriboApp/Transcribo/Models/TranscriptionProject.swift \
  TranscriboApp/Transcribo/Services/TranscriptionPipeline.swift
```

Both address the same underlying defect — a transcription pass that produced **zero segments** was still treated as a real transcript, so the UI would show a project as transcribed when it had nothing in it. `hasTranscript` now requires non-empty segments, and the pipeline guards against emitting an empty pass. Apply them to the current tree (paths may have shifted under `App/`), and confirm the UI reflects the corrected state.

### Task B — decide the FluidAudio dependency strategy

The genuinely open question, and it needs testing rather than a coin flip:

- `main` **vendors** FluidAudio (`.package(path: "Vendor/FluidAudio")`, 317 tracked files) at the version v2.0.0 shipped and was validated against.
- `wip/studio` moves to **remote FluidAudio `0.15.3`** with the API migration half-done — `initialize(models:)` → `loadModels()`, and `transcribe` now threads a `TdtDecoderState` built from `manager.decoderLayerCount`.

Whichever way this goes, **re-validate the CLI afterwards**: FluidAudio performs the diarization, the CLI is what the PADD capture pipeline calls, and a regression there silently degrades Brant's capture loop rather than failing loudly. Re-run a known recording and compare speaker counts and segment boundaries before considering it done.

## Guardrails that outlive the UI

These come from how the CLI is consumed downstream. Preserve them through any redesign:

- **Speaker labels are `SPEAKER_A`, `SPEAKER_B`, … and carry no identity claim.** Names inferred from audio are unverified guesses — a real 2026-07-29 recording transcribed "Brant" as "Brent". Any UI that displays a guessed name must mark it unverified until a human confirms it.
- **Confidence is `null` when the engine provides none.** Never fabricate a number.
- **Outputs are written to a temp file and renamed into place**, so a watcher never sees a half-written artifact.
- **Exit codes are contractual**: `0` success, `1` unexpected, `2` input unreadable, `3` transcription failed, `4` output already exists. A calling script branches on these.
- **Transcript text never appears in logs** — filenames, durations, timings, and errors only.

## Where the rest of the record lives

- `CLI.md` — the CLI contract (flags, exit codes, output schema)
- `10-consensus-spec.md` — the v2 spec, with a banner recording what actually shipped vs what was specified
- `Packaging/README-INSTALL.md` — installer, and the VibeVoice/MLX runtime the CLI needs
- PADD dossier at `~/My Drive/Workspace/Projects/PADD/docs/` — doc 10 (spec), doc 12 (the capture loop that consumes this)
- Vault runbook `ops/runbooks/padd-pipeline.md` in `~/obsidian-vault` — how the CLI is invoked in production

## Suggested first moves

1. **Get the Studio tree onto clean `main`.** It is currently dirty and behind; its local changes are preserved on `origin/wip/studio`, so nothing is lost. Confirm the baseline with `swift build -c release --product consensus` (known good, ~191 s).
2. **Fix the GUI build** — the blocker above. Until the app links, nothing visual can be verified. This likely means introducing an Xcode app target.
3. **Task A**: forward-port the two empty-transcript bug fixes.
4. **Finish Phase 0 (the rename).** Small, already scoped, and it removes a persistent source of confusion — the README alone still says "BDK Transcribo" 8 times.
5. **Task B**: settle the FluidAudio dependency strategy, then re-validate the CLI.
6. Then the visual work, re-deriving the file map from the current tree rather than from the June plan.

Order matters for 1–2: there is no point styling an app that cannot be launched.
