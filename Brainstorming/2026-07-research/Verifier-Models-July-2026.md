# Local Audio-Reasoning LLMs for the Consensus Verifier Role — July 2026

*Research report generated July 10, 2026 (Claude web-research agent) for the Consensus remake. Companion reports: `ASR-Engines-July-2026.md`, `Diarization-July-2026.md`. Synthesis in `/CONSENSUS-REMAKE-PLAN.md`.*

## TL;DR

The landscape changed materially since April 2026. llama.cpp had an "audio spring": Qwen3-Omni-30B-A3B, Gemma 4 audio, Qwen3-ASR, and MERaLiON-2 all landed in `mtmd` between April and June 2026. **Top recommendation: Qwen3-Omni-30B-A3B (Instruct, with the Thinking variant as an experiment)** — best-in-class open-weight audio understanding (MMAU 77.5), Apache-2.0, official ggml-org GGUFs, and MoE speed (~3B active params). **Gemma 4 12B** is the standout *complement*: Apache-2.0 (a first for Gemma), tiny, and its 30-second audio window is an exact fit for the masked-cloze task. **Step-Audio-R1.1 remains blocked** — still vLLM-only, no GGUF/MLX as of July 2026.

---

## 1. Step-Audio-R1.1 status: still not runnable on Apple Silicon

- Impressive on paper: 33.5B params, `step_audio_2` architecture, Apache-2.0, updated Feb 14, 2026 ([HF](https://hf.co/stepfun-ai/Step-Audio-R1.1)). First audio LLM where extended chain-of-thought actually helps on audio (previously CoT *hurt* — "inverted scaling"); 83.6% avg across Big Bench Audio / Spoken MQA / MMSU / MMAU / Wild Speech, beating Gemini 2.5 Pro (81.5%) ([arXiv 2511.15848](https://arxiv.org/abs/2511.15848)).
- **But**: requires customized vLLM ([GitHub](https://github.com/stepfun-ai/Step-Audio-R1/)); no llama.cpp support for `step_audio_2`, no open feature request, no MLX port. Only community quant is MXFP8 compressed-tensors (vLLM/CUDA).
- **Verdict: still a "watch" item.** Adopt the day a llama.cpp port lands.

## 2. llama.cpp mtmd audio support as of July 2026

Per the [official multimodal docs](https://github.com/ggml-org/llama.cpp/blob/master/docs/multimodal.md), audio-input models supported: **Ultravox 0.5 (1B/8B), Voxtral-Mini 3B, Qwen3-ASR (0.6B/1.7B), Qwen2.5-Omni (3B/7B), Qwen3-Omni-30B-A3B (Instruct + Thinking), Gemma 4 (audio on E-series/12B)**, plus MERaLiON-2. Three audio models merged within 48 hours in April. Gemma 4's conformer audio encoder landed via [PR #21421](https://github.com/ggml-org/llama.cpp/pull/21421) (April 12, includes built-in 16kHz resampling). Audio *output* only at planning stage — irrelevant for the verifier.

**Qwen3-ASR issue [#21847](https://github.com/ggml-org/llama.cpp/issues/21847) (no content on longer audio) is closed**, and follow-up quality bug [#22357](https://github.com/ggml-org/llama.cpp/issues/22357) was fixed. (The ASR-research agent found #21847 closed as "bug-unconfirmed" with no documented fix — verify empirically before trusting llama.cpp Qwen3-ASR on long audio.) Qwen3-ASR is a pure transcriber, not a verifier candidate, but now usable as another opinion source.

## 3. MLX ecosystem

- [mlx-vlm](https://github.com/Blaizzy/mlx-vlm) now supports Omni models with `--audio` generation.
- [mlx-audio](https://github.com/Blaizzy/mlx-audio) covers STT (Whisper, Parakeet, Voxtral Realtime, Qwen3-ASR, VibeVoice) and TTS.
- For the *audio-reasoning* verifier role, llama.cpp/mtmd remains the more mature path. No MLX port of Step-Audio-R1 or the Qwen3-Omni audio-reasoning stack found.

---

## 4. Top 3 candidates (ranked)

### #1 — Qwen3-Omni-30B-A3B (Instruct; trial Thinking) — REPLACE candidate

| | |
|---|---|
| Size / RAM | 30B-A3B MoE (~35B incl. encoders); Q4_K_M GGUF ~18–20GB + mmproj; Q8 ~35GB — comfortable on 96GB; ~3B active params so decode is fast |
| Runtime | First-class llama.cpp mtmd; **official [ggml-org Instruct GGUF](https://hf.co/ggml-org/Qwen3-Omni-30B-A3B-Instruct-GGUF)** (Apr 13, 2026); Thinking GGUFs from community |
| Benchmarks | MMAU 77.5 (Instruct) / 75.4 (Thinking); MMSU 69.0/70.2; VoiceBench 85.5/88.8; LibriSpeech clean WER 1.22% ([model card](https://huggingface.co/Qwen/Qwen3-Omni-30B-A3B-Instruct)). Open SOTA on 32 of 36 audio benchmarks |
| Hallucination | Captioner variant marketed as "low-hallucination"; no adverse mtmd reports found |
| License | Apache-2.0 |
| Fit for masked-cloze | Strong: instruction-following omni model, short audio + text context natively; interleaved audio+text works in `llama-mtmd-cli`/`llama-server` |

**Why #1:** only model combining top-tier audio understanding, genuinely supported llama.cpp path with *official* GGUFs, permissive license, and MoE speed. Caveat: Qwen-family conservatism risk (Qwen2.5-Omni 7B refused to engage) — A/B test on the masked-cloze eval set before switching. Instruct *outscores* Thinking on MMAU; test Instruct first.

### #2 — Gemma 4 12B (or E4B for speed) — COMPLEMENT candidate

| | |
|---|---|
| Size / RAM | 12B dense: Q4 ~7–8GB, Q8 ~13GB; E4B smaller. Audio native on E2B/E4B/12B (not 26B-A4B) ([model card](https://ai.google.dev/gemma/docs/core/model_card_4)) |
| Runtime | llama.cpp audio merged April 12, 2026 ([PR #21421](https://github.com/ggml-org/llama.cpp/pull/21421)); community-verified real-world use incl. 8GB Macs |
| Constraint | **Audio max 30 seconds per clip** — limitation for full transcripts, perfect match for the masked-cloze window |
| License | **Apache-2.0** — Gemma 4 dropped the restrictive Gemma Terms of Use ([announcement](https://blog.google/innovation-and-ai/technology/developers-tools/gemma-4/)) |
| Fit | Built-in thinking mode; strong instruction following; cheap enough to run as a **second verifier alongside a bigger model for consensus voting** |

**Why #2:** best power-to-weight; two disagreeing verifiers → flag for human review — fits Consensus's reconciliation workflow exactly.

### #3 — Voxtral Small 24B (incumbent — keep on the bench), Fun-Audio-Chat-8B as watch item

- **Voxtral Small 24B-2507 got no successor**: Mistral's 2026 audio releases were Voxtral TTS (Mar 26, 4B, generation) and Voxtral Realtime 4B STT — nothing new in the 24B understanding class ([Mistral](https://mistral.ai/models/)). Remains a top open audio model with DPO training aimed at hallucination reduction, Apache-2.0, proven in the constrained masked-cloze role. Defensible as one leg of a two-verifier ensemble. (Note: GGUFs were deleted from local disk; re-download only if it wins a seat in the bake-off.)
- **Fun-Audio-Chat-8B** (Alibaba FunAudioLLM, Dec 2025): highest-scoring open audio LLM per size — MMAU 76.6 at 8B, Apache-2.0 ([arXiv 2512.20156](https://arxiv.org/abs/2512.20156), [HF](https://hf.co/FunAudioLLM/Fun-Audio-Chat-8B)). **Blocker:** custom `funaudiochat` architecture, no llama.cpp/MLX; only Mac-adjacent port is Alibaba's MNN runtime. Watch for GGUF.

Ruled out: **Kimi-Audio 7B** (stale, no GGUF); **GLM** (2026 releases are text/agent only); **Ultravox** (Llama-3.2-era, outclassed); **LFM2.5-Audio** (~1.5B, too small); **Phi-4-multimodal** (no notable audio successor).

---

## 5. Research trends: audio-grounded ASR error correction

The masked-cloze verification design is now visible in the literature:

- **Cloze-style GER prompting**: Dec 2025 dissertation on scalable AVSR explicitly refines generative error correction with "cloze-style completion and re-injecting acoustic features to better ground LLM corrections" ([arXiv 2512.14083](https://arxiv.org/pdf/2512.14083)) — direct validation.
- **Dual-hypotheses correction**: "Two Heads Are Better Than One: Audio-Visual Speech Error Correction with Dual Hypotheses" ([arXiv 2510.13281](https://arxiv.org/pdf/2510.13281)) — feeding the LLM two candidate readings plus acoustic evidence; essentially the A/B verifier framing.
- **Anti-hallucination GER**: "Fewer Hallucinations, More Verification: A Three-Stage LLM-Based Framework for ASR Error Correction" ([HF paper 2505.24347](https://hf.co/papers/2505.24347)) — error pre-detection → CoT correction → reasoning verification, training-free; maps onto Deep Review's pipeline.
- **Hallucination measurement**: **HalluAudio** (ACL 2026, [arXiv 2604.19300](https://arxiv.org/pdf/2604.19300)) — 5,000+ human-verified QA pairs measuring hallucination rate, yes/no bias, refusal rate in audio LLMs. Right off-the-shelf template for comparing Voxtral vs Qwen3-Omni vs Gemma 4 before committing.
- Also relevant: AVGER ([arXiv 2501.04038](https://arxiv.org/pdf/2501.04038)); non-intrusive ASR-refinement survey ([arXiv 2508.07285](https://arxiv.org/pdf/2508.07285)).

## 6. Recommended action plan

1. **Pull [ggml-org/Qwen3-Omni-30B-A3B-Instruct-GGUF](https://hf.co/ggml-org/Qwen3-Omni-30B-A3B-Instruct-GGUF)** (Q4_K_M + audio mmproj); run through the existing masked-cloze eval harness vs Voxtral Small 24B. Watch for Qwen-family no-edit conservatism.
2. **Add Gemma 4 12B (Q8, ~13GB)** as a second verifier vote — 30s audio cap matches the cloze window; both fit in RAM simultaneously on the M2 Max.
3. **Keep Step-Audio-R1.1 on the watch list** — becomes the purpose-built answer the moment a `step_audio_2` llama.cpp port appears.
4. All three recommended models (Qwen3-Omni, Gemma 4, Voxtral) are Apache-2.0 — any combination is safe for public distribution.
