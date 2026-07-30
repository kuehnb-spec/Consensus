# Benchmark Recovery and Model Research

Date: June 16, 2026

## What was tested today

The current checkout now builds after the FluidAudio 0.15.3 update, and the headless smoke runner successfully transcribed two available audio fixtures.

### Historical gold audio

Recovered from git history:

- Audio: `/tmp/consensus-benchmark/Brainstorming/vibevoice-test/141_W_54th_3.wav`
- Original expected ground truth name: `TestAudio/141 W 5th St 3 - Manually Revised Transcript.groundtruth.json`

Current run:

- Command: `swift run Consensus -- --smoke /tmp/consensus-benchmark/Brainstorming/vibevoice-test/141_W_54th_3.wav --engine parakeet-v3 --output-dir /tmp/consensus-smoke-141-current`
- Result: 90 segments, 3 detected speakers, 96% average word confidence, 100% average diarization quality, no warnings.
- Export: `/tmp/consensus-smoke-141-current/Exports/141_W_54th_3_transcript.json`

Caveat: the hand-corrected ground truth file was not found in the current repo, Git-tracked files, Spotlight, Obsidian notes, Google Drive paths checked, or the user home search before the scan was stopped. The old benchmark docs prove the file existed locally but it was ignored under `TestAudio/`.

### Clayton Everett regression fixture

Available locally:

- Audio: `/Users/brantkuehn/My Drive/Personal/Audio/Audio-Recordings-from-Desktop/2026-03-19 1145 - Clayton Everett.m4a`
- PDF transcript: `/Users/brantkuehn/My Drive/Personal/Audio/Audio-Recordings-from-Desktop/2026-03-19 1145 - Clayton Everett_transcript.pdf`

Current run:

- Command: `swift run Consensus -- --smoke "/Users/brantkuehn/My Drive/Personal/Audio/Audio-Recordings-from-Desktop/2026-03-19 1145 - Clayton Everett.m4a" --engine parakeet-v3 --output-dir /tmp/consensus-smoke-clayton-current`
- Result: 228 segments, 4 detected speakers, 94% average word confidence, 100% average diarization quality, no warnings.
- Export: `/tmp/consensus-smoke-clayton-current/Exports/2026-03-19 1145 - Clayton Everett_transcript.json`
- Score against parsed PDF reference: 0.00% WER, 28.02% approximate DER.

Caveat: the 0.00% WER means this PDF is almost certainly app-generated or transcript-derived from the same source, not an independent human reference. Keep it as a regression fixture for parsing, export shape, segmentation stability, and speaker-mapping sanity, but not as a true ASR benchmark.

## Historical benchmark baselines to preserve

The April VibeVoice benchmark remains the best true gold-sample evidence because it used the manually revised 141 W transcript:

| Engine | WER | DER | Notes |
|---|---:|---:|---|
| FluidAudio Parakeet v3 + SpeakerKit | 14.72% | 4.96% | Best balanced old baseline |
| WhisperKit Large v3 + SpeakerKit | 10.05% | 47.20% | Strong text, broken speaker labels |
| VibeVoice 4-bit, no hotwords | 9.97% | 7.00% | Matched Whisper text quality with diarization |
| VibeVoice 4-bit + hotwords | 10.21% | 6.43% | Fixed key proper names; 6 GB peak RAM |
| v6 + v8 constrained review | 9.73% | n/a | Best reviewed transcript; repaired 8/8 injected corruptions |

The critical architecture lesson was not "let a big model rewrite the transcript." Voxtral Small Q4 and Q8 both showed dangerous clean-transcript hallucination in the old full-transcript smart-editor test. The safe direction was the tool-constrained patch flow:

1. Treat VibeVoice as the canonical transcript.
2. Use Parakeet/Whisper disagreements only as a heatmap.
3. Re-listen locally to flagged spans.
4. Verify exact masked-cloze candidate patches.
5. Apply only deterministic string patches that pass protected-term and evidence gates.

## Current integration state

The current slim checkout does not contain the older sidecar work. The files exist in git history at commit `14e54e1456588a85cad786c78beba8ba2304c618`, including:

- `TranscriboApp/Scripts/VibeVoiceSidecar/run.py`
- `TranscriboApp/Scripts/PatchReviewSidecar/run_patch_review.py`
- `TranscriboApp/Transcribo/App/Services/PatchReviewRunner.swift`
- `TranscriboApp/Transcribo/Services/VibeVoiceTranscriptionService.swift`
- `TranscriboApp/Transcribo/Services/Qwen3ForcedAlignmentService.swift`
- `Scripts/benchmark/score.py`
- `Brainstorming/vibevoice-test/*`
- `Brainstorming/phase-a-vibevoice-nemotron/*`

Restoring these selectively is the fastest path to model-improvement work.

## Model research summary

### ASR and diarization

1. Keep FluidAudio Parakeet v3 as the default local baseline.
   - It is already integrated, Swift-native, Apple-device oriented, and now builds on FluidAudio 0.15.3.
   - FluidAudio's current model catalog also lists Parakeet TDT-CTC-110M as a smaller faster alternative, plus Japanese and streaming EOU models.

2. Restore VibeVoice 4-bit as the first major ASR upgrade candidate.
   - Microsoft positions VibeVoice-ASR as single-pass long-form ASR with speaker, timestamp, content, hotword support, and 50+ languages.
   - The historical local benchmark already showed it was worth integrating: roughly Whisper-large WER, real diarization, hotword-driven name correction, and about 6 GB peak RAM.
   - Best use: optional premium/Deep Review engine, likely replacing WhisperKit as the comparison pass.

3. Evaluate Cohere Transcribe as a new benchmark candidate, not an immediate app dependency.
   - Cohere's 2026 model is Apache 2.0, 2B parameters, and presented as a strong dedicated ASR model with published Open ASR Leaderboard results.
   - Integration risk: current public path is Transformers/Python, not native Swift/Core ML. It may be best tested through a sidecar first.

4. Track Qwen3-ASR and ForcedAligner for alignment and multilingual coverage.
   - Qwen3-ASR 1.7B/0.6B supports 52 languages/dialects and includes an official forced aligner path for timestamps.
   - Integration risk: official docs emphasize Python, CUDA/vLLM, and Docker. It is promising for experiments, less ready than VibeVoice for a local Apple Silicon app unless we restore/adapt the older Qwen3 CoreML/sidecar work from history.

5. Use Voxtral for constrained audio verification, not primary transcription yet.
   - Mistral's Voxtral family is strong at speech understanding, summarization, and audio Q&A, but the historical Consensus tests rejected free-form transcript editing.
   - Best use: masked-cloze verifier that can only keep/apply exact candidate patches.

### General intelligence / local LLM

1. Update `mlx-swift-lm` experimentally from the current 2.29.x line to 2.31.3 before trying new model families.
   - 2.31.3 is the last 2.x tag, uses `mlx-swift` 0.31.3, adds Qwen3.5 support, tool-call fixes, cache improvements, and Swift concurrency cleanup.
   - 3.31.3 is tempting because it adds Gemma 4 support, but it is the first 3.x release with breaking API changes. Treat it as a separate migration.

2. Add a local model matrix for app tasks:
   - Fast notes and summaries: Qwen3 4B, Gemma 3n E4B text after load testing.
   - Careful reconciliation and global edits: Qwen3 8B, Qwen3.5 8B/14B if 2.31.3 load tests pass.
   - High-RAM "best effort" mode: Qwen3 30B-A3B 4-bit or newer MoE candidates supported by MLX Swift.

3. Design "global revisions" as patch plans, not replacement text.
   - Safe global edits should produce a structured list of proposed patches with before/after, rationale, and affected segments.
   - Summaries, action items, and notes can be freer-form; transcript edits should remain auditable and reversible.

## Recommended next steps

1. Restore the historical benchmark harness and sidecars from commit `14e54e1` into the current branch, but only the pieces needed for VibeVoice, patch review, and scoring.
2. Recreate or recover the missing 141 W ground truth file. Without it, we can smoke-test but cannot make reliable ASR decisions.
3. Add a small in-repo benchmark runner that can:
   - run a selected engine on a fixture,
   - export normalized hypothesis JSON,
   - score WER/DER/cpWER when ground truth exists,
   - save a dated result artifact outside private audio paths.
4. Try dependency update `mlx-swift-lm` 2.31.3 in a separate commit and run `swift build`.
5. Reintroduce VibeVoice as an opt-in Deep Review engine with speaker-name/hotword context populated from project metadata.
6. Rebuild the global revision feature around patch queues and a review UI, not silent transcript replacement.

## Sources checked

- FluidAudio README and model catalog: https://github.com/FluidInference/FluidAudio and https://github.com/FluidInference/FluidAudio/blob/main/Documentation/Models.md
- Argmax/WhisperKit 1.0 release: https://github.com/argmaxinc/argmax-oss-swift/releases
- Microsoft VibeVoice-ASR docs and model card: https://github.com/microsoft/VibeVoice/blob/main/docs/vibevoice-asr.md and https://huggingface.co/microsoft/VibeVoice-ASR
- Qwen3-ASR model card: https://huggingface.co/Qwen/Qwen3-ASR-1.7B
- Cohere Transcribe model card: https://huggingface.co/CohereLabs/cohere-transcribe-03-2026
- Mistral Voxtral announcement and Voxtral Realtime model card: https://mistral.ai/news/voxtral/ and https://huggingface.co/mistralai/Voxtral-Mini-4B-Realtime-2602
- MLX Swift LM releases: https://github.com/ml-explore/mlx-swift-lm/releases
