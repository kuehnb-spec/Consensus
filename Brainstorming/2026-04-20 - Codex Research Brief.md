# Codex Research Brief — Diarization Quality for Phone Calls & Meetings

**Status:** Completed on April 20, 2026. Research response saved to `Brainstorming/2026-04-20 - Codex Research Response.md`.

**Context for the researcher:** I'm building a privacy-first macOS transcription app called **Consensus**. Fully on-device: WhisperKit + FluidAudio Parakeet for ASR, Argmax SpeakerKit (pyannote v4 on CoreML) + FluidAudio (pyannote v1) for diarization, Qwen3-ForcedAligner for word timings, local MLX-quantized Qwen 3 8B for LLM tasks. Target use cases: phone calls (~2 speakers) and small meetings (~3–6 speakers). Apple Silicon only. No cloud APIs. Apache-2.0 / MIT / similar licenses required.

I've hit a ceiling where multiple acoustic diarization passes + heuristic fusion + LLM boundary confirmation still miss speaker changes, especially between similar-voiced speakers in phone-band audio. A companion doc (`2026-04-20 - Fresh Attack Plan.md`) lays out my plan to add orthogonal signal channels (prosodic F0, conversational-logic, LLM global arbiter, self-enrollment, voiceprint library). I want you to validate, refine, and extend that plan with current literature and concrete implementation guidance.

Prior research memos (read these for context, then exceed them):
- `Brainstorming/2026-04-16 - Codex Brainstorming.md`
- `Brainstorming/2026-04-16 - Performance Memo - Transcription and Diarization.md`
- `Brainstorming/WORD-TIMELINE-REBUILD-PLAN.md`
- `DIARIZATION_IMPROVEMENT_GUIDE.md`

**Output format.** For each section below, give me: (a) a short factual answer, (b) primary source links (arXiv, GitHub, Hugging Face, vendor docs — not blog posts unless they are from the model authors), (c) Apple Silicon viability (MLX / CoreML / plain PyTorch-MPS, any known gotchas), (d) license.

---

## Research questions

### Q1. Telephone-domain diarization SOTA

Most diarization models are benchmarked on broadband meeting data (AMI, VoxConverse, DIHARD). Phone audio is very different: bandlimited (300–3400 Hz typically), codec-compressed (G.711, G.729, Opus narrowband), often mixed to mono after full-duplex compression.

- **What models have been trained or fine-tuned specifically on telephone audio?** (NIST SRE / CallHome / Switchboard / Fisher corpora.)
- **Is there a current (2024–2026) pyannote, Sortformer, EEND, or DiariZen checkpoint with telephone training data?**
- **Does FluidAudio's diarization expose a telephone-tuned backend?** (The performance memo mentions "three-backend diarization" — which ones?)
- **If we upsample phone audio to 16 kHz with a bandwidth-extension model before diarization, does it close the domain gap?** Any 2024–2026 work on bandwidth extension as a pre-diarization step?
- **Is NeMo's `diar_msdd_telephonic` checkpoint portable to CoreML / MLX?** Any existing Apple-Silicon port?

### Q2. LLM-as-arbiter for diarization

I want the local LLM to look at the full transcript + provisional speaker labels + timestamps + confidences and propose attribution corrections based on conversational logic.

- **Is there published work on LLM-based speaker attribution correction for diarization output?** (Not LLM-based ASR correction — specifically diarization.)
- **What are the best prompt patterns for this?** Concrete examples from published systems or product docs (DiarizationLM, Rev.ai Universal-1, AssemblyAI, etc.).
- **What structured output format works best for large transcripts** — JSON edit lists, XML-style annotations, diff format? Any evaluation of which is most reliable on 8B-class local models?
- **How should I handle the context-window limit** for very long transcripts (1h+)? Sliding window with overlap? Map-reduce? Re-ranking?
- **What are the known failure modes?** When does LLM-based attribution correction make things worse?

### Q3. Prosodic and lexical signal channels

My plan adds (a) F0/pitch tracking as a parallel boundary detector and (b) a conversational-logic rule set (question→answer, back-channel detection, intro pattern matching).

- **Current literature on fusing prosodic features with acoustic diarization** — what fusion strategies work? Late fusion? Multi-stream models? Graph-based fusion?
- **Best Swift / Accelerate-compatible pitch tracker?** We need something like pYIN or CREPE that runs fast on Apple Silicon. Any existing Swift packages?
- **Is there a speech community dataset of back-channel / short-turn examples** that could be used to tune a back-channel detector?
- **Any work on using turn-taking models (silence patterns, speech rate, pause lengths) as a smoothing prior over raw diarization output?**
- **What's the latest on end-of-turn detection models?** (E.g., Smart Turn, 2024 work on conversational AI endpointing — do any have open weights or Apple-Silicon ports?)

### Q4. Speaker enrollment / verification on short segments

Anchor Speaker + voiceprint library approach: the user enrolls "my voice" once, and we auto-identify frequent callers from a library of saved embeddings.

- **Best open-license speaker embedding model for phone-band audio** on Apple Silicon? (WeSpeaker ResNet34 vs. TitaNet vs. ECAPA-TDNN vs. Resemblyzer — which performs best on telephone data, and which is portable to CoreML / MLX?)
- **Minimum enrollment duration for reliable ID** on phone audio? Literature typically says 10–30 seconds for clean audio — does telephone audio need more?
- **How to handle short segments (<1s)** — are there models that do short-utterance verification well? Typical embedding models need ≥1.5s windows.
- **Any research on "domain-adapted enrollment"** — using a reference clip from a different call (different codec, different line quality) against a new call? This is the real-world case: my library voiceprints may have been captured under different conditions than the new call.
- **Formal name for the "Anchor Speaker" pattern** in the literature, and known failure modes?

### Q5. Overlap handling

We mostly don't care about overlap (phone calls rarely have true concurrent speech after codec compression), but meetings do.

- **What's the current SOTA on overlap-aware diarization** that runs on Apple Silicon? (MossFormer2, ToTaToNet, pyannote overlap detection v4.)
- **Is there any work on using the overlap detector output as a flag rather than trying to separate** — i.e., just tell the user "there's overlap here, consider the attribution uncertain"?
- **Joint ASR + diarization (DiCoW v3 / Sortformer+Canary serialized-tag) ports** — any real progress on Apple Silicon since April 2026?

### Q6. Evaluation infrastructure

The performance memo notes we don't yet have a proper tcpWER/DER benchmark because we haven't parsed the Clayton Everett ground-truth transcript into RTTM.

- **Best existing open-source tooling for tcpWER / cpWER / DER on timestamped transcripts?** (MeetEval, dscore, md-eval, Kaldi's compute-der.)
- **Swift-native tools** or ones easily wrapped from Swift?
- **Minimum test corpus size** to be statistically meaningful for telephone audio? We have ~6 test files currently.

### Q7. Product-side intelligence

Less academic, more industry-practice:

- **How do commercial products handle speaker identification over time?** (Otter.ai, Fireflies, Zoom AI, Rev.ai — do any have a public-facing "speaker library" concept, and what does that UX look like?)
- **What's the UX pattern for "voice review"** — asking the user "who is this?" on short clips? Any products doing this well?
- **Any legal/compliance concerns with persistent voiceprint storage** on-device? (GDPR Article 9 treats biometrics sensitively; macOS keychain storage appropriate?)

---

## Deliverables

Please produce a single markdown document saved as `Brainstorming/2026-04-20 - Codex Research Response.md` with:

1. **TL;DR** (3–5 bullets: what's the single most important finding for each research thread).
2. **Answers to each question above**, structured as described (short answer + sources + Apple Silicon viability + license).
3. **A revised and ranked list of concrete implementation recommendations** — overriding or extending my Phase 1 / Phase 2 / Phase 3 plan in `2026-04-20 - Fresh Attack Plan.md` where the research warrants it.
4. **Any specific model checkpoints, weights, or Swift packages I should try**, with download links and a one-paragraph integration sketch each.
5. **Sharp "why this won't work" analysis** on my LLM-arbiter and Anchor Speaker proposals if the literature suggests known problems.

If any question is unanswerable from public sources, say so explicitly. I'd rather have honest gaps than plausible-sounding guesses.
