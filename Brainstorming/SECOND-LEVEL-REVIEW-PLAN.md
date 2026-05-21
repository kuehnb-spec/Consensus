# Second-Level Review for Consensus — Research Plan

**Status**: Drafted April 28, 2026, after the VibeVoice integration ([Phase 1](../TranscriboApp/Transcribo/Services/VibeVoiceTranscriptionService.swift) shipped today). Updated May 1, 2026 after the v6/v8 experiments: the active app architecture now centers on a patch-constrained Deep Review pass instead of the older full-transcript LLM reconciliation path.

**Implementation update (May 1, 2026)**: The app now has `PatchReviewRunner` and `TranscriboApp/Scripts/PatchReviewSidecar/run_patch_review.py`. The Deep pass runs VibeVoice as the canonical transcript, WhisperKit as the second-opinion heatmap, local VibeVoice re-listen for flagged spans, and a protected masked-cloze verifier for exact patches. The previous rewritten-UI full-reconcile runner was moved to `Brainstorming/archive/legacy-deep-review/`.

## Problem statement

VibeVoice 4-bit + hotwords lands at **9.97–10.21% WER, 6.43% DER** on our gold-standard `141 W 54th St 3.m4a` (see [`vibevoice-test/RESULTS.md`](vibevoice-test/RESULTS.md)). On a 1-hour deposition that's still ~1,000 wrong words, plus typical failure modes:

- "[Music]" segments hallucinated where there is no music
- Short backchannels ("Okay", "Mm hmm", "Right") merged into a longer prior turn
- Long monologues occasionally truncated near the end
- Proper names that were *not* in the hotword list still get mangled
- Formatting artifacts ("100%" vs "Hundred percent", "her costs" vs "her cost")

A second-level review should flag the spans worth re-checking and ideally propose a corrected version, **without** asking the user to listen to the whole call. Two candidate approaches motivate this plan:

1. **VibeVoice re-pass** (same model, different parameters, narrower audio windows)
2. **NVIDIA Nemotron 3 Nano Omni** (30B multimodal MoE, audio + text + reasoning in one model — released today)

## Why a multimodal reviewer is structurally different

The current LLM Judgment stage in Consensus (`LLMReconcileService.judgeDisputes`) operates **text-only**: it sees Engine A's text and Engine B's text and picks the more plausible one. When both engines produce plausible-but-wrong text, the LLM has no source of truth to fall back on and tends to defer to fluency.

A multimodal reviewer like Nemotron can:

- Listen to the actual audio at a flagged span
- Read the existing transcript at that span
- Reason about whether they match
- Suggest corrections **grounded in the audio**, not in text-pattern-plausibility

That difference is the experimental hypothesis worth testing.

## Phase 1 — Define the review target

Before shopping for reviewers, decide *what* needs review. Three classes of candidate spans:

**1. Confidence-flagged spans.** VibeVoice doesn't expose token confidences via mlx-audio today, but our service synthesizes a flat 0.95 — useless for this. Two paths to add real signal:
   - Re-run a pass with `temperature=0.3` and compare against the greedy output; spans where the two diverge are uncertain.
   - Add `repetition_penalty` variation; runs that produce different text point to under-determined spans.

**2. Sanity-flagged spans.** A small, fast LLM (e.g. Qwen3 4B already wired in via mlx-swift-lm) reads the transcript and flags spans that don't make sense in context — non-sequiturs, broken syntax, name inconsistencies, "[Music]" hallucinations, etc. This is purely text-based but cheap.

**3. Boundary-flagged spans.** Short backchannels merged into long turns are a known VibeVoice failure mode. A diarization-only re-pass with SpeakerKit (already in the codebase) over the same audio can flag suspicious turn-merges where SpeakerKit thinks there's a speaker change inside a single VibeVoice turn.

Aggregate the three and you have a prioritized review queue. The reviewer then operates on those spans, not the whole transcript.

## Phase 2 — VibeVoice as its own reviewer

Two tracks worth testing:

### Track 2A: narrowed-window re-inference

Take a flagged span (say, 8 seconds of audio at the boundary), extract that audio chunk to a temporary wav, and re-run VibeVoice on **just that window** with sharper context:

- Hotwords pulled from the surrounding 30s of transcript text
- A note in `context` about what the previous and next turns are
- `temperature=0.0`, `max_tokens=2048` (more than enough for an 8s window)

The hypothesis: VibeVoice's full-call inference is forced to balance global context against local fidelity. Stripped to a narrow window, it can spend its full 64K-token budget on one short span and may hear differently.

**Cost**: ~5–10 seconds per flagged span. For a typical project with ~30 flagged spans, that's 3–5 minutes of GPU time on the M2 Max.

**Risk**: Same model = same systematic biases. If VibeVoice mishears "Brant Kuehn" globally, narrowing the window won't help unless the hotwords list does. This is a way to fix *local* errors that came from global pressure, not *systematic* model biases.

### Track 2B: ensemble decoding

Run the same audio through VibeVoice **twice** with different sampling parameters:
- Run 1: `temperature=0.0` (greedy)
- Run 2: `temperature=0.3, top_p=0.95` (sampled)

Spans where the two runs agree are "high confidence" and skip review. Spans where they disagree are flagged for review. The disagreement rate gives a calibrated uncertainty signal that mlx-audio doesn't expose directly.

**Cost**: doubles inference time. For a 7m call, that's ~3.5 minutes total instead of 1.8.

**Hypothesis to test**: whether disagreement points at *the same* segments humans would flag, vs. at random low-importance variations like punctuation or filler placement.

## Phase 3 — Nemotron 3 Nano Omni as multimodal reviewer

Nemotron's `30B-AD3B` MoE is available on HuggingFace and via NVIDIA NIM as of April 28. Three test approaches:

### Track 3A: span-level audio + text grounding

Send Nemotron each flagged span as `{audio_clip, transcript_text, context_window}` and ask:

> "Here is an 8-second audio clip and what was transcribed for it: '<text>'. Surrounding context is: '<before> ... <after>'. Does the transcript match what is said in the audio? If not, propose the corrected text. Reply in JSON: `{verdict: 'match'|'fix', corrected: string, confidence: 0..1, reasoning: string}`."

This is the highest-value test because it exercises Nemotron's headline capability — listening + reading + reasoning in a single pass.

**Cost**: per-span Nemotron inference. NIM API or local 30B is non-trivial — but only on flagged spans (typical 30 spans × ~2s each = ~60s of audio to process).

**Risk**: 30B local inference on M2 Max may be tight at full precision; quantized GGUF variants exist (`unsloth/NVIDIA-Nemotron-3-Nano-Omni-30B-A3B-Reasoning-GGUF`). For a first test, hosted NIM is cleaner.

### Track 3B: full-transcript cross-check (text only)

Send Nemotron just the transcript text (no audio) and ask it to flag implausible spans based on linguistic reasoning alone. This is a baseline — it tests whether the multimodal grounding actually adds anything over a strong reasoning model running on text.

If 3A and 3B catch the same errors, the multimodal capability isn't pulling its weight here and we'd skip it. If 3A catches things 3B doesn't, the audio grounding is the real value.

### Track 3C: full-audio scan with reasoning summary

Send Nemotron the **full audio** plus the **full transcript** and ask it to produce a numbered list of likely errors with timestamp + suggested fix. This is the "agentic" use case Nemotron is marketed for. It tests whether long-context reasoning can find errors we didn't pre-flag.

**Cost**: highest. A 7m audio + transcript may push context-window limits depending on token economy of audio-as-input.

## Phase 4 — Benchmark setup

Take the existing VibeVoice + hotwords transcript on the gold-standard audio. We have ground truth at [`TestAudio/141 W 5th St 3 - Manually Revised Transcript.groundtruth.json`](../TestAudio/141 W 5th St 3 - Manually Revised Transcript.groundtruth.json). Compute, for each approach:

| Metric | What it measures |
|---|---|
| **Recall on real errors** | Of the actual errors VibeVoice made, how many did the reviewer flag? |
| **Precision on flags** | Of the flags raised, how many were real errors (vs false positives where VibeVoice was actually correct)? |
| **WER post-correction** | If we accept the reviewer's corrections, what's the new WER? Lower is better; baseline is 10.21%. |
| **Wall-clock cost** | Total seconds added to the workflow per minute of audio. |
| **Names recovered** | Of the proper-name errors specifically, how many did each approach catch and correct? |

Use the existing `score.py` rig at [`Brainstorming/vibevoice-test/score.py`](vibevoice-test/score.py) for WER. Add a small "name accuracy" function that checks specific proper nouns.

## Phase 5 — Decision criteria

Integrate a second-level reviewer if **all three** hold for at least one approach:

1. **WER post-correction < 7%** on the gold-standard audio (a 30%+ relative reduction from 10.21%).
2. **Precision > 70%** — fewer than 30% of flagged spans turn out to be false positives. The user has to trust the flag list, not waste time double-checking everything.
3. **Wall-clock < 30s per minute of audio** — on top of VibeVoice's 24s per minute. Total budget is "still faster than a human listening through."

If multiple approaches qualify, pick by:
- Cheaper (in user dollars and watt-hours) over more elaborate
- Local over hosted (Consensus's privacy-first positioning)
- Self-contained (one model) over a chain (avoid more moving parts)

## Tactical sequencing

1. **Build the flag aggregator first** (Phase 1). Without a flag pipeline, all three reviewer approaches have nothing to operate on. This is also a useful product feature in its own right — show the user "here are the 30 spans you should double-check" even without auto-correction.
2. **Run Track 3A on the gold-standard audio** via NIM hosted API (fastest path to data). If the multimodal grounding pays off, work on a local quantized integration second.
3. **Run Track 2A as a baseline** — narrow-window VibeVoice re-inference is essentially free since the model is already loaded. If it gets within striking distance of Nemotron, the simpler architecture wins.
4. **Run Track 3B as a sanity check** — text-only reasoning on the same flag set. Confirms whether audio grounding is doing real work.
5. **Skip Track 3C until later.** Full-audio scan is high-cost and only worth running if the per-span approaches don't catch enough.

## Open questions

- Does mlx-audio's VibeVoice expose any per-token confidence we missed in the first integration? Worth re-reading the `STTOutput` source to see if there's a way to get real signals instead of synthesized 0.95s.
- Is the Nemotron NIM API rate-limited or paid? The blog says "available on OpenRouter" too — that may be the cheaper integration path for testing.
- For private legal use, hosting through NIM/OpenRouter trades the privacy-first positioning. A local quantized GGUF would preserve it but at much higher integration cost. The benchmark should determine whether the quality gap justifies that cost.
- Should the flag pipeline live in the existing `LLMReconcileService` (extend `findDisputes` to operate on a single transcript instead of two) or as a new `ReviewFlagService`? Probably the latter — single-transcript flagging has different semantics than cross-engine disputes.

## Sources

- [NVIDIA Launches Nemotron 3 Nano Omni](https://blogs.nvidia.com/blog/nemotron-3-nano-omni-multimodal-ai-agents/)
- [Building NVIDIA Nemotron 3 Agents — Reasoning, Multimodal RAG, Voice, Safety](https://developer.nvidia.com/blog/building-nvidia-nemotron-3-agents-for-reasoning-multimodal-rag-voice-and-safety/)
- [Nemotron 3 Nano Omni — long-context multimodal intelligence (HF blog)](https://huggingface.co/blog/nvidia/nemotron-3-nano-omni-multimodal-intelligence)
- [unsloth/NVIDIA-Nemotron-3-Nano-Omni-30B-A3B-Reasoning-GGUF](https://huggingface.co/unsloth/NVIDIA-Nemotron-3-Nano-Omni-30B-A3B-Reasoning-GGUF)
- [SiliconANGLE: Nvidia introduces Nemotron 3 Nano Omni (April 28, 2026)](https://siliconangle.com/2026/04/28/nvidia-introduces-nemotron-3-nano-omni-vision-speech-powerful-agentic-ai-use/)

---

## Addendum (April 29, 2026) — Three-stage standard-of-proof architecture

**User proposal**: revamp Deep Review into a three-stage pipeline grounded in a "presumed correct" framing for VibeVoice's output.

### The proposed pipeline

1. **VibeVoice** — full transcript + diarization. Already shipped as the Standard pass.
2. **IBM Granite Speech 4.1** — independent second transcription. Apache 2.0, 2B parameters, 5.33% WER on the OpenASR Leaderboard. Variants: `2B`, `2B Plus` (richer features), `2B NAR` (non-autoregressive, throughput-optimized). Multilingual. No diarization. Apple Silicon support unconfirmed but the model size is small enough that llama.cpp on Apple Silicon is a near-certain path even if no MLX port exists.
3. **NVIDIA Nemotron 3 Nano Omni** — 30B MoE with 3B active parameters. NVIDIA Open Model License. Text + image + video + **audio**. Audio uses NVIDIA Parakeet as the encoder (same family as FluidAudio). GGUF available via `nvidia/Nemotron-3-Nano-Omni-30B-A3B-Reasoning-BF16` and Unsloth quantized checkpoints. Runs through llama.cpp / Ollama / LM Studio on Apple Silicon.

### Why standard-of-proof matters

The proposal: **Nemotron does not change anything unless it concludes (with calibrated confidence ≥ T) that VibeVoice is wrong.** Granite acts as evidence; VibeVoice is presumed correct. This directly counters the Deep Review failure mode where text-only LLM judges over-correct toward fluency at the cost of fidelity.

### What's structurally novel here

- **Audio grounding** (Nemotron listening to disputed spans) breaks the tied-opinion problem that text-only judges can't solve. This is the single biggest accuracy lever.
- **Standard-of-proof** is the right *intent* — a high bar prevents over-correction. But the *implementation* is non-trivial (see calibration below).
- **Triangulation** (VibeVoice + Granite + Nemotron audio check) is a clean ensemble. Three independent observers fail differently.

### Concerns to design around before committing

**1. The confidence threshold needs calibration, not intuition.**

Self-reported LLM confidence is famously poorly calibrated. Three honest options for actually obtaining a probability:

- **(a) Logprob over the decision token.** Force structured output `{"decision": "keep" | "replace", ...}` and use the model's logprob on the literal token "keep" / "replace" as the probability. Calibrated by model training, no extra cost.
- **(b) Sample-and-vote.** Run Nemotron 5 times at temperature 0.3 over the same disputed span; report majority + agreement rate as confidence. ~5× cost per disputed span but more robust against single-sample noise.
- **(c) Calibration mapping.** Build a labeled set of (disputed-span, ground-truth) pairs from our gold-standard audio + ground truth. Plot Nemotron's self-reported confidence vs actual correctness. Pick the threshold where precision tops out while recall is acceptable.

Picking "65%" as a static threshold ships a knob without scale. **Calibration is its own deliverable.**

**2. Granite's marginal value over a 2-stage version is real but smaller than it looks.**

Nemotron has Parakeet baked in as its audio encoder — it can already do its own ASR comparison against VibeVoice without Granite. Granite's actual contribution is operational: it acts as a *pre-filter*, surfacing only the spans where two text-only ASRs disagree. Nemotron then listens to those spans only, not the whole audio. That efficiency win is real (a full-audio multimodal pass is much more expensive than a per-span one), but Granite is also another model to orphan-prevent, RAM-budget, and bug-fix.

Sequence the work: **build the 2-stage version (VibeVoice + Nemotron multimodal review) first; add Granite as the pre-filter only if Phase A doesn't catch enough errors.**

**3. Memory budget on real hardware.**

| Component | Quantized size | Peak runtime |
|---|---:|---:|
| VibeVoice 4-bit MLX | 5 GB on disk | ~6 GB working |
| Granite Speech 4.1 2B Q4 | ~1.5 GB on disk | ~2 GB working |
| Nemotron 3 Nano Omni 30B A3B Q4 GGUF | ~15 GB on disk | ~10–15 GB working (only active experts in RAM at any moment) |
| **Total worst-case** | **~22 GB** | **~22 GB** |

Fine on 64+ GB Macs (the M2 Max test machine). Infeasible on 16 GB Macs without aggressive sequential loading. The Deep tier becomes a **pro-tier feature gated on ≥ 32 GB RAM**.

**4. Privacy positioning.**

NIM / OpenRouter would simplify Nemotron integration but break Consensus's "everything stays on this device" pitch. Local GGUF via llama.cpp is the right path. Higher integration cost, higher first-run download (15 GB), but the value proposition stays intact.

**5. Operational complexity = bug surface.**

The April 28 thermal-shutdown chain showed how subprocess management around a single sidecar can take down the laptop. Three sidecars triples that surface. The orphan-prevention, power-assertion, memory-preflight, and termination paths we hardened for VibeVoice all need to be replicated for each new sidecar — preferably extracted into a shared helper rather than copy-pasted three times.

### Recommended sequencing

**Phase A — Test rig, 2-stage**: VibeVoice + Nemotron multimodal review on `141 W 54th St 3.m4a` (gold standard). Measure: WER post-correction, precision on flags, time per minute of audio, peak RAM. Compare against VibeVoice-alone (10.21% WER baseline). **Decision rule**: if Nemotron-listen-and-decide doesn't beat VibeVoice-alone by ≥3 WER points with calibrated precision ≥70% and time-cost ≤ 30 s/min audio, the architecture isn't earning its keep.

**Phase B — Test rig, 3-stage**: Add Granite as the pre-filter. Re-measure on the same audio. The marginal improvement here tells us whether the third stage justifies the operational cost.

**Phase C — Calibration**: Build the labeled disputed-span dataset. Plot Nemotron confidence vs correctness. Pick the threshold empirically.

**Phase D — Ship**: Whichever variant wins by enough margin becomes the new Deep. The existing Whisper + LLM-text-judge path either retires or becomes "Quick Deep" for users without 32+ GB RAM.

### Open implementation questions

- Where does the disputed-span pre-filter live? The May 1 app integration put it inside the new `PatchReviewRunner` / `PatchReviewSidecar` boundary for now. If it grows beyond the second-ASR heatmap, split it into a shared `ReviewFlagService`.
- Granite Speech 4.1 — is there an MLX port yet, or do we need to ship a llama.cpp wrapper as the second sidecar pattern? Worth checking the mlx-community HF org before assuming.
- Nemotron's audio input format — what does it actually accept? Raw PCM? mp3? Does it expect features from the Parakeet encoder (precomputed) or raw audio? Affects how we hand it span-clipped audio.
- Calibration dataset — we have one ground-truth pair (`141 W 54th St 3.m4a` + revised transcript). Need at least 2-3 more for a defensible calibration. Could synthesize disputed spans by injecting controlled errors into the ground truth and seeing if Nemotron flags them correctly.

### Sources for the addendum

- [IBM Research: Granite 4.1 AI Foundation Models](https://research.ibm.com/blog/granite-4-1-ai-foundation-models)
- [NVIDIA Developer Blog: Nemotron 3 Nano Omni multimodal agent reasoning](https://developer.nvidia.com/blog/nvidia-nemotron-3-nano-omni-powers-multimodal-agent-reasoning-in-a-single-efficient-open-model/)
