# Consensus

Consensus (formerly BDK Transcribo) is a privacy-first macOS app for local
transcription and speaker diarization. Its hallmark is Deep Review: multiple
transcription engines compared and reconciled — with audio evidence — into
the lowest-error transcript the machine can defend. All processing happens
on-device.

## Current Product Direction

- Native SwiftUI macOS app with three tiers: Quick Take, Deep Read, Studio
- VibeVoice-ASR canonical transcription with speaker diarization
- Patch-based Deep Review: second-opinion engines + local audio re-checks
  propose exact patches; deterministic gates decide
- Headless `consensus` CLI for unattended automation (see `CLI.md`)
- Persistent transcription projects with quality metrics and voice library
- Export to text, Markdown, JSON, SRT, RTF, DOCX, and legal-style PDF

## Project Layout

- `TranscriboApp/`: the Swift package (GUI app + headless CLI over one core)
- `Packaging/`: CLI release tarball and installer
- `Scripts/`: benchmark harness (WER/DER scoring against gold fixtures)
- `Legacy/PythonPrototype/`: archived Python/Gradio prototype
- `ROADMAP.md`, `CONSENSUS-REMAKE-PLAN.md`: direction and active plan

## Build And Run

The package targets macOS 15 and uses Swift Package Manager. Two executable
products share one core library:

```bash
cd TranscriboApp
swift build                              # builds everything
./build-app.sh --release --install       # assembles the .app bundle (GUI)
swift build -c release --product consensus   # the headless CLI
```

`build-app.sh` needs full Xcode plus the Metal Toolchain (it compiles
`mlx.metallib` into the bundle). The headless CLI and its automation story
are documented in `CLI.md`; distribution packaging lives in `Packaging/`.

## Onboarding And Help

- First launch now opens a welcome tour with direct actions for `Browse Audio`, `Open Demo Project`, and `Help Center`
- The sidebar includes a `Help Center` workspace plus quick actions for replaying the tour and opening the demo
- The built-in demo project ships with saved Standard, Deep Review, and Consensus passes so users can explore review and reconciliation without downloading models or importing audio

## Current Substance Work

The active development track is focused on:

1. repo consolidation around the native app
2. persistent transcription projects and reopenable work
3. saved quality metrics for transcription and diarization
4. Deep Review with saved pass comparisons, Parakeet integration, and a manual reconciliation workspace
5. onboarding/help and UI redesign after the persistence layer is stable
