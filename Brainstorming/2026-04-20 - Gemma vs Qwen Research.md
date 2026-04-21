# Gemma vs Qwen Research

**Date:** April 20, 2026
**Context:** Should Consensus swap Qwen 3 (4B/8B, 4-bit MLX) for Gemma? Workloads: transcript cleanup, ACTION/KEY summarization, speaker-boundary JSON batch confirmation, diarization arbitration.

## TL;DR

**Worth trying.** Gemma 4 shipped April 2, 2026 under **Apache 2.0** (license parity with Qwen for the first time), has official MLX 4-bit quants on HF, and E4B (4.5B effective) matches Qwen 3 4B. Gemma 4 is competitive-to-leading in the dense ~30B class; at 2B/4B tier **Qwen 3.5 still wins more benchmark rows**, which matters since we run 4B on-device. Biggest risk: **structured JSON reliability with thinking disabled** — ollama issue #15260 shows `think=false` silently drops the `format` constraint on Gemma 4, which mirrors our `/no_think` Qwen workaround and could regress boundary/arbitration tasks. **Plan: A/B the E4B model on cleanup + summarization first, where thinking-off isn't critical.**

## 1. Current Gemma Release Status

| Family | Released | Sizes | Context | License |
|---|---|---|---|---|
| Gemma 3 | Mar 12, 2025 | 270M, 1B, 4B, 12B, 27B | 128K | Custom Gemma TOU |
| Gemma 3n | 2025 | E2B, E4B (edge) | 128K | Custom Gemma TOU |
| **Gemma 4** | **Apr 2, 2026** | **E2B (2.3B eff.), E4B (4.5B eff.), 26B A4B MoE, 31B dense** | **128K (edge) / 256K (26B+31B)** | **Apache 2.0** |

Multimodal (image for 26B/31B, audio for E2B/E4B), trained from the Gemini 3 stack. First Gemma family under a standard permissive license — prior Gemmas used Google's custom Gemma TOU.

## 2. MLX Port Availability

Official MLX 4-bit quants exist. Confirmed repo names as of this writing:

| Model | HF Repo | Notes |
|---|---|---|
| Gemma 4 E2B IT | `mlx-community/gemma-4-e2b-it-OptiQ-4bit` | ~1B on-disk size tier |
| Gemma 4 E4B IT | `mlx-community/gemma-4-e4b-it-OptiQ-4bit` | ~8B on-disk, direct Qwen-3-4B replacement |
| Gemma 4 E4B IT | `unsloth/gemma-4-E4B-it-UD-MLX-4bit` | Alternative Unsloth-packaged variant |
| Gemma 4 26B A4B IT | `mlx-community/gemma-4-26b-a4b-it-4bit` | MoE, 4B activated |
| Gemma 3 QAT variants | `mlx-community/gemma-3-{1b,4b,27b}-it-qat-4bit` | QAT preserves near-fp16 quality at 3× less memory |

**Compatibility caveat:** Gemma 4 MLX support currently routes through `mlx-vlm` rather than `mlx-lm`. For a text-only Swift app on **mlx-swift-lm v2.30.x**, the Swift bindings may or may not yet carry the updated Gemma 4 tokenizer/chat-template. **Verify release notes or test a load before committing.** Gemma 3 QAT variants are safer on current mlx-swift-lm but are prior-gen.

## 3. Head-to-Head Benchmarks

Official Gemma 4 numbers (from Google model card):

| Benchmark | E2B | **E4B** | 26B A4B | 31B |
|---|---|---|---|---|
| MMLU Pro | 60.0 | **69.4** | 82.6 | 85.2 |
| AIME 2026 (no tools) | 37.5 | **42.5** | 88.3 | 89.2 |
| GPQA Diamond | 43.4 | **58.6** | 82.3 | 84.3 |
| BigBench Extra Hard | 21.9 | **33.1** | 64.8 | 74.4 |
| MRCR v2 (128K, 8 needles) | 19.1 | **25.4** | 44.1 | 66.4 |

**Vs Qwen 3/3.5:**
- 2B/4B: aggregators give **Qwen 3.5 4B the edge on more rows** than Gemma 4 E4B, especially instruction-following.
- Dense 30B+: Gemma 4 31B ranks #3 on Arena AI (1452 Elo), beating comparable Qwen 3.5 dense in preference.
- **Long context (MRCR, 128K): E4B only 25.4%** — weak. Fine for 16K transcripts, degrades past that. Qwen 3 4B has similar long-context weakness, so this is a wash at 4B.

**Source caveat:** Primary-source Qwen IFEval numbers not verified in this pass; most side-by-sides are blog aggregators. Cross-check the Qwen 3 arXiv paper before treating any head-to-head as authoritative.

## 4. Task-by-Task Behavior

| Task | Gemma better? | Rationale |
|---|---|---|
| **Cleanup/polish** | Maybe | Gemma historically strong on natural English prose; Qwen is Chinese-first and sometimes introduces odd constructions. Low-risk swap. |
| **Summarization** | Comparable | Both handle structured headers at 4B. E4B's 128K covers any reasonable transcript. |
| **Boundary confirm (JSON batch)** | **Risk** | Gemma 4 has a thinking mode toggled via `enable_thinking=True` — same category as Qwen. Ollama #15260 confirms `think=false` **silently breaks `format` (structured JSON)** on Gemma 4. Validate `enable_thinking=False` on HF/MLX path before trusting it, or replicate `/no_think` via chat template. |
| **Diarization arbitration** | Comparable | Single-region decision, not JSON-heavy. Either works. |

**Thinking-mode analog:** Controlled via `enable_thinking` kwarg in the chat template, not Qwen's `/no_think` string token. Behavior change to port, not just a model swap.

## 5. License Comparison

| Term | Qwen 3 | Gemma 4 |
|---|---|---|
| License | Apache 2.0 | **Apache 2.0** (new as of G4) |
| Commercial on-device app | Yes | Yes |
| Redistribution of weights | Yes, with attribution | Yes, with attribution |
| Use restrictions | None | None |
| Attribution requirement | Apache NOTICE | Apache NOTICE + recommended "Built with Gemma" credit |

**Net:** For Consensus (commercial macOS app, model bundled or downloaded, on-device), **Gemma 4 and Qwen 3 are license-equivalent.** Biggest change from Gemma 3 — the old TOU had a usage-restrictions appendix needing legal review; Apache 2.0 does not.

## 6. Apple Silicon Performance

Reported tok/s for Gemma 4 E4B 4-bit on Apple Silicon:

| Runtime | tok/s | RAM |
|---|---|---|
| Unsloth MLX | 49 | 5.6 GB |
| Ollama (GGUF) | 57 | higher |
| MLX on M3 Max | 71 | — |
| 16 GB Mac target | 40–60 | — |

Multiple reports note **GGUF/Ollama outpaces MLX by ~15–20%** on Gemma 4 specifically, though MLX uses ~40% less memory. Qwen 3 4B on MLX lands in a similar 50–80 tok/s band. No decisive perf win at 4B.

## Recommendation

1. **Low-risk test:** Swap in `mlx-community/gemma-4-e4b-it-OptiQ-4bit` for **cleanup + summarization only** — no thinking-off or strict JSON required. Prose quality delta will be obvious immediately.
2. **Before swapping boundary/arbitration:** verify mlx-swift-lm can load the Gemma 4 tokenizer/chat template, and verify `enable_thinking=False` does not regress structured JSON (mirror ollama #15260 as a known failure mode).
3. **Do not extrapolate from 31B numbers** — they don't apply to 4B on-device.
4. **Keep Qwen 3 as fallback** through at least one full Deep Review pass worth of eval on real transcripts.

## Sources

- [Gemma 4 HF blog](https://huggingface.co/blog/gemma4) · [Model overview](https://ai.google.dev/gemma/docs/core) · [Apache 2.0 announcement](https://opensource.googleblog.com/2026/03/gemma-4-expanding-the-gemmaverse-with-apache-20.html) · [Prompt formatting](https://ai.google.dev/gemma/docs/core/prompt-formatting-gemma4)
- [Gemma 3 model card](https://ai.google.dev/gemma/docs/core/model_card_3) · [mlx-community on HF](https://huggingface.co/mlx-community)
- [Gemma 4 vs Qwen 3.5 by size — maniac.ai](https://www.maniac.ai/blog/qwen-3-5-vs-gemma-4-benchmarks-by-size)
- [ollama #15260 — think=false breaks structured output](https://github.com/ollama/ollama/issues/15260)
- [Gemma 4 on Apple Silicon — SudoAll](https://sudoall.com/gemma-4-31b-apple-silicon-local-guide/) · [GGUF vs MLX — The Agent Times](https://theagenttimes.com/articles/gguf-outpaces-mlx-for-gemma-4-on-apple-silicon-developers-re-ca3911a0)
