# Local ASR on Apple Silicon — State of the Art, July 2026

*Research report generated July 10, 2026 (Claude web-research agent) for the Consensus remake. Companion reports: `Diarization-July-2026.md`, `Verifier-Models-July-2026.md`. Synthesis in `/CONSENSUS-REMAKE-PLAN.md`.*

## Executive Summary

Since April 2026 the landscape has shifted in three ways: (1) **IBM Granite Speech 4.1 2B** (April 30, 2026) took the #1 spot on the Open ASR Leaderboard at 5.33% mean WER under Apache 2.0; (2) the **Qwen3-ASR ecosystem matured on Apple Silicon** — llama.cpp merged support in April 2026 but the long-audio bug (#21847) is still effectively unresolved, while dedicated GGML/MLX/Swift ports now work well including word timestamps via ForcedAligner; (3) the existing stack got better for free — **FluidAudio v0.15.5** (July 7, 2026) shipped a unified Parakeet backend with word-level timestamps and custom-vocabulary controls, and **WhisperKit graduated to the Argmax OSS SDK v1.0** (May 2026, MIT). **VibeVoice-ASR remains current** — no newer version has shipped since January 21, 2026, and it is still the only open model that does 60-minute single-pass transcription with built-in diarization and hotwords. The canonical engine choice remains sound; the second-opinion bench has stronger candidates now.

---

## 1. VibeVoice-ASR Status (canonical engine)

**Verified facts:** VibeVoice began as Microsoft's open TTS project; **VibeVoice-ASR** is a genuinely distinct ASR model Microsoft open-sourced **January 21, 2026** ([GitHub](https://github.com/microsoft/VibeVoice), [announcement](https://techcommunity.microsoft.com/blog/azure-ai-foundry-blog/introducing-vibevoice-asr-longform-structured-speech-recognition-at-scale/4501276)). ~9B params BF16 (17.3GB), **MIT license**, up to **60 minutes of audio in a single pass within a 64K-token context**, structured "who/when/what" output (diarization + timestamps built in), 50+ languages, and **customized hotwords** support ([HF model card](https://huggingface.co/microsoft/VibeVoice-ASR), [tech report arXiv:2601.18184](https://arxiv.org/pdf/2601.18184)).

**Maintenance:** Actively maintained. Transformers-native support landed **March 6, 2026**; vLLM inference and finetuning code released; ~690K monthly downloads. **No newer ASR version has been released as of July 2026** — the January weights are current.

**MLX path:** `mlx-community/VibeVoice-ASR-4bit` (5.71GB) runs via [mlx-audio](https://github.com/Blaizzy/mlx-audio); Simon Willison [transcribed 1 hour of audio in ~8m45s on an M5 Max](https://simonwillison.net/2026/Apr/27/vibevoice/). Known hard limit: **audio >60 min must be split**.

**Benchmark position:** The tech report claims lowest error on 8 of 16 long-form settings (DER/cpWER/tcpWER) with marginal degradation elsewhere ([DeepWiki summary](https://deepwiki.com/microsoft/VibeVoice/3-vibevoice-asr)). Nothing open has displaced it for long-form + diarization + hotwords as a single model. **Verdict: keep as canonical; nothing newer to migrate to.**

## 2. Qwen3-ASR Family (Alibaba, Apache 2.0)

Released **January 29, 2026**: Qwen3-ASR-0.6B, Qwen3-ASR-1.7B, and Qwen3-ForcedAligner-0.6B ([GitHub](https://github.com/QwenLM/Qwen3-ASR), [tech report arXiv:2601.21337](https://arxiv.org/abs/2601.21337)). 52 languages, unified streaming/offline inference, **Apache 2.0** (App Store-safe).

- **Qwen3-ASR-1.7B WER:** LibriSpeech clean/other **1.63/3.38**, Open ASR Leaderboard mean **5.76**, GigaSpeech 8.45 ([HF card](https://huggingface.co/Qwen/Qwen3-ASR-1.7B)). SOTA-competitive at 1.7B.
- **Context biasing:** the Qwen3-ASR API accepts up to ~10K tokens of arbitrary biasing text ([overview](https://qwen-ai.com/qwen-asr/)); the tech report describes context-biasing training in the open models — verify the open-weights inference path exposes it during integration.
- **Word timestamps:** via the companion **ForcedAligner-0.6B** (11 languages; claims to beat E2E forced-alignment accuracy).
- **Runtime status on Apple Silicon:**
  - **llama.cpp:** support merged ~April 13, 2026 ([announcement](https://x.com/ngxson/status/2043707526986813811)), **but issue [#21847](https://github.com/ggml-org/llama.cpp/issues/21847) (empty output beyond ~2 min of audio) is closed as "bug-unconfirmed" with no fix or workaround documented** — avoid llama.cpp for long audio. (Note: the verifier-research agent found #21847 marked closed with follow-up #22357 fixed; treat llama.cpp Qwen3-ASR as "verify empirically before trusting on long audio.")
  - **[qwen3-asr.cpp](https://github.com/predict-woo/qwen3-asr.cpp)** (MIT): dedicated GGML port, Metal dual-backend, flash attention (3.7x), ASR + ForcedAligner combined pipeline, ~5s for 92s audio on M2 Pro. Young project — promising but immature.
  - **[mlx-qwen3-asr](https://github.com/moona3k/mlx-qwen3-asr/)** — MLX port; fits the existing MLX sidecar directly.
  - **[speech-swift](https://github.com/soniqo/speech-swift)** (Apache 2.0, v0.0.21, ~1K stars): native Swift toolkit with Qwen3-ASR (MLX+CoreML), ForcedAligner word timestamps, Whisper, Parakeet, Nemotron streaming, Sortformer diarization. Could eventually run Qwen3-ASR **without a Python sidecar**, though pre-1.0. *(Already vendored in Consensus script targets.)*

## 3. Granite Speech 4.1 2B (IBM) — new leaderboard leader

Released **April 30, 2026** ([MarkTechPost](https://www.marktechpost.com/2026/04/30/ibm-releases-two-granite-speech-4-1-2b-models-autoregressive-asr-with-translation-and-non-autoregressive-editing-for-fast-inference/), [IBM Research](https://research.ibm.com/blog/granite-4-1-ai-foundation-models)). Two variants: autoregressive ASR+translation, and a non-autoregressive "editing" model (RTFx ~1820 on H100). **#1 on the Open ASR Leaderboard at 5.33% mean WER; 1.33 on LibriSpeech clean**; reportedly robust on noisy/meeting/telephony audio ([HF card](https://huggingface.co/ibm-granite/granite-speech-4.1-2b), [Northflank roundup](https://northflank.com/blog/best-open-source-speech-to-text-stt-model-in-2026-benchmarks)). **Apache 2.0.** En/Fr/De/Es/Pt/Ja.

Caveats: runs via Transformers (Python sidecar on MPS; no confirmed MLX/CoreML port yet); no documented hotword support; word-timestamp support unclear; long-form requires chunking. Best fit: high-accuracy **second-opinion engine** for Deep Review.

## 4. Parakeet / FluidAudio (second-opinion engine)

FluidAudio is very actively maintained — v0.15.x releases through **July 7, 2026** ([releases](https://github.com/FluidInference/FluidAudio/releases)):

- **v0.15.5 (Jul 7):** "Parakeet unified ASR" — native-Swift mel front-end, **word-level timestamps**, lower-latency streaming tiers, **custom vocabulary controls (per-term CTC thresholds + acoustic spotter)** — a hotword mechanism Consensus isn't using yet.
- **v0.15.5 also fixed chunk-merge seam artifacts in offline transcription** — directly relevant to long-form quality.
- **v0.15.0–0.15.3 (June):** Nemotron 3.5 streaming (40 locales, CoreML/ANE), SenseVoiceSmall, Parakeet Unified 0.6B chunked-attention backend.
- Earlier 2026: Parakeet-TDT-CTC-110M hybrid, CTC decoder with ARPA LM (9.4% WER with domain LM).

Model facts: [Parakeet TDT 0.6B v3](https://huggingface.co/nvidia/parakeet-tdt-0.6b-v3) (Aug 2025, 25 languages, 6.34% leaderboard WER) vs v2 (English-only, **6.05%** — more accurate for English) ([NVIDIA modelcard](https://build.nvidia.com/nvidia/parakeet-tdt-0_6b-v2/modelcard)); CoreML conversions at [FluidInference/parakeet-tdt-0.6b-v3-coreml](https://huggingface.co/FluidInference/parakeet-tdt-0.6b-v3-coreml). License: CC-BY-4.0. Also new: [nvidia/nemotron-speech-streaming-en-0.6b](https://huggingface.co/nvidia/nemotron-speech-streaming-en-0.6b) (Jan 2026, cache-aware streaming, ~7.28% streaming WER, NVIDIA Open Model License — review before shipping).

## 5. WhisperKit / Argmax

**v1.0.0 (May 1, 2026):** repo renamed to `argmaxinc/argmax-oss-swift`; bundles WhisperKit + SpeakerKit (pyannote diarization) + TTSKit in one **MIT** Swift package with Swift 6 concurrency ([GitHub](https://github.com/argmaxinc/WhisperKit)). No new Whisper-class model — `large-v3-v20240930` remains the accuracy recommendation. Custom-vocabulary and real-time-with-speakers live in the **paid Pro SDK 2**, not OSS. In [Dictato's 13,023-recording benchmark](https://dicta.to/blog/speech-to-text-engine-comparison-mac-2026/), WhisperKit still won clean English at **5.2% WER** and was best for brand names/proper nouns via vocabulary boosting. Upgrade the dependency; expect no accuracy jump.

## 6. Apple SpeechAnalyzer (macOS 26 "Tahoe")

`SpeechAnalyzer`/`SpeechTranscriber` shipped with macOS 26 ([docs](https://developer.apple.com/documentation/speech/speechanalyzer)) — fully on-device, extremely fast (34-min file in 45s; 55% faster than large-v3-turbo per [MacRumors](https://www.macrumors.com/2025/06/18/apple-transcription-api-faster-than-whisper/)). Dictato found it best-in-class for FR/DE/IT but **behind WhisperKit on English**, and it **lacks custom vocabulary**. Requires raising deployment target from macOS 15 to 26. Verdict: a free, fast third opinion someday — not an accuracy play for English.

## 7. Others (briefly)

- **Canary-Qwen-2.5B** (NVIDIA, Jul 2025): 5.63% leaderboard WER, English-only, CC-BY-4.0, but NeMo-only runtime — poor Mac fit.
- **Moonshine v2** (Feb 23, 2026): streaming-first, sub-200ms edge latency — a latency play, not an accuracy play ([arXiv:2602.12241](https://arxiv.org/abs/2602.12241)).
- **Kyutai STT** (`stt-2.6b-en`): unchanged, streaming-focused, CC-BY-4.0 — no 2026 update found.
- **LLM proofread post-pass:** Dictato found an LLM proofread layer **cuts jargon WER roughly in half (~20%→~10%)** — cheap win for the existing SummaryRunner/llama.cpp infrastructure ([Dictato](https://dicta.to/blog/speech-to-text-engine-comparison-mac-2026/)).

## Long-form (30–60 min) reliability notes

- The [Open ASR Leaderboard long-form track](https://huggingface.co/blog/open-asr-leaderboard) shows open models still trail closed systems on long-form; chunking strategy dominates outcomes. VibeVoice-ASR's single-pass 64K-token design is the right architecture — but its **60-minute/64K-token ceiling is the same failure class as the June 36-minute token-budget bug**; dense/fast speech can exhaust tokens before audio ends. Guard by duration *and* estimated token count, and split defensively.
- Qwen3-ASR long audio needs explicit `max_new_tokens` sizing — same failure mode.
- FluidAudio v0.15.5's chunk-seam fix directly improves Parakeet long-form output.

---

## Top 3 Recommendations to Benchmark (against 10.21% gold-file baseline)

1. **Qwen3-ASR-1.7B + ForcedAligner-0.6B via MLX** — best new candidate: 5.76 leaderboard mean / 1.63 LibriSpeech-clean at only 1.7B, Apache 2.0, context-biasing lineage, word timestamps via aligner, drops into the existing MLX Python sidecar. Do NOT route through llama.cpp for long audio.
2. **Granite Speech 4.1 2B via Transformers sidecar** — current open-source accuracy king (5.33% mean WER), Apache 2.0. Medium effort; no hotwords — evaluate purely as maximum-accuracy Deep Review engine.
3. **FluidAudio v0.15.5 Parakeet-unified upgrade + custom vocabulary** — lowest effort, guaranteed win: word-level timestamps, chunk-seam fix, per-term hotwords; consider Parakeet v2 (English, 6.05%) vs current model.

**Keep VibeVoice-ASR as canonical.** The realistic upside play is Qwen3-ASR as a challenger plus an LLM proofread pass, which Dictato's data suggests could roughly halve jargon errors on top of any engine.
