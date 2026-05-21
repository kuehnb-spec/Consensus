# Source Index — Consensus

Per the external-asset pattern in `~/Desktop/REORG_PROTOCOL.md` Section 5, large model binaries are not stored in this repo. They live on the local disk under `Brainstorming/` (currently) and are referenced here.

## Untracked Model Assets

| Location | Approx. Size | Purpose |
|---|---|---|
| `Brainstorming/phase-a-vibevoice-nemotron/gguf/` | ~25 GB | NVIDIA Nemotron 3 Nano Omni 30B Q4_K_XL + mmproj |
| `Brainstorming/phase-a-vibevoice-nemotron/qwen-omni/` | ~13 GB | Qwen 2.5 Omni 7B Q4_K_M and Q8_0 + mmproj |
| `Brainstorming/phase-a-vibevoice-nemotron/qwen3-asr/` | ~2.5 GB | Qwen3 ASR 1.7B Q8_0 + mmproj |
| `Brainstorming/phase-a-vibevoice-nemotron/voxtral-small/` | ~40 GB | Voxtral Small 24B Q4_K_M and Q8_0 + mmproj |
| `Brainstorming/phase-a-vibevoice-nemotron/voxtral/` | ~3.2 GB | Voxtral Mini 3B 2507 + mmproj |
| `Brainstorming/vibevoice-test/model-4bit/` | ~5.7 GB | VibeVoice 4-bit model (safetensors) |

Total: roughly 80–90 GB of model artifacts plus a few GB of supporting test corpora.

## Gitignore

The repo `.gitignore` excludes `*.gguf`, `*.safetensors`, `*.bin`, `*.pt`, and `*.ckpt`. The supporting docs, scripts, JSON manifests, logs, and reports in those subdirectories are tracked.

## Future

A dedicated task (#6 in the May 20, 2026 reorganization task list) will audit which transcription/diarization models the app actually loads and uses, identify which can be deleted, and either move the keepers to `~/Project-Assets/Consensus/` or to an external SSD.
