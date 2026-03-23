# BDK Transcribo

`BDK Transcribo` is a native macOS app for local transcription and speaker diarization.
The active product lives in [TranscriboApp](/Users/brantkuehn/Projects/BDK-Transcribo/TranscriboApp).

## Current Product Direction

- Native SwiftUI macOS app
- Local transcription via WhisperKit
- Local speaker diarization via FluidAudio
- Persistent transcription projects with saved transcript quality metrics
- Built-in Help Center, first-run welcome tour, and demo project
- Export to text, Markdown, JSON, SRT, RTF, DOCX, and legal-style PDF

## Project Layout

- [TranscriboApp](/Users/brantkuehn/Projects/BDK-Transcribo/TranscriboApp): active macOS application
- [Legacy/PythonPrototype](/Users/brantkuehn/Projects/BDK-Transcribo/Legacy/PythonPrototype): archived Python/Gradio prototype
- [ROADMAP.md](/Users/brantkuehn/Projects/BDK-Transcribo/ROADMAP.md): product and implementation roadmap

## Run The Native App

```bash
cd /Users/brantkuehn/Projects/BDK-Transcribo/TranscriboApp
swift build
swift run
```

The package currently targets macOS 15 and uses Swift Package Manager.

## Smoke Test With Local Audio

You can run the real pipeline headlessly against a local file and save a disposable project workspace:

```bash
cd /Users/brantkuehn/Projects/BDK-Transcribo/TranscriboApp
swift run Transcribo -- --smoke "/path/to/audio.m4a" --engine whisper --model tiny --output-dir "/tmp/transcribo-smoke"
```

This validates transcription, diarization, project persistence, and export generation in one pass.

For Deep Review engine validation you can also run:

```bash
swift run Transcribo -- --smoke "/path/to/audio.m4a" --engine parakeet-v3 --output-dir "/tmp/transcribo-smoke-parakeet"
```

Deep Review now defaults to `Parakeet v3`, while the standard transcription path stays on WhisperKit.

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
