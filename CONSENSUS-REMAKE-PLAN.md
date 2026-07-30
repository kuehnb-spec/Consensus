# Consensus Remake Plan — July 2026

**Started:** July 10, 2026
**Mission:** Push Consensus across the finish line into a polished, distributable app. Two goals: (A) measurably improve transcription/diarization accuracy, (B) rebuild the UI around three clean modes.
**Supersedes:** `UI-OVERHAUL-PLAN.md` (all phases complete as of March 16, 2026 — kept as historical record) and the Phase A handoff (`Brainstorming/phase-a-vibevoice-nemotron/HANDOFF.md`).

---

## Where we stand (verified July 10, 2026)

The benchmark harness reproduces **exactly**. A fresh VibeVoice run today on the gold file (`141 W 54th St 3.m4a`, 7m36s, 2 speakers) scored **10.21% WER / 6.43% DER** — identical to April. The archived best pipeline (v6 local re-listen + v8 protected masked-cloze) re-scores at **9.73% WER**.

| Configuration | Verbatim WER | Style-normalized WER* | DER |
|---|---:|---:|---:|
| VibeVoice 4-bit + hotwords (baseline) | 10.21% | ~6.4% | 6.43% |
| v6 + v8 masked-cloze (Phase A best) | 9.73% | ~5.9% | 6.43% |

*Style-normalized = fillers (um/uh/mhm) removed, spoken-form equivalences unified (gonna/going to, Ms/Miss, 100/hundred). Crude normalizer; true content error is likely ~3–4%.

### Finding 1: A large share of measured WER is style mismatch, not misrecognition

The gold transcript is a *cleaned* human transcript; VibeVoice output is verbatim. Of ~131 errors in the baseline, **~49 insertions are pure fillers** ("uh" ×17, "um" ×13, "you know"…) that the human editor deliberately removed. Normalization mismatches (Ms/Miss ×4, 100/hundred, 'cause/because, gonna/going to, alright/all right) account for another chunk. Genuinely wrong words on this file: roughly 15–20 — and the v8 masked-cloze verifier already found and fixed exactly the right ones (`seeing→thinking`, `that's it→that said`, `oh gosh→that was fast`).

**Consequences:**
1. `score.py` needs a second scoring track: **content WER** (filler-insensitive, spoken-form-normalized, e.g. Whisper's EnglishTextNormalizer) reported alongside verbatim WER. Otherwise we optimize against noise.
2. The app's existing Clean/Verbatim style toggle is the right product answer — the "clean" rendering should be scored against cleaned gold, verbatim against verbatim gold.
3. The gold transcript itself has at least one typo (`afer` → `after`) — needs a correction pass.

### Finding 2: The Voxtral verifier assets are gone from disk

`Brainstorming/phase-a-vibevoice-nemotron/voxtral-small/` contains only logs — the 13GB Q4 GGUF was deleted (matching the June 30 "missing verifier assets" alert). v8 masked-cloze cannot re-run until a verifier model is downloaded. Given the research below, we should **not** re-download Voxtral reflexively — the verifier bake-off should decide what earns those gigabytes.

### Finding 3: The app ships two UI generations

`useRewrittenUI` defaults to `true`; the rewritten Deep Read surface (`App/Views/`, 13 files) is the real app. The legacy surface (`Views/`, ~20 files incl. ReconciliationView, QualityView, TranscriptionSetupView) still compiles behind the flag. This duality is the main source of the "clanky, doesn't fit together" feel.

---

## Goal A — Accuracy (benchmark-gated, iterative)

Everything below gets measured on the gold file before it earns a place in the app. Target: **content WER under 3%, DER under 4%** on the gold file, verified on at least three gold fixtures.

### A1. Scoring upgrade (prerequisite for everything)
- Add content-WER track to `Scripts/benchmark/score.py` (filler removal + spoken-form normalization + number normalization).
- Fix `afer` typo (and audit for others) in the gold transcript.
- Unify the two score.py variants (Scripts/benchmark vs vibevoice-test symlink) into one canonical scorer.

### A2. Gold fixture expansion
One file cannot calibrate thresholds. Draft ground truth for 2–3 more TestAudio files (Brant spot-checks): ideally one long file (the 36-min Maralan recording — also exercises long-form reliability), one 3-speaker file, one noisy/hard file.

### A3. Engine research verdict (July 2026 landscape — completed July 10)

**Canonical ASR: keep VibeVoice-ASR.** Still current (no release since Jan 21, 2026), still the only open model doing 60-min single-pass transcription + diarization + hotwords in one shot. MIT license. Its 60-min/64K-token ceiling is a known failure class — guard by duration *and* token estimate (June 30 fix was the right shape).

**Second-opinion ASR bench — three candidates to benchmark:**
1. **Qwen3-ASR-1.7B + ForcedAligner-0.6B** (Apache 2.0) — 5.76 Open-ASR-Leaderboard mean at only 1.7B; MLX port exists; word timestamps via aligner. The project already vendors speech-swift's Qwen3ASR in script targets and has the 0.6B models cached — extend to 1.7B. Avoid the llama.cpp path (long-audio bug #21847 unresolved in practice).
2. **IBM Granite Speech 4.1 2B** (Apache 2.0, Apr 30, 2026) — new Open ASR Leaderboard #1 (5.33% mean), strong on noisy/meeting audio. Transformers-on-MPS sidecar; no hotwords; evaluate as max-accuracy second opinion.
3. **FluidAudio upgrade to v0.15.5** (lowest effort, guaranteed win) — the vendored copy predates the July 7 release: unified Parakeet backend, word-level timestamps, per-term custom-vocabulary hotwords, and a chunk-seam fix that directly improves long-form output.

**Verifier (Deep Review masked-cloze role) — bake-off of three, all Apache 2.0:**
1. **Qwen3-Omni-30B-A3B Instruct** (official ggml-org GGUF, Q4 ~20GB) — open-weights SOTA audio understanding (MMAU 77.5). Risk: Qwen-family conservatism (Qwen2.5-Omni 7B refused to edit); test Instruct before Thinking (Instruct scores higher on MMAU).
2. **Gemma 4 12B audio** (Q8 ~13GB) — newly Apache 2.0; 30-second audio cap is an exact fit for the cloze window; cheap enough to run as a **second verifier vote alongside the primary** — verifier-level consensus, the app's own thesis applied to its referee.
3. **Voxtral Small 24B Q4** (incumbent) — no successor released; proven in the constrained role; re-download only if it wins a seat.
- **Watch list:** Step-Audio-R1.1 (purpose-built audio reasoning, still vLLM-only — adopt the day a llama.cpp port lands); Fun-Audio-Chat-8B (MMAU 76.6 at 8B, no GGUF yet).
- Literature now validates the masked-cloze design (cloze-style GER prompting, dual-hypotheses correction, three-stage verify frameworks — see arXiv 2512.14083, 2510.13281, HalluAudio ACL 2026). HalluAudio's methodology (yes/no bias, refusal rate) is the right template for the verifier bake-off eval.

**Diarization — three moves, in order of effort:**
1. **Upgrade vendored FluidAudio (0.5.x-era snapshot) to upstream v0.15.5** — upstream now ships the **pyannote community-1 pipeline on CoreML** (powerset segmentation + WeSpeaker + VBx clustering): 10.6% DER on AMI-SDM at 323× real-time vs ~22% for the old pipeline generation. Bonus: deterministic re-clustering, an **"exclusive" single-speaker mode purpose-built for word→speaker assignment during STT reconciliation**, and **per-chunk speaker embeddings exposed in `DiarizationResult`** — which gives the Voice Library its embedding source for free. Licensing distribution-safe (CC-BY-4.0 models / Apache-2.0 SDK). This one upgrade serves ASR (A3.3), diarization, and Voice Library simultaneously.
2. **Score VibeVoice's native speaker tags as a second diarization opinion — zero new dependencies.** The sidecar already emits per-segment `Speaker` labels and Swift already parses them; they're unused for consensus today. Benchmark the VibeVoice speaker track's DER on the gold file, then treat FluidAudio-vs-VibeVoice speaker disagreement exactly like ASR disagreement (DOVER-Lap-style fusion is the established method — 30–40% DER reduction in ensembles). *Diarization-level consensus is the app's thesis applied to speakers, and it's already wired.*
3. **DiariZen-Large-s80-v2 as accuracy ceiling** (best open DER anywhere; WavLM-based so decorrelated from both pyannote and VibeVoice) — but weights are **CC BY-NC** (non-commercial), so benchmark-only unless relicensed. Shippable alternate third engine if wanted: Streaming Sortformer v2.1 (validate on phone-call audio specifically).
- Apple's SpeechAnalyzer (macOS 26) still has no speaker support — nothing to wait for there.
- **Voice Library embeddings:** start with the WeSpeaker embeddings FluidAudio v0.15.x already computes (zero extra inference); escalate to CAM++-CoreML or ReDimNet2-B6 (0.26% EER, MIT) only if cross-recording matching underperforms.

### A4. Benchmark sequence
1. A1 scoring upgrade → re-baseline everything with both WER tracks.
2. FluidAudio upgrade to v0.15.5 (community-1 diarizer + Parakeet-unified ASR + embeddings) → re-run second opinion + DER (cheap, and the single highest-leverage dependency bump).
3. Score VibeVoice's native speaker track DER (zero-cost second diarization opinion) → if competitive, wire speaker-level disagreement into the reconciliation pipeline.
4. Qwen3-ASR-1.7B via MLX → score standalone; if strong, promote to second-opinion engine in the patch pipeline.
5. Verifier bake-off: download Qwen3-Omni-30B-A3B Q4 (~20GB) + Gemma 4 12B Q8 (~13GB); re-run v8 masked-cloze protocol (clean-transcript no-edit test + corrupted-transcript 8-injection test) per model; also test two-verifier voting. (Disk: 202GB free as of July 10 — fine.)
6. Granite Speech 4.1 sidecar (only if 4–5 leave accuracy on the table).
7. DiariZen benchmark run (non-commercial license — ceiling measurement only).
8. Long-form validation on the Maralan 36-min fixture once its gold exists.

Full research reports with citations: `Brainstorming/2026-07-research/` (ASR, Diarization, Verifier — three files).

Decision gates as in Phase A: a verifier must propose **zero edits on clean input** and catch **≥6/8 injections** to ship; ties broken by content WER.

### A5. The AI editor — how far do we push local reasoning? (added July 10 per Brant)

Brant's framing: we now have real thinking available locally; don't waste it. Proposed expansion of the audio-LLM's role from "masked-cloze referee" to a three-job **AI editor**, in increasing order of freedom:

1. **Adjudicate disputed spans** (exists — v8 masked-cloze). Audio + two candidates + blank to fill. Tightest constraint, proven safe.
2. **Semantic plausibility scan** (new, cheap): a *text-only* LLM pass over the finished transcript flagging spans that don't make sense in context — "meditation" in an arbitration call, a reply that answers a different question, legal terms that don't exist. No audio needed, so any strong local text model works; output is *flags routed into the existing patch pipeline* (each flag becomes a masked-cloze verification), never direct edits. This also catches errors both ASR engines agree on — the blind spot of disagreement-driven review. (Independent support: Dictato's 2026 benchmark found an LLM proofread pass roughly halves jargon-term WER.)
3. **Diarization sanity check** (new): feed the LLM the transcript with speaker labels and ask "where does attribution not make conversational sense?" — a speaker answering their own question, an interjection ("Gotcha," "Mm-hmm") buried inside another speaker's long turn, a mid-sentence voice change. Flags route to targeted re-diarization of that window (re-listen with FluidAudio on the local span, or masked speaker-cloze: "which of the named speakers said this line?"). Today's Clayton Everett draft run produced a textbook case: a 115-second mega-turn with the other party's "Gotcha." swallowed mid-stream.

**The hard-won guardrail (Phase A, v5 failure):** free-form "smart editor" LLM passes hallucinate — Voxtral rewrote a *correct* name on a clean transcript. So every expanded role follows the same constitution: **the LLM proposes, deterministic gates + audio evidence dispose.** Reasoning output is always a *flag* or a *choice between presented candidates*, never an unmediated rewrite. This also feeds Studio mode: every flag, verification, and verdict is exactly the auditable "Review Trace" content the observability cockpit wants to display.

---

## Goal B — UI (consolidate, then elevate)

### B1. Consolidation (prerequisite)
- Inventory legacy-only features worth porting (candidates: DisagreementHeatmapView, CircularProgressGauge, reconciliation keyboard model, help/welcome tours).
- Delete the legacy surface (~20 views) + `useRewrittenUI` flag; single skeleton.
- `swift build` clean; screenshot audit of every remaining screen.

### B2. Three modes, deliberately tiered
- **Quick Take** — drop audio, one button, at most 2–3 options (speaker count hint, clean/verbatim). Zero jargon. Must never show a scary degraded-mode alert (June 30 decision stands: absent verifier assets → polished Standard result, quietly).
- **Deep Read** (middle tier, current default) — polished version of today's flow: setup → progress → speaker naming → review with patch audit → export.
- **Studio** — the observability cockpit (backlogged concept in UI-OVERHAUL-PLAN.md): live engine telemetry (tokens/sec, RTF, stage timings), patch-review trace with evidence cards, disagreement timeline, process/memory health. Read-only, joy-oriented, auditable-evidence framing ("Review Trace," not chain-of-thought).

### B3. Visual identity
Post-consolidation: custom display font(s), tightened ConsensusTheme, app icon refresh — per standing design direction (no emojis, identity tied to function: *consensus being forged* is the visual metaphor).

---

## Priority shift — July 25, 2026

Brant reprioritized: **freeze the engine as-is**; the work is now (1) UI revamp and (2) a headless/CLI mode so captured audio can be automated on the Mac Studio. Goal A's benchmark sequence (content-WER scorer, FluidAudio upgrade, verifier bake-off) is **paused, not cancelled** — the research and the fixture drafts stay valid for when accuracy work resumes.

**Goal C — Headless CLI** (new, from `10-consensus-spec.md`): a single-shot, idempotent `consensus transcribe` binary that a watch-folder job can call unattended, feeding the larger PADD pipeline (recorder → iCloud → watcher → Consensus → LLM post-pass → Obsidian → Telegram). Consensus owns only the transcription step. **Status: built and verified July 25** — see `CLI.md` and the implementation-status section of the spec. Remaining gaps: 2-hour audio needs internal chunking (VibeVoice caps at 60 min), config file unimplemented, hosted `--engine` adapters rejected rather than supported.

## Sequencing

1. **Session 1 (this one):** baseline verified, research complete, this plan written.
2. **Next:** A1 scoring upgrade + A2 first extra gold fixture + FluidAudio upgrade (A4.2).
3. **Then:** verifier bake-off (A4.4) — the biggest expected accuracy win.
4. **Then:** UI consolidation (B1) once the engine lineup is settled (Studio telemetry should be built against the final pipeline).
5. **Then:** three-mode build-out (B2), visual identity (B3), distribution prep (signing, notarization, first-run model-download experience).

## Open questions — RESOLVED July 10, 2026
- ~~Gold fixtures~~ → **Yes.** Drafts for Maralan + Clayton Everett in progress (multi-engine, disagreement-flagged review docs).
- ~~Distribution target~~ → **Direct download.** No App Store sandbox constraints; plan for notarized DMG + Sparkle-style updates; model downloads can go wherever we like (support NAS-relocatable model storage as a nice-to-have).
- ~~Disk budget~~ → **~33GB approved** for the verifier bake-off downloads; models are deletable/NAS-movable afterward.
