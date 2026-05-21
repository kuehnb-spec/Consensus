# Handoff — Phase A v6/v7 tool-constrained editor

**Date drafted**: May 1, 2026
**Status**: v5 rejected; v6 + v8 masked cloze is the new best architecture
**Next concrete action**: productionize the v6/v8 harness into the app-side Deep Review experiment, then run it on at least 2-3 more human-revised transcripts before any shipping decision.

## May 1 app integration update

The productionization pass has started. The active app no longer treats v6/v8 as an optional experiment beside the old full-transcript reconciler:

- Added `TranscriboApp/Transcribo/App/Services/PatchReviewRunner.swift`.
- Added `TranscriboApp/Scripts/PatchReviewSidecar/run_patch_review.py`.
- Updated `DeepReadViewModel` so Deep Review runs the patch editor instead of `DeepPassRunner`.
- Made the rewritten Deep Read surface the app entry point and removed the developer UI toggle from Settings.
- Archived the prior rewritten-UI full-reconcile runner at `Brainstorming/archive/legacy-deep-review/DeepPassRunner.full-llm-reconcile.swift`.

The next calibration action is unchanged: run this app-integrated patch editor on at least 2-3 more human-revised transcripts, then tune candidate limits, protected-term behavior, and verifier thresholds.

## TL;DR (read first)

The full-transcript v5 smart-editor architecture should **not** ship with Voxtral Small. Q8 did **not** fix the clean-transcript hallucination: it applied `"Brant Kuehn" -> "Bernard Cohen"` on a correct transcript and worsened clean WER from 10.21% to 10.36%.

The new best path is a **tool-constrained editor**:

1. `run_local_relisten_editor.py` (v6) uses second-ASR disagreements only as a heatmap, re-runs VibeVoice on local windows, and applies only small word replacements. Result: **8/8 injected errors repaired**, **0 edits on clean**, corrupted WER restored from 10.84% to **10.21%**.
2. `run_patch_verifier.py --masked-cloze` (v8) generates small WhisperKit-vs-VibeVoice candidate patches, protects hotwords/domain terms, masks the disputed phrase out of the transcript, and asks Voxtral Small to fill the blank from two allowed choices. Result with Voxtral Small Q4: clean WER **10.21% -> 9.73%**, applying `seeing -> thinking`, `that's it -> that said`, and `Oh, gosh -> That was fast`.
3. Combined v6 + v8 on the corrupted transcript: **9.73% WER**, with all 8 injected corruptions repaired and the three verified real corrections applied.

This is the closest current implementation to the user's mental model: a person-like editor using tools, not a model hallucinating its own patch list.

For the full architectural narrative, see `RESULTS.md` (this directory) and the `April 30 – May 1` entry in `/Users/brantkuehn/Projects/Consensus/PROJECT_HISTORY.md`.

## Current decision

- **Reject v5 with Voxtral Small Q4 and Q8** for production. Both fail the clean proper-name reliability test.
- **Keep v6** as the safe regression/corruption guard. It proved the standard-of-proof gate can repair real wrong words without touching clean text.
- **Keep v8 masked cloze** as the forward path for actual WER improvement. It is still modest (9.73%, not sub-7%), but it is the first method in this experiment set that found the "that said" correction while avoiding full-transcript hallucination.
- **Do not treat Q8 as automatically better.** Q8 missed `seeing -> thinking` as a verifier; Q4 did better in the constrained patch-verification role.
- **The missing trick was masking.** Do not show the verifier a sentence with the disputed phrase already embedded. Show `____` plus two allowed fills. This changes the task from "argue whether this transcript is wrong" to "fill one blank from audio," which is much closer to how a careful human editor checks a disputed word.

## Recommended next implementation steps

1. Port the v6 local re-listen editor into the Swift/Python sidecar layer as a Deep Review safety pass.
2. Port v8 masked-cloze candidate generation and verifier prompts, but run the verifier through a resident process/server so each patch does not reload a 13-23 GB GGUF.
3. Add the user's context/hotword box to both passes. Treat proper names and domain terms as protected terms: never replace away from them unless the proposed patch moves toward a protected term.
4. Add a review UI queue that shows only applied/proposed patches with before/audio/after, because the architecture is now patch-centered rather than transcript-centered.
5. Build at least two more gold-standard fixtures. The current sample proves the shape, but one call cannot calibrate production thresholds.

---

## Historical v5 Q8 checklist

## Step 1 — download Voxtral Small Q8

```bash
cd /Users/brantkuehn/Projects/Consensus/Brainstorming/phase-a-vibevoice-nemotron/voxtral-small
curl -L --retry 10 --speed-time 60 --speed-limit 51200 \
  -o Voxtral-Small-24B-Q8_0.gguf \
  "https://huggingface.co/bartowski/mistralai_Voxtral-Small-24B-2507-GGUF/resolve/main/mistralai_Voxtral-Small-24B-2507-Q8_0.gguf"
```

Expected size: ≈25 GB. At ~30 MB/s on a good connection, ~14 minutes. The mmproj-f16 file (1.3 GB) is already on disk in this same directory — Voxtral uses the same mmproj across quantizations.

While waiting, check existing files:

```bash
ls -la /Users/brantkuehn/Projects/Consensus/Brainstorming/phase-a-vibevoice-nemotron/voxtral-small/
# expected:
#   Voxtral-Small-24B-Q4_K_M.gguf       (13 GB — keep, useful for comparison)
#   mmproj-Voxtral-Small-24B-f16.gguf    (1.3 GB — reused for Q8)
#   Voxtral-Small-24B-Q8_0.gguf          (after download finishes — ~25 GB)
```

**Disk check before downloading**: confirm at least 30 GB free.
```bash
df -h / | tail -1
```

## Step 2 — smoke-test Q8 actually works

Quick sanity check that the Q8 model loads and produces audio output. Should complete in under 10 seconds.

```bash
cd /Users/brantkuehn/Projects/Consensus/Brainstorming/phase-a-vibevoice-nemotron
/opt/homebrew/bin/llama-mtmd-cli \
  -m voxtral-small/Voxtral-Small-24B-Q8_0.gguf \
  --mmproj voxtral-small/mmproj-Voxtral-Small-24B-f16.gguf \
  --audio ../vibevoice-test/141_first30s.wav \
  -p "Listen and summarize what is being discussed in one sentence." \
  -n 100 --temp 0.0 -ngl 99
```

Expected: a one-sentence summary mentioning "mediation" / "Marie" / "Brant" or similar. If the model says something unrelated to the audio (e.g., "two men talking about reading"), Q8 has the same hallucination problem as Q4 and the Voxtral family is probably not the right model regardless of quantization.

## Step 3 — corrupted-transcript benchmark

This is the apples-to-apples comparison with the v5 Q4 result.

```bash
cd /Users/brantkuehn/Projects/Consensus/Brainstorming/phase-a-vibevoice-nemotron
/usr/local/bin/python3 run_smart_editor.py \
  --vibevoice-json vibevoice_corrupted.json \
  --audio ../vibevoice-test/141_W_54th_3.wav \
  --gguf voxtral-small/Voxtral-Small-24B-Q8_0.gguf \
  --mmproj voxtral-small/mmproj-Voxtral-Small-24B-f16.gguf \
  --out phase_a_v5_q8_corrupted.json \
  --audit-log phase_a_v5_q8_corrupted_audit.json
```

Expected wall clock: ~120-180s (Voxtral Small Q4 took 61s; Q8 will be slower per token but the audio encoding stays the same).

Score it:
```bash
/usr/local/bin/python3 score.py phase_a_v5_q8_corrupted.json \
  "/Users/brantkuehn/Projects/Consensus/TestAudio/141 W 5th St 3 - Manually Revised Transcript.groundtruth.json"
```

**Pass threshold**: WER ≤ 10.84% (corrupted baseline) AND ≥ 3 injections caught surgically (target: more than the 3/8 Q4 caught). Comparison reference:

| Variant | Corrupted WER | Δ corrupted | Injections caught |
|---|---:|---:|:---:|
| Corrupted baseline (no review) | 10.84% | — | — |
| **v5 / Voxtral Small Q4** | **10.68%** | **−0.16** | **3/8** |
| **v5 / Voxtral Small Q8** | (run this) | (run this) | (run this) |

## Step 4 — CRITICAL clean-transcript reliability test

**This is the test that mattered most.** Q4 failed it. The whole point of testing Q8 is to see if it passes.

```bash
/usr/local/bin/python3 run_smart_editor.py \
  --vibevoice-json ../vibevoice-test/vibevoice_with_context.json \
  --audio ../vibevoice-test/141_W_54th_3.wav \
  --gguf voxtral-small/Voxtral-Small-24B-Q8_0.gguf \
  --mmproj voxtral-small/mmproj-Voxtral-Small-24B-f16.gguf \
  --out phase_a_v5_q8_clean.json \
  --audit-log phase_a_v5_q8_clean_audit.json
```

Score it (should still be 10.21% — the original VibeVoice baseline):
```bash
/usr/local/bin/python3 score.py phase_a_v5_q8_clean.json \
  "/Users/brantkuehn/Projects/Consensus/TestAudio/141 W 5th St 3 - Manually Revised Transcript.groundtruth.json"
```

**Then look at the raw output**:
```bash
/usr/local/bin/python3 -c "
import json
a = json.load(open('phase_a_v5_q8_clean_audit.json'))
print(f'parse_error: {a.get(\"parse_error\")}')
print(f'proposed_edits: {len(a[\"proposed_edits\"])}')
print(f'applied_count: {a[\"applied_count\"]}')
print(f'\\nraw response:')
print(a['raw_response'][:1500])
"
```

**The correct answer for the clean test** is `{"edits": []}` (zero proposed edits). Anything else — even if filtered by the apply-gate — is a reliability red flag because we got lucky with Q4 only because the JSON parse failed.

**Decision matrix after Step 4**:

- **Q8 returns `{"edits": []}` on clean AND catches ≥ 3/8 on corrupted** → ship v5 with Q8 as the production Deep Review backend.
- **Q8 returns `{"edits": []}` on clean BUT catches 0/8 on corrupted** → Q8 is too conservative. Consider tweaking the prompt or pursuing a different model.
- **Q8 proposes ANY edit on clean (especially reversing correct names like Q4 did)** → Voxtral family hallucinates regardless of quantization. Pursue Step-Audio-R1.1 or wait for better tooling. Ship v2 (Qwen Q8 per-segment) in the meantime.
- **Q8 catches more than 3/8 on corrupted** → architecture is even better than the Q4 baseline showed; document and ship.

## Step 5 — update PROJECT_HISTORY and RESULTS.md with Q8 results

After running, append a short entry to:
- `RESULTS.md` (this directory) — add a row to the "Phase A v5 results table"
- `/Users/brantkuehn/Projects/Consensus/PROJECT_HISTORY.md` — add a brief addendum to the May 1 v3/v4/v5 section

Template entry:

```markdown
### May X, 2026 — v5 Q8 reliability test

Voxtral Small 24B Q8 on the smart editor architecture:
- Corrupted: WER X.XX%, applied N edits, caught N/8 injections.
- Clean: model proposed N edits (target: 0); raw response shows ___.
- Wall clock: Xs.

Conclusion: [Q8 is reliable enough / Q8 has same hallucination as Q4 / Q8 is too conservative].
Decision: [ship v5 / pursue Step-Audio / ship v2 as interim].
```

## Things worth thinking about (architectural review)

The user paused here specifically to think more about the architecture. A few open questions worth considering before the next iteration:

### 1. Is the smart-editor framing fundamentally the right shape?
Yes, by elimination. v3 (disagreement-driven) and v4 (candidate-judge) had structural problems with segment alignment whenever the two ASRs split the same audio differently. v5 sidesteps that entirely by never showing the model another transcript — only VibeVoice's, with audio. Five rounds of trying to merge two transcripts confirmed this isn't the right framing.

### 2. Where does the second ASR fit, if anywhere?
Currently: nowhere. The Parakeet transcript is on disk and is being ignored by v5. There IS an optional `--disagreements` flag in `run_smart_editor.py` that prepends a "spots worth listening closely" hint block to the prompt — using Parakeet's disagreements to focus the editor's attention. We tested v5 WITHOUT that hint block; results were 3/8. **Worth trying with the hint block**: does focusing attention boost recall to 5/8 or 6/8?

```bash
# Try this after Step 4 if Q8 is reliable
/usr/local/bin/python3 run_smart_editor.py \
  --vibevoice-json vibevoice_corrupted.json \
  --audio ../vibevoice-test/141_W_54th_3.wav \
  --gguf voxtral-small/Voxtral-Small-24B-Q8_0.gguf \
  --mmproj voxtral-small/mmproj-Voxtral-Small-24B-f16.gguf \
  --disagreements disagreements_corrupted.json \
  --out phase_a_v5_q8_corrupted_with_hints.json \
  --audit-log phase_a_v5_q8_corrupted_with_hints_audit.json
```

### 3. What about the user-provided context box?
The user's earlier idea — let the user provide a free-form summary + speaker names before transcription, used as both VibeVoice hotwords AND Qwen/Voxtral adjudication context — is **not yet integrated** in v5. The smart editor's prompt has no provision for user-provided context. Worth designing in:

- Add `--context "Brant Kuehn and Marie Larsen discussing legal arbitration..."` to `run_smart_editor.py`.
- Render it at the top of the prompt, before the transcript block.
- Potentially big win on accuracy because the editor would have proper-name priors AND domain context.

### 4. What's the failure mode of v5 if the model hallucinates BUT the find-string DOES exist in the segment?
The current standard-of-proof gate rejects edits where `find` is not in the segment. But it can't catch a hallucination where the model proposes a real swap (e.g., "Marie" → "Tracy") on a CORRECT segment. The Q4 clean test proposed exactly this kind of swap. The only thing that saved us was JSON truncation.

A real fix: **multi-sample voting**. Run the editor 3 times at temp 0.3; only apply edits that appear in ≥ 2 of the 3 outputs. Costs 3× inference time but catches stochastic hallucinations. Trivial change to `run_smart_editor.py`.

### 5. Is per-prompt context size a problem?
Current prompt is 10,485 chars on this 7m36s test audio. Under Voxtral's 32k context easily. But for a 60-min audio with ~400 segments, the prompt would be ~80k chars — over the limit. Need a chunking strategy for long audio:

- Chunk transcript into ~10-min slices
- Run smart editor per chunk with the corresponding audio slice
- Concatenate edit lists
- Apply

This is a real architecture question for the production version.

### 6. Should v2 ship now while v5 is being validated?
The April 30 v2 result (Qwen Q8 per-segment, soft prompt) is the only configuration we've VERIFIED safe on clean input. WER on corrupted: 10.60%. Detection: 3/8. Cost: 28 s/min audio. It's not better than v5 on detection, and it's slower, but it's verified. Worth shipping as the validated Deep Review backend while v5 work continues. The user has authorized 'going further' on v5 specifically.

Files for v2:
- `run_phase_a.py` — current sidecar (default soft prompt)
- `phase_a_voxtral_soft.json`, `phase_a_qwen_soft.json` — last v2 outputs
- See `RESULTS.md` for full v2 numbers.

## Quick architecture cheat sheet

For anyone (including future-me) who picks this up cold:

```
Input:  VibeVoice transcript (canonical) + audio
Optional input: second ASR's disagreement spots (as a "listen here closely" hint)
Output: a list of {segment_index, find, replace, evidence} patches

Process:
  1. Build prompt with full transcript indexed by segment + (optional) hint block
  2. Send prompt + audio to reasoning model in ONE inference
  3. Parse model's JSON edit list
  4. Apply each edit only if:
       - find string exists in target segment (rejects model confusion)
       - non-trivial diff (rejects punctuation/case/filler-only changes)
       - replace/find length ratio between 0.33 and 3.0 (rejects rewrites)
       - non-empty evidence ≥12 chars (forces articulation)
  5. Output corrected transcript with audit log of every accepted/rejected edit
```

What v5 explicitly does NOT do (and shouldn't):
- Merge two transcripts
- Rewrite segments wholesale
- Pick between candidate transcripts
- Trust the model to transcribe fresh from audio (audio is just for verification)

## Files index

In this directory (`Brainstorming/phase-a-vibevoice-nemotron/`):

**Working code**:
- `run_smart_editor.py` — v5 smart editor (recommended architecture)
- `find_disagreements.py` — disagreement detector (still useful for hints)
- `inject_errors.py` — controlled error injection tool
- `score_injections.py` — TP/FN/FP/TN scoring against the manifest
- `score.py` — symlink to vibevoice-test/score.py (WER + DER)
- `apply_word_swaps.py` — v4 word-swap apply (deprecated, kept for reference)
- `run_disagreement_review.py`, `run_phase_a.py`, `run_multi_candidate_judge.py` — v3/v4 (deprecated, kept for reference)
- `test_decision.py` — 15 unit tests on standard-of-proof primitives — all pass

**Test data**:
- `vibevoice_corrupted.json` — VibeVoice transcript with 8 deliberate injections
- `injection_manifest.json` — manifest of those injections
- `disagreements.json`, `disagreements_corrupted.json` — differ output (clean/corrupted)
- `phase_a_v5_corrupted.json`, `phase_a_v5_clean.json` — Q4 smart editor outputs

**Reference docs**:
- `RESULTS.md` — full benchmark results across all v1–v5 iterations
- `HANDOFF.md` — this file

**Models on disk**:
- `gguf/` — Nemotron 3 Nano Omni (no llama.cpp audio support yet; preserved for later)
- `voxtral/` — Voxtral Mini 3B (audio works but bad calibration)
- `qwen-omni/` — Qwen2.5-Omni-7B Q4 + Q8 (audio works with --jinja)
- `qwen3-asr/` — Qwen3-ASR 1.7B (broken in llama.cpp, issue #21847)
- `voxtral-small/` — Voxtral Small 24B Q4 (downloaded; Q8 is the next download)

## Open question for the next session

Once Q8 results are in, the choice point is: **does v5 ship, or do we wait for a better model?** The user wants to think about this. The architectural ground truth is: v5 is the right shape. The product question is: how patient are we for a more reliable driver model, and what do we ship in the meantime?
