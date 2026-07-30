# Phase A Results — VibeVoice + Multimodal Audio Reviewer

**Test audio**: `141 W 54th St 3.m4a` (7m 36s, 2 speakers, 41 GT turns, 1264 ref words)
**Baseline**: VibeVoice 4-bit MLX with hotwords — 10.21% WER, 6.43% DER
**Hardware**: M2 Max, 96 GB RAM
**Date**: April 28 – May 1, 2026

## Architectural verdict (TL;DR)

After five rounds of architectural iteration, the **smart-editor architecture (v5)** is the right design. It:
- Treats VibeVoice's transcript as the canonical document.
- Sends transcript + full audio to a reasoning model.
- Asks for a list of targeted patches (`{segment, find, replace, evidence}`), not a new transcript.
- Applies only patches that pass the standard-of-proof gate (`find` must exist in segment, non-trivial diff, non-empty evidence, sensible length ratio).

This is **structurally clean** — no transcript merging, no segment alignment issues, no wholesale replacement bugs. The ONLY remaining variable is: which model can the editor be?

| Model used as editor | Corrupted WER | Δ corrupted | Injections caught | Clean transcript behavior |
|---|---:|---:|:---:|---|
| Voxtral Small 24B Q4 | **10.68%** | **−0.16** | **3/8** (Bernard Cohen, Tracy, meditation) | **HALLUCINATES** — proposed "Brant Kuehn" → "Bernard Cohen" reversal on a correct transcript; saved only by output truncation |
| Qwen2.5-Omni 7B Q8 | 10.84% | 0 | 0/8 | Returns `{"edits": []}` — doesn't engage |

## What previous architectures got wrong

For documentation completeness — five iterations were tested before arriving at v5:

| Architecture | Result | Why it failed |
|---|---|---|
| **v1 (strict prompt, per-segment)** | 0/8 detection | Prompt anchored on "presume correct" so strongly that models rubber-stamped every segment |
| **v2 (soft prompt, per-segment)** | 3/8 caught, 10.60% WER | Worked! But scope is per-segment review of *every* segment regardless of likelihood; expensive and doesn't scale |
| **v3.0–v3.2 (disagreement-driven, both candidates shown)** | 0/8 detection | Showing model both A and B candidates causes anchoring — model picks one of the candidates instead of transcribing fresh |
| **v3.3 (Voxtral as fresh ASR per disputed span)** | 83.15% WER (catastrophic) | Voxtral hallucinates per-span audio transcription; substituted random unrelated content into VibeVoice segments |
| **v4 (Voxtral Small judge picks A/B, with word-swap apply)** | 46.52% WER | Voxtral Small *does* catch real errors but transcribes the full ±5s clip; word-swap apply still pulls in neighboring content because Parakeet's segmentation differs from VibeVoice's — can't align cleanly |
| **v5 (smart editor — Voxtral Small Q4)** | **10.68% WER, 3/8 caught on corrupted; clean transcript: ALMOST broken by hallucinated reversal** | Architecture works; Q4 model isn't reliable enough |

## What v5 (smart editor) gets right structurally

1. **No transcript merging.** The model never sees Parakeet's text. It only sees VibeVoice's transcript and the audio. Edits target VibeVoice's segments by index and string-match.

2. **Atomic patches.** Each edit is `{segment, find, replace}`. The `find` string MUST exist in the segment. Replacement is a string-level swap. No segment is ever wholesale replaced.

3. **Default = no edit.** The prompt explicitly says "if you find no errors, return an empty edit list. That is a perfectly valid answer." Qwen Q8 took this default; Voxtral Small Q4 ignored it.

4. **Standard-of-proof gate at the apply layer**:
   - `find` string must exist in target segment (rejects model confusion)
   - Non-trivial diff (rejects punctuation/case/filler-only "corrections")
   - Length ratio of `replace`/`find` between 0.33 and 3.0 (rejects wholesale rewrites)
   - Non-empty evidence ≥12 chars (forces the model to articulate why)

5. **Audit log.** Every proposed edit is recorded with applied/rejected status and reason. Reviewable.

6. **Single-shot inference.** ~60s per full transcript with Voxtral Small. No per-segment overhead. Scales with transcript length, not segment count.

## What v5 demonstrates about Voxtral Small Q4

**On corrupted input**: caught the audibly-clear injections at the start of the audio (where the speaker introduces themselves with a name). Specifically:
- ✓ "Bernard Cohen" → "Brant Kuehn" (segment 1)
- ✓ "Tracy" → "Marie" (segment 2)
- ✓ "meditation" → "mediation" (segment 5)
- + 2 more edits (one possibly real VibeVoice error, one possibly hallucinated)
- Missed: Florida counsel, 10%, AAA, different attorney, lunch (deeper in the audio, less obvious)

**On clean input**: HALLUCINATED a reversal — proposed swapping "Brant Kuehn" (correct) with "Bernard Cohen" (the corruption from the OTHER run). This is a serious unreliability signal. The model is not consistent; its output depends on something other than the actual audio content.

**The Q4 quantization is likely the culprit.** Voxtral Small at full precision or Q8 may not have this issue. Worth verifying before declaring the architecture viable for production.

## Recommended next steps

1. **Test Voxtral Small at Q8** (≈25 GB on disk, ~30 GB peak RAM — within budget on the 96 GB M2 Max). If it doesn't hallucinate the reversal on clean input, the architecture is shippable.

2. **Test Step-Audio-R1.1 33B** if it gets a GGUF release. It's purpose-built for audio reasoning with `<think>` blocks; should outperform Voxtral on this task.

3. **For the immediate Consensus product**: ship v2 (Qwen Q8 per-segment soft-prompt review) as the validated Deep Review architecture. It hits 10.60% WER on corrupted with 3/8 detection and zero false positives on clean. The numbers aren't dramatically better than v5, but it's the only configuration that's been verified to NOT introduce errors on clean input.

4. **For the longer term**: implement v5 in production with whichever larger / higher-precision audio reasoning model is available. The architecture is correct; we're just waiting for a reliable enough model to drive it.

## Files

Sidecars:
- `run_phase_a.py` — v2 per-segment review (Qwen Q8 / soft prompt) — **current baseline**
- `find_disagreements.py` — timestamp-aligned disagreement detector (still useful as a hint generator for v5)
- `run_disagreement_review.py` — v3/v4 disagreement-driven attempts (kept for reference)
- `apply_word_swaps.py` — v4 word-swap apply experiment (deprecated)
- `run_smart_editor.py` — **v5 smart editor (recommended architecture)**

Test artifacts:
- `vibevoice_corrupted.json` — corrupted baseline with 8 injected errors
- `injection_manifest.json` — manifest of injections for scoring
- `disagreements.json`, `disagreements_corrupted.json` — differ outputs
- `phase_a_v5_corrupted.json`, `phase_a_v5_clean.json` — smart editor outputs (Voxtral Small Q4)
- `phase_a_v5_audit.json`, `phase_a_v5_clean_audit.json`, `phase_a_v5_qwen_audit.json` — per-run audit logs
- 15 unit tests in `test_decision.py` for the standard-of-proof primitives — all pass

## Cost analysis

| Architecture | Wall clock per 7.6m audio | s/min |
|---|---:|---:|
| v2 (Qwen Q8, per-segment) | 216s | 28 |
| v4 (Voxtral Small, disagreement-driven) | 695s | 91 |
| v5 (Voxtral Small Q4, smart editor) | **61s** | **8** |

v5 is **3.5× faster than v2** because it's one inference call instead of 51. With Voxtral Small Q8 on the same architecture, expect ~120-180s (still under the 30 s/min budget).

---

## Architectural lesson (for the next session and for the product)

> The job is NOT to merge two transcripts. It is NOT to pick between candidate transcripts per segment. The job is to use the reasoning model as a smart editor: read the canonical transcript, listen to the audio, and propose targeted patches. VibeVoice's transcript is the canonical document. The editor only adjusts it where the audio gives clear evidence of an error. The optional second ASR is a heatmap of "spots worth listening to," nothing more — never a candidate to be merged.

Anything else cascades into segment alignment issues and over-correction.

## May 1 continuation — baseline reproduced before new tests

Current session reproduced the Phase A baseline before changing the method:
- Corrupted VibeVoice baseline: **10.84% WER**, **6.43% DER**.
- v5 Voxtral Small Q4 smart editor: **10.68% WER**, **6.43% DER**, 5 patches applied from 7 proposed, catching 3 of the 8 injected corruptions.
- Clean VibeVoice baseline and v5 clean output both scored **10.21% WER**, but the v5 clean audit still contained the dangerous hallucinated `"Brant Kuehn" -> "Bernard Cohen"` proposal and was safe only because the JSON parse failed.
- The next experiments should therefore test a stricter evidence architecture, not just a stronger prompt. Q8 was started as a model-quality check, but the immediate work shifted to a candidate-patch method that limits what the editor is allowed to change.

## May 1 final update — v6/v7 tool-editor architecture

The best result from this session is **not** the full-transcript v5 smart editor. It is a narrower two-tool architecture:

1. **v6 local re-listen editor** (`run_local_relisten_editor.py`): use the second ASR disagreement file only as a heatmap, re-run VibeVoice on each flagged local segment, and apply only small token-level replacements. This catches artificial corruptions without trusting a free-form reasoning model to author edits.
2. **v7 patch verifier** (`run_patch_verifier.py`): generate small candidate replacements from WhisperKit vs VibeVoice, protect hotwords/domain terms, then ask Voxtral Small to verify each exact patch against the local audio. The model can only answer keep/apply; it cannot invent a new correction or rewrite a segment.

### Results table

| Variant | Clean WER | Corrupted WER | Edits on clean | Injected errors repaired | Notes |
|---|---:|---:|---:|---:|---|
| VibeVoice baseline | **10.21%** | 10.84% | — | — | Lead transcript with hotwords |
| v5 smart editor, Voxtral Small Q4 | 10.21% only because parse failed | 10.68% | raw hallucination | 3/8 | Proposed `"Brant Kuehn" -> "Bernard Cohen"` on clean |
| v5 smart editor, Voxtral Small Q8 | **10.36%** | not run after clean failure | 1 bad applied edit | n/a | Q8 did **not** fix the hallucination; it applied `"Brant Kuehn" -> "Bernard Cohen"` |
| v6 local re-listen editor | **10.21%** | **10.21%** | 0 | **8/8** | Safe corruption-repair layer; 136s generation for 49 segments |
| v7 patch verifier, Voxtral Small Q4 | **9.89%** | n/a | 2 | n/a | Applied `seeing -> thinking` and `Oh, gosh -> That was fast`; rejected `that's it -> that said` |
| v7 patch verifier, Voxtral Small Q8 | 9.97% | n/a | 1 | n/a | Q8 missed `seeing -> thinking`; Q4 was better as the constrained verifier |
| **v6 + v7 combined** | n/a | **9.89%** | n/a | **8/8** | Repairs all injected corruptions, then applies the two verified real corrections |
| **v8 masked-cloze verifier, protected terms** | **9.73%** | n/a | 3 | n/a | Masks disputed phrase before verification; applied `seeing -> thinking`, `that's it -> that said`, `Oh, gosh -> That was fast` |
| **v6 + v8 combined** | n/a | **9.73%** | n/a | **8/8** | Repairs all injected corruptions, then applies the three masked-cloze real corrections |

### Architectural verdict

The unconstrained v5 smart-editor architecture should **not** ship with Voxtral Small, even at Q8. The Q8 clean test failed the most important reliability check: it applied a hallucinated proper-name reversal on an already-correct transcript.

The promising architecture is a **tool-constrained editor**:

```
VibeVoice canonical transcript
  + second ASR disagreement heatmap
  -> v6 local VibeVoice re-listen patches for flagged spans
  -> v7 second-opinion candidate patches
  -> audio verifier can only keep/apply exact patch
  -> deterministic string patch gate
```

This matches the "human editor with tools" mental model better than v5. The editor is not asked to write corrections from scratch. It is shown a tiny, concrete patch and the audio needed to verify that patch.

### May 1 creative follow-up — the missing trick

The extra step that improved the architecture was **masked cloze verification**. v7 still showed the model a segment containing VibeVoice's disputed phrase, then asked whether to replace it. That leaves the model anchored to whichever phrase is already written in the transcript.

v8 changes the cognitive task:

```
Current v7:
  Segment says "... what she's seeing about the numbers ..."
  Proposed patch: seeing -> thinking
  Should we apply?

New v8:
  Segment says "... what she's ____ about the numbers ..."
  Allowed fills: ["seeing", "thinking"]
  Which fill is spoken in the audio?
```

That one representation change let Voxtral Small Q4 catch the patch v7 missed:

- `seeing -> thinking`
- `that's it -> that said`
- `Oh, gosh -> That was fast`

Unprotected masked cloze also demonstrated the risk: it accepted phonetically plausible but wrong regressions such as `Brant Kuehn -> Brankine` and `Marie -> Maria`. Therefore the production rule is: **masked cloze + protected user/domain vocabulary**. User-provided names, speaker names, organizations, legal terms, and hotwords should be hard protected unless the candidate moves *toward* the protected term.

### What still does not meet the original target

The best WER so far is **9.73%**, not the earlier target of sub-7%. That means the method is directionally right but not "solved" for production-quality Deep Review yet. The limiting factor now appears to be candidate evidence: WhisperKit supplies a few real corrections, but many remaining VibeVoice errors are filler/segmentation/timing artifacts, or places where the available second opinions are also wrong or ambiguous.

### Production implications

- Do **not** ship v5 full-transcript patch authoring with Voxtral Small Q4 or Q8.
- Promote v6 as the safer corruption/regression guard: it proved zero clean edits and 8/8 injected-error repair on the gold sample.
- Use v8 masked cloze as the preferred second-opinion verifier. It improved clean WER to 9.73% with three verified substantive patches.
- The user context/hotword box should become a protected-term list for the verifier. Proper names and domain terms must be hard-vetoed unless the patch moves *toward* the protected term.
- Next benchmark need: at least 2-3 more human-revised transcripts. One gold call is enough to identify failure modes, but not enough to calibrate thresholds for shipping.
