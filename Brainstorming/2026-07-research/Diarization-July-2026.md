# Local Speaker Diarization on Apple Silicon — State of the Art, July 2026

*Research report generated July 10, 2026 (Claude web-research agent) for the Consensus remake. Companion reports: `ASR-Engines-July-2026.md`, `Verifier-Models-July-2026.md`. Synthesis in `/CONSENSUS-REMAKE-PLAN.md`.*

Current baseline: FluidAudio (pyannote-style CoreML pipeline), 6.43% DER on the gold file (7m36s, 2–3 speakers, phone-call-style legal/business audio).

Two findings change the picture materially: **(a)** the vendored FluidAudio copy in the repo is a pre-community-1 snapshot (CITATION.cff says 0.5.1) while upstream is at v0.15.5, and **(b)** the app *already receives* speaker-attributed output from VibeVoice-ASR (`VibeVoiceTranscriptionService.swift` parses `speaker_id` per segment) — a second diarization opinion is already flowing through the pipeline, apparently unused for consensus.

---

## 1. What's new since April 2026

### pyannote 4.0 / community-1 / Precision-2
- **pyannote.audio 4.0** shipped with **`speaker-diarization-community-1`**, successor to 3.1 — new segmentation + WeSpeaker embeddings + **VBx clustering**, markedly better speaker counting/assignment, and a new **"exclusive" single-speaker mode designed specifically for reconciling diarization with STT timestamps** ([pyannote blog](https://www.pyannote.ai/blog/community-1), [GitHub](https://github.com/pyannote/pyannote-audio)).
- **License: CC-BY-4.0** — permits commercial redistribution with attribution (HF repo is click-gated for contact info only) ([HF model card](https://huggingface.co/pyannote/speaker-diarization-community-1)).
- Community-1 DER (pyannote's own bench, no collar): AISHELL-4 11.7, AliMeeting 20.3, AMI-IHM 17.0, DIHARD3 20.2, VoxConverse 11.2.
- **Precision-2** (+28% over OSS 3.1) is API-only cloud — irrelevant for a privacy-first local app; useful as an accuracy ceiling reference.

### FluidAudio (current vendor) — upstream has moved a lot
- Upstream at **v0.15.5 (July 7, 2026)**; now ships the **pyannote Community-1 pipeline on CoreML** (powerset segmentation + WeSpeaker + VBx) as its recommended offline diarizer ([README](https://github.com/FluidInference/FluidAudio), [releases](https://github.com/FluidInference/FluidAudio/releases)).
- Their benchmark: **10.6% DER on AMI-SDM at 323× real-time** (July 3, 2026) — versus ~22.4% for pyannote 3.1-era pipeline on the same set ([Benchmarks.md](https://github.com/FluidInference/FluidAudio/blob/main/Documentation/Benchmarks.md)).
- CoreML conversion costs ~1% DER/JER vs PyTorch original; models hosted ungated, CC-BY-4.0 (models) / Apache-2.0 (SDK) ([FluidInference/speaker-diarization-coreml](https://huggingface.co/FluidInference/speaker-diarization-coreml)).
- Also new upstream: **Streaming Sortformer CoreML**, **LS-EEND streaming diarization** (20.7% AMI-SDM), deterministic VBx re-clustering, **speaker embeddings exposed per chunk in `DiarizationResult`**, plus June 2026 PRs adding **CAM++ embedding** and FSMN-VAD CoreML backends.

### NVIDIA Streaming Sortformer v2 / v2.1
- End-to-end streaming diarizer (117M params, up to **4 speakers max**) ([HF card](https://huggingface.co/nvidia/diar_streaming_sortformer_4spk-v2.1), [paper](https://arxiv.org/pdf/2507.18446)).
- DER (1.04s latency): **CALLHOME 2-spk 6.65%, 3-spk 11.25%**, DIHARD3 15.09%, AMI-IHM 16.67% — on telephone-style 2-speaker audio competitive with the current 6.43%, but its value is real-time, not offline accuracy. NVIDIA Open Model License.
- Caution: FluidAudio's CoreML port measured **31.7% DER on AMI-SDM** — the CoreML port currently underperforms badly on meeting audio; treat as real-time-mode-only.

### DiariZen (BUT) — open-source accuracy leader
- WavLM-Large (structurally pruned) + Conformer + powerset + VBx. **DiariZen-Large-s80-v2 (Dec 2025): AMI-SDM 13.9, AliMeeting-far 10.8, NOTSOFAR-1 16.7, MSDWild 15.8 (no collar)** — best open numbers across benchmarks ([GitHub](https://github.com/BUTSpeechFIT/DiariZen), [tutorial paper](https://arxiv.org/abs/2604.21507)).
- **Critical catch: code is MIT, but pretrained models are CC BY-NC 4.0 — non-commercial only.** Blocker for public distribution unless BUT relicenses.
- Runtime: PyTorch (CUDA-targeted; would run via Python sidecar on MPS/CPU).

### Senko / 3D-Speaker
- **Senko** (MIT): optimized 3D-Speaker pipeline — pyannote segmentation-3.0 or Silero VAD + **CAM++ embeddings + spectral or UMAP+HDBSCAN clustering, VAD and embeddings via CoreML on Mac**. **1 hour of audio in 7.7s on an M3.** DER: VoxConverse 13.5, AISHELL-4 13.3, AMI-IHM 26.5 ([GitHub](https://github.com/narcotic-sh/senko)). Below community-1 on meetings; value is raw speed and a clean MIT clustering/embedding reference implementation (worth reading for Voice Library clustering).

### sherpa-onnx
- Mature offline diarization (pyannote segmentation-3.0 ONNX + 3D-Speaker/NeMo embeddings), CPU-only, Swift bindings — but still generation-3.0 pyannote; not a step forward.

### Apple SpeechAnalyzer (macOS 26)
- **Still no native speaker diarization.** SpeechTranscriber, DictationTranscriber, SpeechDetector (VAD) only; shipping multi-speaker apps pair it with FluidAudio or similar. No speaker support added at WWDC 2026.

---

## 2. Speaker-attributed ASR (single-pass "who said what")

Where the field moved most since April 2026 — and where Consensus has an unusual advantage: consensus across *independent attribution mechanisms*, not just independent ASR engines.

| Model | Developer / Date | What it does | License | Apple Silicon | Notes |
|---|---|---|---|---|---|
| **VibeVoice-ASR** (8B) | Microsoft, Jan 2026 | Joint ASR + diarization + timestamps, 60-min single pass | **MIT** | Already in the sidecar | **Already in the app** — per-segment `Speaker` labels parsed by Swift |
| **TagSpeech** (Qwen2.5-7B backbone) | AudenAI, Jan 2026 ([arXiv 2601.06896](https://arxiv.org/abs/2601.06896)) | E2E multi-speaker ASR + diarization + timestamps, SOT + interleaved time anchors | Apache-2.0 | PyTorch, 7B, ≤30s chunks | Domain-tuned checkpoints (AMI/AliMeeting) |
| **NeMo streaming multitalker ASR** | NVIDIA 2026 | Sortformer activity injected into ASR encoder | NVIDIA OML | CUDA-centric | Architecture to watch, not ship |
| **DiCoW** | BUT, Oct 2025 ([arXiv 2510.03723](https://arxiv.org/abs/2510.03723)) | Whisper conditioned on diarization masks | research | portable in principle | Bridges WhisperKit + diarization |
| **IBM Granite-Speech SAA** | IBM, ICASSP 2026 | Speech-LLM emitting speaker-cluster tags | paper only | no checkpoint | Validates the approach |
| **Qwen3-ASR** | Alibaba 2026 | ASR + timestamps — **no diarization** | open | MLX port exists | Additional ASR engine, not a diarizer |

**Takeaway:** single-pass speaker-attributed ASR is real now, but the strongest, lowest-effort instance is the VibeVoice-ASR sidecar already running. The two-stage pipeline doesn't need replacing — it needs a *competitor inside the consensus*.

## 3. Word-level attribution

- Dominant production pattern unchanged: word-timestamped ASR + segment-level diarization, assign each word by midpoint. WhisperX-style forced alignment gets word boundaries to <100ms at ~10–20% extra compute.
- **pyannote community-1's "exclusive" mode is purpose-built for this** — non-overlapping single-speaker regions specifically for unambiguous word→speaker assignment during STT reconciliation. Directly serves the word-level reconciliation engine.
- FluidAudio v0.15.4+ exposes **per-token timing** from its streaming ASR, easing word-level fusion on the Swift side.

## 4. Overlapped speech

- Community-1 and DiariZen use **powerset multi-class segmentation** (overlap-native at frame level).
- Sortformer/LS-EEND emit per-speaker sigmoid streams — simultaneous speakers natively representable.
- **DOVER-Lap** remains the standard for fusing multiple diarization hypotheses overlap-aware — 30–40% DER reduction over the best single system in ensembles ([overview](https://www.emergentmind.com/topics/overlap-aware-speaker-diarization)). This is the diarization analog of Consensus's whole thesis: FluidAudio community-1 + VibeVoice speaker track (+ optionally LS-EEND) fused DOVER-Lap-style.
- For phone-call audio, overlap is modest; the bigger win is boundary precision on interruptions.

## 5. Speaker embeddings for the Voice Library

| Model | EER (Vox1-O) | Size | License | Apple Silicon | Fit |
|---|---|---|---|---|---|
| **ReDimNet2-B6** ([PalabraAI, Mar 2026](https://github.com/PalabraAI/redimnet2)) | **0.26%** | 12.3M | **MIT** | PyTorch; CoreML-convertible | Best accuracy-per-param; conversion work needed |
| ReDimNet-b2/b3 ([IDRnD](https://github.com/IDRnD/redimnet)) | ~0.5–1% | 1–5M | open | PyTorch | Lighter fallback |
| **CAM++** (3D-Speaker) | ~0.65–0.73% | 7M | Apache-2.0 | **CoreML conversions exist** (Senko; June 2026 FluidAudio PR) | Lowest integration effort |
| ERes2NetV2 | 0.61% (strong at 2–3s clips) | ~17M | Apache-2.0 | PyTorch/ONNX | Best short-utterance robustness |
| WeSpeaker ResNet (inside community-1) | ~0.7–1% | — | Apache-2.0 | Already in FluidAudio CoreML bundle; **v0.15.x exposes embeddings per chunk** | **Free** — Voice Library can consume embeddings the diarizer already computes |

Practical answer: use the WeSpeaker embeddings FluidAudio already exposes for Voice Library v1 (zero extra inference); evaluate CAM++-CoreML or ReDimNet2 conversion if cross-recording matching proves insufficient.

---

## Top 3 recommendations to benchmark (against the 6.43% DER gold file)

**1. FluidAudio upstream v0.15.5 with the Community-1 CoreML pipeline — the drop-in upgrade.** The vendored snapshot predates the community-1 backend; upstream measures 10.6% DER on AMI-SDM at 323× RT vs ~22% for the old pipeline, plus deterministic VBx re-clustering, exclusive mode for STT reconciliation, and per-chunk speaker embeddings (Voice Library enabler). Same Swift API family → lowest integration cost; CC-BY-4.0/Apache-2.0 distribution-safe with attribution.

**2. VibeVoice-ASR's native speaker tags as a second diarization engine in the consensus — zero new dependencies.** The sidecar already emits per-segment `Speaker` labels; today they appear to serve only transcription. Score the VibeVoice speaker track's DER on the gold file, then treat FluidAudio-vs-VibeVoice speaker disagreement exactly like ASR disagreement — ideally fused DOVER-Lap-style. Cheapest possible test of whether joint speaker-attributed ASR beats or complements the two-stage pipeline.

**3. DiariZen-Large-s80-v2 via Python sidecar — as accuracy ceiling / tie-breaker, with a license asterisk.** Best open DER anywhere; WavLM-based so architecturally decorrelated from both pyannote and VibeVoice — exactly what a consensus tie-breaker wants. But **weights are CC BY-NC 4.0 (non-commercial)**: benchmark to know the ceiling and grade other engines; only ship if the distribution model can honor NC. Shippable alternate third engine: Streaming Sortformer v2.1 (CALLHOME 2-spk 6.65%, but validate on phone-call audio — its CoreML port is weak on meetings).

**Not recommended:** waiting on Apple (no speaker support in macOS 26); sherpa-onnx (older pyannote generation); Senko (fast but less accurate; MIT clustering code worth reading); TagSpeech (7B per 30s chunk — heavy for marginal gain over VibeVoice).
