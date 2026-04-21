# Codex Research Response — Diarization Quality for Phone Calls & Meetings

**Prepared:** April 20, 2026  
**Project:** Consensus  
**Companion files:** `2026-04-20 - Codex Research Brief.md`, `2026-04-20 - Fresh Attack Plan.md`, `2026-04-16 - Codex Brainstorming.md`, `2026-04-16 - Performance Memo - Transcription and Diarization.md`, `WORD-TIMELINE-REBUILD-PLAN.md`

## TL;DR

- **Telephone-domain diarization is still a domain gap.** The strongest explicit telephony checkpoints I found were NVIDIA NeMo's `diar_msdd_telephonic` and a public **CALLHOME LS-EEND ONNX** export; I did **not** find an official telephone-specific pyannote, Sortformer, or DiariZen release with an Apple-native port. For Consensus, the most realistic move is a **telephone-specialist sidecar**, not replacing SpeakerKit outright.
- **LLM diarization correction is now real, but text-only correction is brittle.** `DiarizationLM`, the contextual beam-search paper, the 2024 generalization paper, and Amazon's `SEAL` all support using lexical context to fix speaker labels. The consistent warning is that **ASR errors, long-context truncation, and loss of acoustic evidence** can make an LLM over-correct or hallucinate speaker flips.
- **Prosodic and turn-taking cues are worth adding, but as evidence, not authority.** Current work on turn-taking and backchannel prediction supports combining acoustic timing/prosodic cues with language-model context. For Consensus, F0, pause structure, and short-turn/backchannel priors belong in a **late-fusion boundary graph or constrained edit verifier**, not as a standalone relabeler.
- **Speaker enrollment is best framed as speaker identification / enrollment / registration, not as a diarization replacement.** A voiceprint library will help identity continuity and disputed short spans, but the public literature and pyannote docs both imply the same thing: it improves **who this is**, not necessarily **where the turns are**.
- **Apple Silicon reality matters more than paper SOTA.** The best practical open stack today is still SpeakerKit plus speech-swift / FluidAudio components, plus ONNX/CoreML/MLX conversions where needed. `diar_msdd_telephonic` looks useful on paper, but I found **no official CoreML or MLX port**. By contrast, WeSpeaker, Sortformer, LS-EEND ONNX, Qwen3-ForcedAligner, and FluidAudio's diarizers are all meaningfully closer to a working Consensus integration path.

---

## Framing Notes

- I treated this as a **codebase-grounded research pass**, not a generic diarization survey.
- I prioritized **primary sources**: papers, model cards, official docs, and upstream repos.
- Where I recommend an implementation detail without a paper proving it, I label it as an **inference**.
- Where public sources were thin, I say so explicitly instead of guessing.

---

## Q1. Telephone-domain diarization SOTA

### Short answer

For telephone-style audio, the clearest public telephone-specialized options I found were:

1. **NeMo `diar_msdd_telephonic`** for cascaded telephonic diarization.
2. **CALLHOME LS-EEND variants** for long-form / streaming end-to-end diarization.
3. **Sortformer v2.1** as a strong modern diarizer with very good CALLHOME results, but not explicitly documented as telephone-trained.

I did **not** find an official telephone-tuned pyannote Community-1 or DiariZen release, and I did **not** find a public Apple-native port of `diar_msdd_telephonic`.

### Findings by sub-question

| Sub-question | Short factual answer | Apple Silicon viability | License | Primary sources |
|---|---|---|---|---|
| What models have been trained or fine-tuned specifically on telephone audio? | The most explicit current answer is **NeMo `diar_msdd_telephonic`**, which NeMo documents as the telephonic-domain MSDD model and pairs with `diar_infer_telephonic.yaml`. The strongest public end-to-end telephony artifact I found is a **CALLHOME LS-EEND ONNX export**. I also found newer CALLHOME-fine-tuned community pyannote models on Hugging Face, but they are community fine-tunes rather than official pyannote releases. | `diar_msdd_telephonic` is PyTorch/NeMo-first; no official MLX/CoreML port found. LS-EEND ONNX is more plausible on Apple because it already exists as ONNX, but it is still a custom runtime job. | NeMo code/docs are Apache-2.0; the exact model terms for NGC-distributed checkpoints need to be checked at download time. LS-EEND ONNX repo is MIT. Community CALLHOME pyannote fine-tunes vary by card. | [NeMo configs](https://docs.nvidia.com/nemo-framework/user-guide/latest/nemotoolkit/asr/speaker_diarization/configs.html), [NeMo results/checkpoints](https://docs.nvidia.com/nemo/speech/nightly/asr/speaker_diarization/results.html), [LS-EEND ONNX](https://huggingface.co/GradientDescent2718/LS-EEND-ONNX), [CALLHOME dataset card](https://huggingface.co/datasets/talkbank/callhome) |
| Is there a current pyannote, Sortformer, EEND, or DiariZen checkpoint with telephone training data? | **EEND:** yes, via the public **CALLHOME LS-EEND ONNX** variant. **Sortformer:** public model cards report strong CALLHOME results, but I did not find an explicitly telephone-trained Sortformer checkpoint distinct from the general `diar_streaming_sortformer_4spk-v2.1`. **pyannote:** I found community CALLHOME fine-tunes, but not an official pyannote telephone release. **DiariZen:** I did not find a public telephone-tuned checkpoint. | LS-EEND ONNX is the easiest Apple path among the telephony-specialized public artifacts. Sortformer has better Apple-native story via FluidAudio, but not telephone specialization. | LS-EEND ONNX MIT; Sortformer model card uses NVIDIA Open Model License; pyannote Community-1 CC-BY-4.0; DiariZen weights are not a clean commercial path. | [LS-EEND ONNX](https://huggingface.co/GradientDescent2718/LS-EEND-ONNX), [Sortformer v2.1 card](https://huggingface.co/nvidia/diar_streaming_sortformer_4spk-v2.1), [pyannote Community-1](https://huggingface.co/pyannote/speaker-diarization-community-1), [DiariZen repo](https://github.com/BUTSpeechFIT/DiariZen) |
| Does FluidAudio expose a telephone-tuned backend? | **No public docs I found say yes.** FluidAudio's public README describes three diarization families: **LS-EEND**, **Sortformer**, and a **pyannote/WeSpeaker pipeline**. None is documented as telephone-specialized. | Very good Apple story overall, but not a documented telephony specialist. | FluidAudio code Apache-2.0; underlying model terms vary by backend. | [FluidAudio README](https://github.com/FluidInference/FluidAudio/blob/main/README.md) |
| If we use bandwidth extension before diarization, does it close the gap? | **No public diarization-specific evidence convinced me this is a reliable first-line fix.** I found good bandwidth-extension work and a telephony speaker-verification paper showing BWE can reduce narrowband/wideband mismatch, but not strong 2024-2026 evidence that BWE as a pre-diarization step reliably closes telephone diarization gaps. I would treat BWE as an experiment, not a Phase 1 dependency. | Weak Apple path today. NVIDIA `RE-USE` is GPU/Linux/noncommercial. Generic BWE papers are portable in theory, but I did not find an Apple-ready open implementation tied to diarization. | `RE-USE` is noncommercial; AP-BWE paper/code is open research but not an Apple-native product path. | [RE-USE model card](https://huggingface.co/nvidia/RE-USE), [AP-BWE paper](https://arxiv.org/abs/2401.06387), [Telephony super-resolution for speaker verification](https://arxiv.org/abs/2209.01702) |
| Is NeMo `diar_msdd_telephonic` portable to CoreML / MLX? | **No official Apple-Silicon port surfaced in public sources.** It is clearly usable in NeMo/PyTorch, but I found no maintained CoreML or MLX conversion for it. | Possible in principle via ONNX/CoreML conversion, but this is a custom research port, not a ready-made dependency. | Model distribution terms should be checked at NGC download time; NeMo code/docs are Apache-2.0. | [NeMo configs](https://docs.nvidia.com/nemo-framework/user-guide/latest/nemotoolkit/asr/speaker_diarization/configs.html), [NeMo results/checkpoints](https://docs.nvidia.com/nemo/speech/nightly/asr/speaker_diarization/results.html) |

### Practical interpretation for Consensus

- **SpeakerKit / pyannote Community-1 remains a good general baseline**, but it is not a telephony specialist.
- The most realistic telephone-specific additions are:
  1. **LS-EEND CALLHOME ONNX** as a sidecar telephony voter.
  2. **NeMo `diar_msdd_telephonic`** as a research-sidecar only if you are willing to own a port or a Python helper.
- I would **not** burn a phase on bandwidth extension before testing a telephony-specialist diarizer and your word-timeline rebuild.

---

## Q2. LLM-as-arbiter for diarization

### Short answer

Yes: there is now solid published support for **LLM-based diarization correction**. The strongest public line runs through:

- **DiarizationLM** (LLM post-processing on Fisher and CallHome),
- **Contextual beam search with LLM lexical cues**,
- **LLM-based speaker diarization correction: A generalizable approach**, and
- **SEAL**, which explicitly argues that **text-only correction misses acoustic evidence** and adds acoustic conditioning plus constrained decoding.

### Findings by sub-question

| Sub-question | Short factual answer | Apple Silicon viability | License | Primary sources |
|---|---|---|---|---|
| Is there published work on LLM-based speaker attribution correction? | **Yes.** `DiarizationLM` reports large relative WDER reductions on Fisher and CallHome using LLM post-processing over ASR + diarization output. The contextual beam-search paper shows LLM lexical cues improve SA-WER. The 2024 generalization paper confirms LLM correction helps, but ASR-specific fine-tuning hurts generalization. `SEAL` adds acoustic conditioning and constrained decoding to reduce hallucinations. | Very viable in your stack because this is fundamentally a post-processing layer over transcript + diarization output. The main Apple constraint is local context budget and runtime, not model support. | Papers. Code/models vary. | [DiarizationLM](https://arxiv.org/abs/2401.03506), [Contextual beam search](https://arxiv.org/abs/2309.05248), [Generalizable diarization correction](https://arxiv.org/abs/2406.04927), [SEAL PDF](https://assets.amazon.science/22/14/0ebc502745a5990284ca1f4b08dc/seal-speaker-error-correction-using-acoustic-conditioned-large-language-models.pdf) |
| What prompt patterns look strongest? | The literature consistently favors a **compact transcript representation** rather than free-form prose. `DiarizationLM` explicitly feeds a compact textual encoding of transcript + speaker sequence. `SEAL` also conditions the model with transcript-format choices plus acoustic confidence labels and uses constrained decoding to prevent text drift. **Inference:** for Consensus, the best local pattern is likely a compact utterance list with `speaker`, `start`, `end`, `text`, and a coarse confidence bin, not a long natural-language prompt. | Excellent locally; this is prompt design plus post-processing. | Same as above. | [DiarizationLM](https://arxiv.org/abs/2401.03506), [SEAL PDF](https://assets.amazon.science/22/14/0ebc502745a5990284ca1f4b08dc/seal-speaker-error-correction-using-acoustic-conditioned-large-language-models.pdf) |
| What output format works best for large transcripts? | I did **not** find a diarization-specific paper that benchmarks **JSON vs XML vs diff** on local 8B models. `DiarizationLM` uses compact text formats for prompting; `SEAL` emphasizes constrained decoding to preserve the original word sequence. **Inference:** for Consensus, the safest engineering output is a **JSON edit list** over spans, because it is easy to validate, replay, and reject. | Very good. JSON edit lists are easy to validate locally before merge. | Engineering inference, not a literature result. | [DiarizationLM](https://arxiv.org/abs/2401.03506), [SEAL PDF](https://assets.amazon.science/22/14/0ebc502745a5990284ca1f4b08dc/seal-speaker-error-correction-using-acoustic-conditioned-large-language-models.pdf) |
| How should long transcripts be handled? | None of the public papers gives a neat one-size-fits-all recipe for 1h+ local transcripts. **Inference:** use a **hierarchical pass**: overlapping windows for local proposals, then a global reconciliation pass over speaker-change candidates and segment summaries. Avoid single-shot hour-long prompting on an 8B local model. | Feasible, but you need a chunker and merge validator. | Inference. | Supported indirectly by the chunking / sequence-length constraints visible across local-model workflows and long-form transcription practice. |
| Known failure modes? | The public literature is consistent here: **ASR errors matter a lot**, **text-only correction can over-correct**, and **domain mismatch hurts**. The generalization paper explicitly says fine-tuned models were constrained by the ASR tool used to create the transcripts. `SEAL` directly motivates acoustic conditioning because the LLM otherwise lacks access to acoustic evidence and can over- or under-correct. | Apple is not the issue; failure modes are conceptual. | Same as above. | [Generalizable diarization correction](https://arxiv.org/abs/2406.04927), [SEAL PDF](https://assets.amazon.science/22/14/0ebc502745a5990284ca1f4b08dc/seal-speaker-error-correction-using-acoustic-conditioned-large-language-models.pdf) |

### Recommended local schema for Consensus

This is an **engineering recommendation**, not a claimed literature consensus:

```json
{
  "window_start": 126.0,
  "window_end": 171.0,
  "known_speakers": ["Brant", "Caller_A"],
  "items": [
    {
      "start": 127.32,
      "end": 128.10,
      "speaker": "SPEAKER_1",
      "confidence_bin": "low",
      "text": "yeah"
    }
  ],
  "edits": [
    {
      "start": 127.32,
      "end": 128.10,
      "from": "SPEAKER_1",
      "to": "SPEAKER_0",
      "reason": "backchannel_inside_other_turn",
      "llm_confidence": 0.71
    }
  ]
}
```

Why I prefer this:

- It is easy to validate against the original transcript.
- It lets you reject edits outside low-confidence regions.
- It keeps the LLM from rewriting transcript text.
- It aligns well with a second-pass acoustic verifier.

### Sharp "why this might fail" on the LLM-arbiter idea

The literature supports the idea, but only under constraints:

1. **Text-only arbitrage is not enough.** `SEAL` is persuasive here: acoustic conditioning helps because lexical logic alone misses turn acoustics and overlap.
2. **ASR bias leaks straight into the arbiter.** The 2024 generalization paper shows ASR-specific fine-tuning can reduce portability.
3. **Long local prompts are where small models get sloppy.** A single 60-minute transcript is exactly the kind of sequence where a local 8B model starts inventing "cleaner" structure than the audio supports.
4. **Phone calls are a trap for conversational heuristics.** Similar-voiced dyads often alternate in predictable question-answer patterns, but they also produce many acknowledgment tokens that are ambiguous without acoustics.

**Bottom line:** implement the LLM as a **constrained edit proposer over low-confidence spans**, not as the final authority over the whole transcript.

---

## Q3. Prosodic and lexical signal channels

### Short answer

The public evidence supports your instinct: prosody and turn-taking cues are useful, especially for **boundary proposal and smoothing**. The strongest current evidence I found is not "pitch-only fixes diarization," but rather that **acoustic timing/prosody and lexical context work best together** for turn-taking and backchannel prediction.

### Findings by sub-question

| Sub-question | Short factual answer | Apple Silicon viability | License | Primary sources |
|---|---|---|---|---|
| Current literature on fusing prosodic features with diarization? | The clearest current direction I found is **fusion**, not replacement. The 2024 turn-taking/backchannel paper explicitly fuses a neural acoustic model with an LLM and shows better turn-taking/backchannel prediction than single-modality baselines. The 2025 multimodal turn-taking/backchannel paper reinforces that acoustic, linguistic, and timing cues are complementary. **Inference:** for Consensus, prosody belongs in a late-fusion scorer or evidence graph, not as a stand-alone relabeler. | Very feasible. Prosodic features are cheap to compute. | Papers. | [Turn-taking and Backchannel Prediction with Acoustic and Large Language Model Fusion](https://arxiv.org/abs/2401.14717), [Predicting Turn-Taking and Backchannel in Human-Machine Conversations Using Linguistic, Acoustic, and Visual Signals](https://arxiv.org/abs/2505.12654), [Continuous backchannel prediction with VAP](https://arxiv.org/abs/2410.15929) |
| Best Swift / Accelerate-compatible pitch tracker? | I did **not** find a mature, widely adopted Swift-native `pYIN` or `CREPE` package that is already the obvious production choice. The best portable neural option I found is **ONNX CREPE**; the best low-dependency path is a custom **YIN / pYIN-style vDSP implementation** in Swift. My practical recommendation is: use **cheap YIN-style F0 for online boundary proposals**, and only consider CREPE if YIN proves too noisy on phone audio. | YIN/pYIN-style DSP is excellent on Apple via Accelerate. ONNX CREPE is portable, but it adds another runtime and conversion step. | `onnxcrepe` is MIT. A custom YIN implementation would be yours. | [onnxcrepe](https://github.com/yqzhishen/onnxcrepe) |
| Is there a speech dataset of backchannels / short turns? | Yes, but the public landscape is more scattered than I expected. The 2025 MM-F2F paper introduces a large dataset with turn-taking and backchannel annotations. The 2024/2025 backchannel papers also operate on real conversational backchannel data and VAP-style continuous prediction setups. I did **not** find one canonical "phone-call backchannel corpus" that clearly dominates the field the way CALLHOME does for diarization. | N/A | Papers and their linked data/code. | [MM-F2F paper](https://arxiv.org/abs/2505.12654), [Continuous backchannel prediction with VAP](https://arxiv.org/abs/2410.15929), [Listener-aware backchannel predictor](https://arxiv.org/abs/2304.04478) |
| Any work on turn-taking models as a smoothing prior? | Yes. The turn-taking/backchannel papers are effectively learning or scoring **where a turn is likely to continue or flip**, which is exactly the kind of prior you want over noisy diarization. This is a strong fit for a Consensus boundary prior. | Very feasible. | Papers. | [2401.14717](https://arxiv.org/abs/2401.14717), [2410.15929](https://arxiv.org/abs/2410.15929), [2505.12654](https://arxiv.org/abs/2505.12654) |
| Latest on end-of-turn detection models? | Public-source evidence here is thinner than I wanted. The strongest Apple-native practical artifact I found is **Parakeet EOU** in speech-swift, which is explicitly positioned for streaming dictation and end-of-utterance detection. I also found `mlx-audio-swift` advertising **SmartTurn** in an Apple-Silicon MLX audio stack, but I did not find peer-reviewed/public benchmarking material that let me rank it confidently against Parakeet EOU. | Good if you use speech-swift / MLXAudio. | speech-swift Apache-2.0; mlx-audio-swift MIT. Underlying model weights may vary. | [speech-swift README](https://github.com/soniqo/speech-swift), [mlx-audio-swift README](https://github.com/Blaizzy/mlx-audio-swift) |

### Recommendation for Consensus

I would implement this channel in two stages:

1. **Stage A: cheap deterministic prosody**
   - F0 median and F0 delta
   - voiced/unvoiced transitions
   - pause length
   - speaking-rate change

2. **Stage B: learned turn prior**
   - backchannel prior
   - question-to-answer prior
   - end-of-turn probability

Then feed both into the same boundary candidate pool as acoustic diarizers and the LLM arbiter.

---

## Q4. Speaker enrollment / verification on short segments

### Short answer

For Consensus specifically, the best **practical** open-license Apple-Silicon choice is **WeSpeaker ResNet34**, because there are already Apple-oriented CoreML / MLX ports and it is already adjacent to the pyannote / speech-swift ecosystem. If you were optimizing for raw speaker-verification research performance rather than shipping friction, **ECAPA-family** or **TitaNet** would still be serious contenders.

### Findings by sub-question

| Sub-question | Short factual answer | Apple Silicon viability | License | Primary sources |
|---|---|---|---|---|
| Best open-license embedding model for phone-band audio on Apple Silicon? | **Best practical choice:** WeSpeaker ResNet34. Not because it is guaranteed to win every benchmark, but because it has the cleanest Apple path today and is already used in modern diarization stacks. **Best research-family alternatives:** ECAPA-TDNN / ECAPA2 and TitaNet. Resemblyzer is easiest conceptually but too old and general to be my first choice for a production phone-call speaker library. | WeSpeaker has public CoreML and MLX conversions. ECAPA/TitaNet are more work on Apple today. Resemblyzer is Python-first. | WeSpeaker project Apache-2.0; official HF model cards commonly CC-BY-4.0; Apple conversions vary. Resemblyzer Apache-2.0. | [WeSpeaker repo](https://github.com/wenet-e2e/wespeaker), [WeSpeaker official HF model card](https://huggingface.co/Wespeaker/wespeaker-voxceleb-resnet34-LM), [CoreML WeSpeaker conversion](https://huggingface.co/aufklarer/WeSpeaker-ResNet34-LM-CoreML), [speech-swift README](https://github.com/soniqo/speech-swift), [Resemblyzer](https://github.com/resemble-ai/Resemblyzer) |
| Minimum enrollment duration for reliable ID on phone audio? | I did **not** find a neat new 2024-2026 open-source consensus number specifically for phone-band calls. The older 10-30 second rule of thumb still looks directionally right, and phone audio almost certainly wants the **upper end** of that range. **Inference:** target at least **20-30 seconds of relatively clean, non-overlapped speech** for a durable library entry, and avoid treating 3-5 seconds as "enrollment complete." | Easy to support in product UX. | Inference from speaker-verification practice, not a new single paper result. | General SV literature plus model docs. |
| How to handle short segments under 1 second? | This remains a weak spot. `ECAPA2` explicitly targets robustness to short utterance lengths, which is encouraging, but sub-second speaker verification is still materially weaker than multi-second enrollment. **Recommendation:** do not verify sub-second spans in isolation; score them with neighboring context and speaker-turn priors. | Feasible. | Papers/models vary. | [ECAPA2](https://arxiv.org/abs/2401.08342) |
| Any research on domain-adapted enrollment across codec / call conditions? | I found related evidence, but not a perfect diarization-side answer. The closest evidence is the telephony super-resolution paper showing bandwidth/domain adaptation can shift narrowband embeddings toward wideband ones, plus general multilingual / cross-domain speaker verification work. **Inference:** domain mismatch between stored voiceprints and new calls is real, so you should maintain **multiple exemplars per person**, not a single centroid forever. | Very feasible in product design. | Mixed. | [Telephony super-resolution for speaker verification](https://arxiv.org/abs/2209.01702), [language similarity in speaker verification](https://arxiv.org/abs/2506.02777) |
| Formal name for "Anchor Speaker"? | The closest formal names are **speaker enrollment**, **speaker identification with enrollment**, **speaker registration**, and in some literature **target speaker verification / target speaker diarization** depending on the exact setup. `SpeakerLM` explicitly uses the term **speaker registration mechanism**. | Very feasible. | Paper/model specific. | [SpeakerLM](https://arxiv.org/abs/2508.06372), [pyannote voiceprints/identification docs](https://docs.pyannote.ai/introduction), [AssemblyAI speaker identification docs](https://www.assemblyai.com/docs/speech-understanding/speaker-identification/speaker-identification-existing-transcript) |

### Failure modes for the Anchor Speaker idea

This is a good idea, but the literature and product docs point to concrete traps:

1. **It solves identity continuity better than turn discovery.**
   - If the diarizer misses the boundary, the anchor cannot rescue a turn that never got proposed.

2. **Single-centroid libraries drift.**
   - Phone calls vary by codec, handset, room, and emotional state.
   - Keep multiple exemplars and re-cluster periodically.

3. **Sub-second spans are not strong biometric evidence.**
   - Short acknowledgments should inherit context from surrounding turns and priors.

4. **False certainty is dangerous.**
   - A persistent library can make wrong IDs look authoritative.
   - Expose uncertainty and let the user correct identity.

5. **Under GDPR-style regimes, voiceprints are not "just metadata."**
   - If used for unique identification, they are biometric personal data.

**Bottom line:** ship Anchor Speaker as a **confidence-weighted identification layer** with explicit opt-in and easy deletion, not as an infallible global truth source.

---

## Q5. Overlap handling

### Short answer

For meetings, overlap-aware diarization matters. For phone calls, overlap is less central, but **overlap uncertainty flags** are still worth it because they explain why attribution is weak around interruptions. On Apple Silicon today, the strongest practical overlap-aware options are **Sortformer**, **LS-EEND**, and pyannote-style overlap-aware segmentation. I would **surface overlap as uncertainty before I tried separation**.

### Findings by sub-question

| Sub-question | Short factual answer | Apple Silicon viability | License | Primary sources |
|---|---|---|---|---|
| Current SOTA overlap-aware diarization on Apple Silicon? | The most practical Apple-facing overlap-aware options are **Sortformer** and **LS-EEND**. FluidAudio documents both as Apple-native diarizer families. Public overlap-aware research also points to EEND-OLA / TOLD-style overlap-aware modeling as strong on CALLHOME. pyannote Community-1 also explicitly includes overlapped-speech-detection as part of its modern toolkit, though not as a separate Apple-native CoreML package. | Sortformer and LS-EEND are the strongest Apple story. pyannote on Apple is mostly via SpeakerKit / custom ports. | Sortformer model terms are NVIDIA Open Model License; LS-EEND ONNX MIT; pyannote Community-1 CC-BY-4.0. | [FluidAudio README](https://github.com/FluidInference/FluidAudio/blob/main/README.md), [Sortformer v2.1 card](https://huggingface.co/nvidia/diar_streaming_sortformer_4spk-v2.1), [LS-EEND ONNX](https://huggingface.co/GradientDescent2718/LS-EEND-ONNX), [TOLD / EEND-OLA](https://arxiv.org/abs/2303.05397), [pyannote Community-1](https://huggingface.co/pyannote/speaker-diarization-community-1) |
| Should overlap output be used as a flag rather than separation? | **Yes, especially for Consensus.** The user-facing value of "this span contains overlap, attribution is uncertain" is high, and it is much cheaper and safer than trying to separate and re-transcribe everything. | Very feasible. | N/A | Supported by overlap-aware diarization literature and product design logic. |
| Joint ASR + diarization ports on Apple Silicon since April 2026? | Publicly, I still do **not** see a credible ready-to-drop Apple-Silicon port of **DiCoW** or a Sortformer+Canary-style joint stack. The direction is real in research, but it still looks like a research sidecar rather than a production dependency for Consensus. | Low near-term viability. | DiCoW is Apache-2.0 at the repo level; dependent pieces vary. | [DiCoW paper](https://arxiv.org/abs/2501.00114), [DiCoW repo](https://github.com/BUTSpeechFIT/DiCoW), [Sortformer paper](https://arxiv.org/abs/2409.06656) |

### Recommendation for Consensus

- **Meetings:** keep an overlap-aware side channel.
- **Phone calls:** use overlap mostly as an uncertainty flag.
- **Do not** spend early cycles on source separation unless your benchmark shows overlap, not boundary timing, is the primary failure mode.

---

## Q6. Evaluation infrastructure

### Short answer

Use **MeetEval** for **cpWER / tcpWER**, and pair it with **dscore / md-eval-style DER**. I found no serious reason to build custom metrics first. Six calls are enough to catch regressions, but not enough to claim statistical significance for product decisions.

### Findings by sub-question

| Sub-question | Short factual answer | Apple Silicon viability | License | Primary sources |
|---|---|---|---|---|
| Best existing open-source tooling for cpWER / tcpWER / DER? | **MeetEval** should be your center of gravity. Its README explicitly supports **cpWER**, **tcpWER**, several related multi-speaker WER metrics, and even wraps DER tooling. For DER/JER specifically, **dscore** remains a standard reference implementation in the open community. `md-eval.pl` still matters historically, but I would not center new work on it directly. | Excellent, because these are evaluation tools, not runtime inference dependencies. Python wrapper from Swift is easy. | MeetEval is open source; dscore is open source. | [MeetEval README](https://github.com/fgnt/meeteval), [MeetEval paper](https://arxiv.org/abs/2307.11394), [dscore README](https://github.com/nryant/dscore) |
| Swift-native tools or easily wrapped from Swift? | I did **not** find a Swift-native equivalent with comparable maturity. The pragmatic answer is to wrap MeetEval and dscore as subprocess tools from Swift or a helper Python environment. | Very feasible. | Same as above. | [MeetEval](https://github.com/fgnt/meeteval), [dscore](https://github.com/nryant/dscore) |
| Minimum test corpus size for telephone audio? | I did **not** find a public source that gives a universally accepted minimum specifically for telephone diarization. **Inference:** six calls are enough for smoke tests, but not enough for stable comparative decisions. I would target at least **20-30 calls** spanning codec variation, speaker similarity, call quality, and 2-speaker vs small-group cases before trusting deltas, and I would report confidence intervals or bootstrap variance, not just raw averages. | N/A | Inference. | Evaluation practice plus the need for paired RTTM/text references. |

### Recommendation for Consensus

Build the benchmark harness around:

1. **MeetEval**
   - cpWER
   - tcpWER
   - optionally DI-cpWER if you want diarization-invariant comparison

2. **dscore**
   - DER
   - JER

3. **A corpus split that reflects your product**
   - 2-speaker phone calls
   - 3-6 speaker meetings
   - narrowband vs better broadband
   - easy vs same-voice vs interruption-heavy

---

## Q7. Product-side intelligence

### Short answer

Public product documentation strongly suggests that commercial systems handle speaker identity through some combination of:

- **generic diarization labels first**,
- **speaker naming / identification later**,
- **persistent speaker profiles or rematching**, and
- **short interactive correction loops**.

The most explicit public documentation I found for persistent speaker identity was **Otter** and **AssemblyAI**. I did **not** find equally clear public docs from Zoom or Fireflies describing a user-visible persistent speaker library.

### Findings by sub-question

| Sub-question | Short factual answer | Apple Silicon viability | License | Primary sources |
|---|---|---|---|---|
| How do commercial products handle speaker identification over time? | The clearest public example is **Otter**. Their help docs say tagging a speaker helps Otter recognize that speaker in future conversations, shared workspace speakers can be reused, and old conversations can be **rematched** using newer speaker-identification data. **AssemblyAI** publicly documents a two-stage pattern: diarization first, then speaker identification over the finished transcript using known names or roles. **pyannoteAI** also publicly exposes **voiceprints** as a first-class feature. I did **not** find comparably explicit public speaker-library docs from Zoom or Fireflies. | Very aligned with Consensus. | Product docs / SaaS features. | [Otter tagging help](https://help.otter.ai/hc/en-us/articles/360048465453-Tagging-speaker-names-in-a-conversation), [Otter rename help](https://help.otter.ai/hc/en-us/articles/21665980053655-Rename-a-speaker), [AssemblyAI diarization docs](https://www.assemblyai.com/docs/pre-recorded-audio/label-speakers), [AssemblyAI speaker identification docs](https://www.assemblyai.com/docs/speech-understanding/speaker-identification/speaker-identification-existing-transcript), [pyannoteAI intro/features](https://docs.pyannote.ai/introduction) |
| What's the UX pattern for voice review? | The public pattern is simple: **speaker labels first, then quick correction and rematching**. Otter's docs are especially instructive here: users tag a speaker once, Otter learns, and later rematches prior transcripts. That maps well to a Consensus "voice review" step where the app plays representative clips and asks "who is this?" | Excellent fit for Consensus. | N/A | [Otter tagging help](https://help.otter.ai/hc/en-us/articles/360048465453-Tagging-speaker-names-in-a-conversation) |
| Legal/compliance concerns with persistent voiceprint storage? | **Yes.** GDPR materials explicitly treat biometric data used for unique identification as sensitive / special-category data. On-device storage helps with privacy and transfer risk, but it does **not** automatically remove the legal classification. From the platform side, Apple's Keychain docs describe Keychain Services as a place to securely store small chunks of data; for a production design, I would use Keychain for **keys / secrets**, not as the primary store for large embedding blobs. Store embeddings encrypted on disk, with the encryption key in Keychain. | Good platform story if you encrypt locally and expose deletion/export/disable controls. | GDPR is law; Apple docs are platform guidance. | [EUR-Lex GDPR text](https://eur-lex.europa.eu/legal-content/EN/TXT/HTML/?uri=CELEX:32016R0679), [Apple Keychain Services](https://developer.apple.com/documentation/security/keychain_services) |

### Product recommendation for Consensus

The best product pattern is:

1. **Diarize first with generic labels**
2. **Ask for quick voice review on 2-5 representative clips**
3. **Save explicit speaker profiles only with opt-in**
4. **Use rematch / re-identify on older projects when the user confirms a person**

That is much safer and more legible than pretending the system "just knows" a person forever.

---

## Revised and Ranked Implementation Recommendations

This section intentionally **overrides or tightens** parts of the current Phase 1 / Phase 2 / Phase 3 plan where the research points more clearly.

### 1. Finish the word-timeline rebuild and make it the benchmark gate

This remains the highest-leverage move.

Why it stays #1:

- Every downstream speaker decision improves when word timings are real.
- The current literature on LLM correction and telephony specialists does not remove the need for accurate word timing.
- You already have working momentum here.

What I would add:

- Make **tcpWER** and **boundary-offset metrics** the primary gating metrics for word-timeline changes.
- Keep the chunked forced-alignment path.

### 2. Add a telephone-specialist diarizer sidecar before adding more heuristic passes

Revised recommendation:

1. **Try `LS-EEND-ONNX` CALLHOME first**
2. **Keep `diar_msdd_telephonic` as a research-sidecar second**

Why:

- LS-EEND already has a public ONNX artifact and an explicit CALLHOME variant.
- `diar_msdd_telephonic` is attractive, but its Apple path is worse.
- This gives you real domain diversity, unlike more SpeakerKit thresholds.

### 3. Implement the LLM arbiter as a constrained edit proposer, not a full-document relabeler

Specific revision to the Fresh Attack Plan:

- I **agree** with the LLM-arbiter direction.
- I **disagree** with making it a one-shot whole-transcript judge early.

Do this instead:

1. only send **low-confidence spans**
2. include **coarse acoustic confidence bins**
3. require **JSON edit output**
4. verify each edit acoustically before committing

### 4. Ship self-enrollment / voice library, but position it as identity continuity

I support this direction strongly, with one change in framing:

- Call it **Speaker Identification / Voice Library**
- Do **not** treat it as a direct diarization-quality fix

Use it for:

- auto-labeling known people
- stabilizing disputed short segments
- rematching older projects

### 5. Add a lightweight prosodic boundary channel now

This should move **up**, not stay as a speculative extra.

Practical version:

- YIN-style F0
- pause-duration prior
- speaking-rate change
- short backchannel detector

Use it only to **propose or up-weight boundaries**, not to directly assign speakers.

### 6. Treat overlap as an uncertainty layer before you try separation

For meetings:

- add overlap-aware diarizer votes
- surface overlap uncertainty in UI

For phone calls:

- mostly use overlap detection to explain low confidence around interruptions

### 7. Build the proper benchmark before Phase-3 moonshots

This should happen **before** any serious DiCoW / joint ASR investment.

Required stack:

- MeetEval cpWER / tcpWER
- DER / JER via dscore
- at least ~20-30 labeled calls before strong claims

### 8. Keep joint ASR + diarization as research-track only

This remains a good long-term direction, but the public Apple path is still weak.

Research-track candidates:

- DiCoW
- Sortformer + serialized speaker tags
- SpeakerLM-style registration-aware end-to-end work

Do not pull this onto the critical path yet.

---

## Specific Checkpoints / Weights / Packages To Try

### 1. `GradientDescent2718/LS-EEND-ONNX` — CALLHOME variant

- **Link:** [LS-EEND ONNX](https://huggingface.co/GradientDescent2718/LS-EEND-ONNX)
- **Why try it:** explicit **CALLHOME** variant; genuinely telephony-relevant; public ONNX export already exists.
- **Integration sketch:** run it as a telephony-specialist sidecar on phone calls only. Convert 16 kHz call audio to the model's expected 8 kHz frontend, keep state across chunks, threshold/post-process to RTTM, then feed its turns into your evidence graph as a second family of boundary evidence.

### 2. `nvidia/diar_streaming_sortformer_4spk-v2.1`

- **Link:** [Sortformer v2.1 model card](https://huggingface.co/nvidia/diar_streaming_sortformer_4spk-v2.1)
- **Why try it:** strong modern overlap-aware diarizer, good CALLHOME metrics, much better Apple-native story than NeMo MSDD if you use FluidAudio or a conversion path.
- **Integration sketch:** add as the meeting/overlap specialist, not the telephone specialist. Use its output for overlap flags and boundary proposals in your multi-signal fusion layer.

### 3. `diar_msdd_telephonic`

- **Link:** [NeMo configs](https://docs.nvidia.com/nemo-framework/user-guide/latest/nemotoolkit/asr/speaker_diarization/configs.html)
- **Why try it:** it is the clearest public telephony-specific diarization checkpoint I found.
- **Integration sketch:** keep it outside the shipping Swift app at first. Run it in a research harness or helper service, export RTTM, and compare against SpeakerKit + LS-EEND on the same telephone benchmark. Only consider deeper Apple integration if it clearly wins.

### 4. `Qwen/Qwen3-ForcedAligner-0.6B`

- **Link:** [speech-swift README](https://github.com/soniqo/speech-swift)
- **Why try it:** already validated inside this repo's ongoing work; still the best immediate timing-quality lever.
- **Integration sketch:** keep it post-merge, before any final speaker assignment or export.

### 5. `Wespeaker/wespeaker-voxceleb-resnet34-LM`

- **Links:** [official model card](https://huggingface.co/Wespeaker/wespeaker-voxceleb-resnet34-LM), [CoreML conversion](https://huggingface.co/aufklarer/WeSpeaker-ResNet34-LM-CoreML)
- **Why try it:** strongest practical voice-library option for Apple Silicon right now.
- **Integration sketch:** embed high-confidence spans, store multiple exemplars per person, compare disputed spans against a small set of per-person centroids or exemplars, and only auto-apply identities above a conservative threshold.

### 6. `onnxcrepe`

- **Link:** [onnxcrepe](https://github.com/yqzhishen/onnxcrepe)
- **Why try it:** portable neural F0 tracker with MIT license if simple YIN proves too noisy.
- **Integration sketch:** run it offline over the same 10 ms or 20 ms hop grid as your boundary pool, derive abrupt F0-shift candidates, then merge with pause and lexical cues before the evidence decoder.

### 7. `Parakeet EOU` in speech-swift

- **Link:** [speech-swift README](https://github.com/soniqo/speech-swift)
- **Why try it:** pragmatic Apple-native end-of-utterance prior, useful for turn-end smoothing even if it is not a diarizer.
- **Integration sketch:** run as a low-cost turn-end prior in streaming or chunked analysis, then incorporate as a feature in the boundary proposal score rather than as a hard boundary.

---

## Sharp "Why This Won't Work" Analysis

### LLM arbiter: why it can fail

1. **Text-only reasoning cannot hear hesitation, interruption, or acoustic continuity.**
   - `SEAL` is the clearest evidence for this.

2. **It will inherit ASR hallucinations and mis-segmentation.**
   - The generalization paper makes this explicit.

3. **A local 8B model will sound more certain than it is.**
   - Especially on long transcripts and same-voice dyads.

4. **It may optimize for conversational neatness rather than truth.**
   - Real speech is messy; LLMs like clean alternation.

**Implication:** keep the arbiter on a tight leash.

### Anchor Speaker / voice library: why it can fail

1. **A wrong enrollment pollutes future calls.**
2. **Codec / handset mismatch can drift the embedding.**
3. **Sub-second segments are too weak to trust on their own.**
4. **Persistent identity makes errors feel authoritative to users.**
5. **Biometric storage creates privacy and compliance obligations.**

**Implication:** treat the voice library as opt-in, multi-exemplar, reversible, and uncertainty-aware.

---

## Questions Public Sources Did Not Fully Answer

- I did **not** find a public, official **telephone-tuned pyannote Community-1** or **telephone-tuned Sortformer** checkpoint with a clean Apple-native port.
- I did **not** find a public Apple-Silicon port of **NeMo `diar_msdd_telephonic`**.
- I did **not** find a diarization-specific paper that benchmarks **JSON vs XML vs diff output schemas** on **local 8B-class models**.
- I did **not** find a single canonical public **phone-call backchannel dataset** that obviously dominates the way CALLHOME dominates telephone diarization discussion.
- I did **not** find clear public-facing documentation from **Zoom** or **Fireflies** describing a user-visible persistent speaker library comparable to what Otter documents publicly.

---

## Final Recommendation

If I were steering Consensus from here, I would do this in order:

1. **Finish and benchmark the word-timeline rebuild**
2. **Add LS-EEND CALLHOME as a telephony-specialist sidecar**
3. **Implement constrained LLM speaker correction over low-confidence spans**
4. **Add WeSpeaker-based voice library / enrollment**
5. **Add F0 + short-turn + pause priors**
6. **Stand up MeetEval + dscore on a larger labeled phone corpus**
7. **Only then decide whether deeper evidence-graph or joint-ASR research is worth the cost**

That sequence gives you the best balance of research-backed upside, Apple-Silicon viability, and product value.
