# VibeVoice ASR Evaluation — Consensus

A controlled benchmark of Microsoft VibeVoice-ASR (MLX 4-bit port) against the existing Consensus engines on the gold-standard `141 W 54th St 3.m4a` (7m 36s, 2 speakers, 1264 ref words).

## Files

| File | Purpose |
|---|---|
| `141_W_54th_3.wav` | 16kHz mono wav of the test audio (decoded from m4a) |
| `score.py` | Compute WER, DER, speaker mapping. Inputs: hypothesis JSON + groundtruth JSON. |
| `extract_consensus_pass.py` | Pull a pass from a Consensus `project.json` into hypothesis format. |
| `qualitative_diff.py` | Print side-by-side ground-truth vs hypothesis turns with similarity markers. |
| `run_vibevoice.py` | Run mlx-audio VibeVoice on a wav file, write hypothesis JSON. |
| `fluidaudio_baseline.json` | Existing pass: FluidAudio Parakeet v3 + SpeakerKit (project 5810D7B5). |
| `whisperkit_large.json` | Existing pass: WhisperKit Large v3 + SpeakerKit (Deep Review B). |
| `deepreview_primary.json` | Existing pass: FluidAudio multi-pass + LLM consensus. |
| `model-4bit/` | MLX-quantized VibeVoice-ASR weights (download in progress). |
| `venv/` | Fresh venv for mlx-audio. |

## Baselines (already scored)

| Engine + Diarizer | WER | DER | Speakers detected | Note |
|---|---:|---:|:---:|---|
| FluidAudio Parakeet v3 + SpeakerKit | **14.72%** | **4.96%** | 2 ✓ | Best balanced; bar to beat |
| WhisperKit Large v3 + SpeakerKit | **10.05%** | 47.20% | 1 ✗ | Best WER, but Deep-Review B drops diarization (UNKNOWN labels) |
| Deep Review primary (multi-pass merge) | 70.65% | 8.66% | 2 ✓ | Merge artifact: 704 insertions from concatenated alts; not a fair single-engine number |

**Reference:** 41 turns, 1264 words, two named speakers (BRANT KUEHN, MARIE LARSEN).

## Qualitative findings — where the existing engines miss

From `qualitative_diff.py fluidaudio_baseline.json … groundtruth.json`:

1. **Proper names** — FluidAudio Parakeet's biggest weakness:
   - "Brant Kuehn" → "Branickin"
   - "Marie" → "Maria"
   - "JAMS" → "jams"
   - "Legalist" → "legalists"
   - "Virginia counsel" → "Virginia Council"

2. **Backchannel speaker turns lost** — short interjections from the second speaker get absorbed into the prior turn:
   - Reference: `BRANT: "Hey Marie, thanks for calling." | MARIE: "Yep." | BRANT: "So, yeah, what's…"`
   - Hypothesis: one merged turn `SPEAKER_1: "Hey Maria, thanks for calling. Yep. So uh yeah, what's…"`

3. **Mild disfluency rendering differences** ("I, I" vs "I I", "what's, what's" vs "what's what's") — minor.

Both error classes are *exactly* what VibeVoice's design targets:
- The `context=` parameter acts as a hotword bias (Microsoft's own example: technical terms, names).
- The joint ASR+diarization model resolves who-said-what in a single pass with full global context.

## Running the VibeVoice test

When the network cooperates, run from this directory:

```bash
# 1. Inference (with hotwords as context)
./venv/bin/python run_vibevoice.py \
    ./model-4bit \
    141_W_54th_3.wav \
    vibevoice_with_context.json \
    "Brant Kuehn, Marie Larsen, Legalist, JAMS, arbitrator, mediation, Virginia counsel"

# 2. Inference (no hotwords, baseline)
./venv/bin/python run_vibevoice.py \
    ./model-4bit \
    141_W_54th_3.wav \
    vibevoice_no_context.json

# 3. Score both
python3 score.py vibevoice_with_context.json \
    "/Users/brantkuehn/Projects/Consensus/TestAudio/141 W 5th St 3 - Manually Revised Transcript.groundtruth.json"

python3 score.py vibevoice_no_context.json \
    "/Users/brantkuehn/Projects/Consensus/TestAudio/141 W 5th St 3 - Manually Revised Transcript.groundtruth.json"

# 4. Qualitative diff
python3 qualitative_diff.py vibevoice_with_context.json \
    "/Users/brantkuehn/Projects/Consensus/TestAudio/141 W 5th St 3 - Manually Revised Transcript.groundtruth.json"
```

## Decision criteria

VibeVoice is worth integrating as a third engine if at least one of these holds on the with-context run:

- **WER < 14.72%** AND **DER < 4.96%** → it's a candidate primary engine on high-RAM Macs.
- **WER similar to FluidAudio (12–18%) but errors land on different turns** → ideal reconciliation partner: cross-engine disagreement gets *more* signal-rich for the consensus pass.
- **Names correctly transcribed via context** → a direct and unique value-add even if global WER is similar.

If WER > 25% or DER > 15%: drop it; it's not worth a third engine slot for this corpus.

## Integration plan if results are positive

Per the architecture survey of `DiarizationService.swift:6` and `DeepReviewEngine.swift:73`, adding an engine is a clean 4-step extension:

1. New case `vibevoice` in `TranscriptionEngineDescriptor`.
2. New `VibeVoiceTranscriptionService.swift` that shells out to a Python sidecar bundled in the app.
3. Switch arm in `TranscriptionPipeline.executePipeline()`.
4. RAM-gate UI: only offer VibeVoice if `ProcessInfo.processInfo.physicalMemory >= 64 * 1024^3`.

Sidecar choice (Python+MLX vs Swift Core ML port) deferred until benchmark confirms the engine earns its keep.
