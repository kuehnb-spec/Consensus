# Roadmap

## Guiding Principles

- Default flow should stay simple and fast.
- High-stakes transcripts should have an explicit quality-upgrade path.
- Export is an output, not the source of truth.
- macOS distribution quality matters as much as transcription quality.

## Phase 1: Consolidate Around The Native App

Status: in progress

- Move the Python prototype into `Legacy/`
- Rewrite root documentation around the Swift macOS app
- Remove mixed-product onboarding that points new users at the prototype
- Standardize the native app as the only shipping path

## Phase 2: Persistent Projects And Saved Metrics

Status: in progress

- Save every transcript as a reopenable project in App Support
- Persist source-audio bookmarks, transcript passes, speaker labels, and export history
- Persist confidence and quality metrics for transcription and diarization
- Add a project library, open/close project flow, and quality inspection view

## Phase 3: Deep Review

Status: in progress

- Add a separate `Deep Review` workflow for high-stakes or poor-audio transcripts
- Keep standard mode single-pass for most jobs
- Run at least two intentionally different full passes in Deep Review
- Save pass outputs, disagreements, and reconciled consensus results inside the project
- Surface disputed spans for human review instead of hiding them
- Current state: projects can now store multiple passes, switch the active pass, run either a comparison Whisper pass or a Parakeet pass from the quality screen, inspect disagreement summaries between saved passes, default new Deep Review work to Parakeet v3, and open a manual reconciliation workspace with editable consensus text

## Phase 4: Help, Onboarding, And Packaging

Status: planned

- First-run onboarding with clear model-download expectations
- Bundled help content and troubleshooting
- Better model and storage management in Settings
- Signing, notarization, and distributable app packaging

## Phase 5: Interface Overhaul

Status: planned

- Redesign the app around a more polished transcription workspace
- Improve hierarchy, density, and visual feedback
- Add better review tools such as waveform, search, filters, and hotspots
- Build UI affordances for saved projects and Deep Review

## Immediate Next Steps

- Add consensus/reconciliation on top of saved pass comparisons
- Evaluate Parakeet v2 and v3 defaults, presets, and model-management UX
- Persist edit/export state more aggressively as users work
- Build onboarding and help around the now-stable project workflow
