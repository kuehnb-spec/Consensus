# FluidAudio 0.12.2 -> 0.17.1: trial and plan (2026-11-11)

Branch `fable/fluidaudio-0.17` (not merged). Upstream source: tag `v0.17.1` of
FluidInference/FluidAudio, copied over `TranscriboApp/Vendor/FluidAudio`
without `.git`.

## What was tried and what broke

1. Replaced the vendored tree wholesale with upstream 0.17.1.
   `vendored-patches-vs-upstream-0.12.2.diff` (here) is the full difference
   between the old vendored copy and upstream v0.12.2: 70 files, ~12k lines,
   most of it a vendored-only `TTS/Kokoro` tree plus the Swift 6 concurrency
   patches (`AsrManager` as `@unchecked Sendable`, `@preconcurrency import
   CoreML`, Diarizer/Sortformer/PocketTTS isolation fixes). **None of those
   patches were needed:** upstream 0.17.1 compiles cleanly under this package's
   Swift 6 toolchain (`AsrManager` is now an `actor`).
2. `swift build -c release --product consensus --build-system native`: FluidAudio
   built; ConsensusCore failed at exactly two call sites, both in
   `Transcribo/Services/FluidAsrTranscriptionService.swift`:
   - `AsrManager.initialize(models:)` is gone → `loadModels(_:)`.
   - `transcribe(_ url:)` now takes `decoderState: inout TdtDecoderState`
     → `TdtDecoderState.make(decoderLayers: await manager.decoderLayerCount)`.
   With those two changes the CLI builds (35-40 s incremental).
3. Behaviour: the in-process Parakeet witness on the Loper Bright clip now
   returns the same words as the external fluidaudiocli 0.17 (58 disputes, 130
   of 1,931 words, 6.8% flag rate, 66.4% recall) in ~24 s total, against 0.12.2's
   1,723 words / 14.0% flag rate / ~160 s.

## Not yet checked (why it is not merged)

- The GUI app was not built or run (Metal Toolchain uninstalled for Xcode
  27.2), so the app's other FluidAudio paths are compiled but unexercised:
  SpeakerKit/Diarizer, Sortformer, Nemotron 3 diarization, streaming ASR,
  PocketTTS. `TTS/Kokoro` (vendored-only) is gone; nothing in ConsensusCore
  referenced it, but confirm the app does not load it at runtime.
- Model cache layout: 0.17.1 found the existing
  `~/Library/Application Support/FluidAudio/Models/parakeet-tdt-0.6b-v3-coreml`
  without downloading; check the diarizer models the same way.
- Package.resolved for the vendored package changed; run a clean resolve.

## Plan

1. Reinstall the Metal Toolchain, build the app (`build-app.sh`), and smoke-test
   Standard (VibeVoice), the Parakeet fallback, Deep Review and diarization on
   one fixture.
2. Re-run the four Proving Ground clips with `--witness parakeet` in process and
   confirm `disputes[]` match `TestCorpus/runs/cli-2.1.1-witness/`.
3. Merge; then drop the external-fluidaudiocli preference in
   `WordWitness.swift` (keep it behind `CONSENSUS_WITNESS_EXTERNAL=1` for one
   release), set `ConsensusVersion.fluidAudio`, and update CLI.md.
4. Start the streaming latency bench on 0.17.1 (gates Second Chair).
