# VibeVoice ASR Benchmark — Results

Test audio: `141 W 54th St 3.m4a` (7m 36s, 2 speakers, 41 turns, 1264 ref words)
Ground truth: manually revised transcript with timestamped turns
Hardware: M2 Max, 96 GB RAM, macOS 26.4.1
Model: `mlx-community/VibeVoice-ASR-4bit` (5.3 GB on disk)

## Headline numbers

| Engine | WER | DER | Speakers | Names correct? | Wall clock | Peak RAM |
|---|---:|---:|:---:|:---:|---:|---:|
| FluidAudio Parakeet v3 + SpeakerKit | 14.72% | **4.96%** | 2 ✓ | ✗ | — | — |
| WhisperKit Large v3 + SpeakerKit (Deep Review B) | 10.05% | 47.20% | 1 ✗ (UNKNOWN) | — | — | — |
| **VibeVoice 4-bit, no hotwords** | **9.97%** | 7.00% | 2 ✓ | ✗ | 1.93 min | 6 GB |
| **VibeVoice 4-bit + hotwords** | 10.21% | 6.43% | 2 ✓ | **✓** | 1.84 min | 6 GB |

(Deep Review primary multi-pass merge omitted — 70.6% WER from merge artifacts, not a fair single-engine number.)

## What's surprising

1. **VibeVoice's base accuracy already matches WhisperKit Large v3.** No hotwords needed for that.
2. **The 4-bit MLX quant is shockingly memory-light: 6 GB peak.** Willison saw 61 GB peak on the bf16 version; 4-bit is roughly a 10× reduction. Any 16 GB Mac could run this. That changes the deployment story Microsoft's own docs imply.
3. **Hotwords cost 0.24% WER but fix the most important error.** Without context, "Brant Kuehn" came out as "Brian Keane" (a different mishear from FluidAudio's "Branickin"). With context, the personal name is correct. For legal transcripts, this trade is obviously worth it.
4. **VibeVoice already gets domain terms right without help.** "JAMS", "Legalist", "Virginia counsel" all correct in the no-context run. Only the proper personal name needed hotword guidance.
5. **Diarization quality is real but not better than SpeakerKit.** 6.43% DER is solid — much better than WhisperKit's 47% — but slightly worse than FluidAudio + SpeakerKit's 4.96%. SpeakerKit (pyannote v4) still has the diarization edge.

## Where VibeVoice still misses

Same error class on both runs (with/without hotwords):
- A "[Music]" segment hallucinated at the start (audio has no music).
- Short backchannels ("Okay", "Mm hmm", "Right") sometimes merged into the prior speaker's long turn — same failure mode as FluidAudio, just on different turns.
- Light formatting normalization ("Hundred percent" → "100%", "her cost" → "her costs") — counted as substitutions but not really errors.
- One long monologue turn at the end was truncated.

## What this means for Consensus

**VibeVoice earns its keep as a third engine.** Three reasons:

1. **WER parity at WhisperKit Large** with working diarization built in — that's a strict upgrade over WhisperKit-as-Engine-B (which currently gets diarization wrapped after the fact and ends up tagged UNKNOWN in Deep Review).
2. **Personal-name fixing via hotwords** is unique. None of the existing engines have a comparable mechanism. For legal calls the speaker names are usually known in advance — feeding them to VibeVoice should make consensus passes far cleaner on names.
3. **Different error fingerprint than FluidAudio.** FluidAudio gets names wrong everywhere; VibeVoice gets them right via hotwords but occasionally over-merges short turns. Reconciliation gets a richer set of disagreements that *aren't all the same kind of error*.

**RAM gating is no longer the constraint we thought.** 6 GB peak means VibeVoice runs comfortably on 16 GB Macs. The original "high-end Macs only" plan from the research note can be relaxed.

## Recommended integration

### Phase 1 — Wire VibeVoice as an opt-in third ASR engine
1. Add `vibevoice` case to `TranscriptionEngineDescriptor` (DeepReviewEngine.swift:73-94).
2. Create `VibeVoiceTranscriptionService.swift` that shells out to a bundled Python+MLX sidecar.
   - Sidecar binary: PyInstaller-built single-file executable wrapping `run_vibevoice.py`.
   - Or: Core ML port if someone publishes one (multi-week project, not worth the cost yet).
3. Switch arm in `TranscriptionPipeline.executePipeline()` (lines 159-179).
4. Add UI toggle in Transcribe setup screen with a "premium" or "AI-enhanced" label.
5. Pass the project's known speaker names from `speakerMapping` as `context=` automatically — that's the killer feature.
6. RAM gate at 16 GB, not 64 GB.

### Phase 2 — Use VibeVoice in Deep Review
Replace WhisperKit Large v3 as the Deep Review B engine (the comparison pass). Reasons:
- Same WER quality.
- Diarization actually works, so engine-B passes carry their own speaker labels — no more UNKNOWN handling downstream.
- The hotword pathway gives the LLM Judgment stage cleaner disagreements to reconcile.

### Phase 3 — Harvest hotwords from project metadata
When the user names speakers in the Speaker Naming view, those names should automatically populate VibeVoice's `context=` on the next pass. This is a small UX win that compounds.

## Run-it-yourself

```bash
cd /Users/brantkuehn/Projects/Consensus/Brainstorming/vibevoice-test

# With hotwords (recommended)
./venv/bin/python run_vibevoice.py ./model-4bit \
    141_W_54th_3.wav \
    vibevoice_with_context.json \
    "Brant Kuehn, Marie Larsen, Legalist, JAMS, arbitrator, mediation, Virginia counsel, Anthony"

# Without hotwords (baseline)
./venv/bin/python run_vibevoice.py ./model-4bit \
    141_W_54th_3.wav \
    vibevoice_no_context.json

# Score
python3 score.py vibevoice_with_context.json \
    "/Users/brantkuehn/Projects/Consensus/TestAudio/141 W 5th St 3 - Manually Revised Transcript.groundtruth.json"

# Side-by-side qualitative diff
python3 qualitative_diff.py vibevoice_with_context.json \
    "/Users/brantkuehn/Projects/Consensus/TestAudio/141 W 5th St 3 - Manually Revised Transcript.groundtruth.json"
```
