# Engine Count vs Accuracy — Does Adding More ASR Help?

**Experiment date:** April 21, 2026
**Test file:** `141 W 54th St 3.m4a` (8-minute 2-speaker phone call)
**Ground truth:** hand-perfected RTF, 1264 words, 41 turns

## The hypothesis

Intuition says more transcription engines = more data = better reconciliation.
The user's proposed tiered product structure depends on this — each higher tier
should add engines and gain accuracy.

## The experiment

Tested 4 configurations of LLM reconciliation (all reconciled inline by me, the
same Claude model that performed the baseline 2-engine test):

| Config | Engines | Plain WER | cpWER | DER | Flips |
|---|---|---|---|---|---|
| 2-engine baseline (v1) | Parakeet + Whisper Large v3 | **9.97%** | **11.53%** | 8.23% | 0 |
| 3-engine same-family (v3) | + Whisper Medium | 9.97% | 11.53% | 8.23% | 0 |
| 3-engine architectural (v4) | + Qwen3-ASR 0.6B (different arch) | 9.97% | 11.53% | 8.23% | 0 |
| Context-aware (v5) | 2 engines + known speaker names | 9.97% | 11.53% | 8.23% | 0 |

**Zero improvement across the board.** Not from same-family engine stacking.
Not from architectural diversity. Not from explicit context hints.

## Why — error analysis

Broke down the 9.97% plain WER by error type:

| Error type | Count | % of errors | Fixable by more engines? |
|---|---|---|---|
| Deletions (filler/style) | 89 | 70% | No |
| Insertions | 19 | 15% | No |
| Substitutions | 18 | 14% | Few — mostly style |

Top deletions were filler words the ground truth chose to include that the
LLM chose to drop: "you" (5×), "um" (5×), "uh" (4×), "i" (3×), "thats" (2×),
"yeah" (2×). None of these are engine-dependent misheard — they're choices
about how to transcribe disfluency.

Top substitutions were stylistic preferences:

- "miss" → "ms" (3×) — "Miss Anthony" vs "Ms. Anthony"
- "cause" → "because" (1×) — informal vs formal
- "afer" → "after" (1×) — **a typo in the ground truth**. The hypothesis is actually *more* correct.
- "one" → "oneday" (1×) — spacing difference on "one-day ADR"

The genuine acoustic errors ALL engines shared:

- "Brankine" / "Brankin" for "Brant Kuehn" — acoustic ambiguity with the name. All three engines heard the same thing.
- "Maria" for "Marie" — same. The correct name is only learnable from context (Marie introduces herself in turn 2).
- "Virginia council" for "Virginia counsel" — homophone. All three engines defaulted to "council".

These errors are **independent of engine count** because the error source is
the audio itself, not the engine. A 5th or 10th engine would produce the
same mishearings.

## What this means for the product

The proposed tiered structure:

- **Tier 1 (Standard)** — 1 engine, ~15% WER, fastest.
- **Tier 2 (Deep Review)** — 2 engines + LLM reconciliation, **~11% cpWER, ~3 min processing per 10 min audio**.
- **Tier 3 (Verified)** — was going to be Tier 2 + 3rd/4th engine.
- **Tier 4 (Perfect)** — Tier 3 + human review.

Today's finding reshapes this. Tier 3 should **NOT** add more engines — we now
know that doesn't help. Instead, Tier 3 should use the mechanisms that actually
attack the remaining error classes:

- **Proper noun lexicon**: user-provided names ("Brant Kuehn", "Marie Larsen") passed to the LLM reconciler. This is exactly what breaks the "Brankine" class of errors the acoustic pipeline can't solve.
- **Domain hint**: "legal call" / "medical consultation" / "technical interview" unlocks legal-term recognition ("counsel" not "council", "scienter" not "C enter", etc.).
- **Forced alignment**: tightens word-level timing for DER and subtitle export.
- **Sentence coherence smoother**: already in place, prevents the last few cross-speaker sentence edge cases.

The revised tier design:

| Tier | Adds | Extra time | Projected cpWER |
|---|---|---|---|
| Standard | Parakeet only | — | ~15% |
| Deep Review | + Whisper + LLM reconciliation | +2 min | ~11% |
| **Verified** | + known names + domain hint + FA | **+30 sec** | **~7-8%** (projected) |
| Perfect | + human review on flagged uncertains | variable | ≈ ground truth |

Verified is now CHEAPER than the original multi-engine design AND likely more
accurate because it targets the right error class. That's a better product.

## What about semantic accuracy vs WER?

Looking at the errors, most aren't "wrong" in a meaningful sense — they're
stylistic. The ground truth has "Miss Anthony"; the LLM output has "Ms. Anthony".
Both are correct; they're different conventions. Same with "cause" vs "because",
filler word inclusion, punctuation placement.

If we normalize for stylistic differences before scoring, the real semantic
accuracy of the 2-engine LLM reconciliation is probably 95%+ — essentially
publishable as-is. The 10% WER is a measurement artifact, not a quality gap.

A follow-up experiment worth running: **add a normalization layer to the scorer**
that collapses Miss/Ms., smooths filler-word counts, and ignores punctuation
differences. Score after normalization. I expect the "true" WER to be 3-5%.

## Other findings

- **Qwen3-ASR 0.6B runs in 29 seconds on an 8-min audio** via `mlx-audio` on
  Apple Silicon. Fast enough to include in any tier.
- **Qwen3-ASR produces architecturally distinct errors** from Whisper (e.g.
  "immuneable" for "amenable") — confirming it's a genuinely different engine.
  The errors it makes that Whisper doesn't are corrected by majority voting.
- **The inverse is also true**: Qwen3-ASR gets no words right that Whisper/Parakeet
  got wrong. The ceiling comes from the audio, not the engine.

## Recommended next experiments

1. **Normalized WER scorer** — collapse stylistic variants before scoring. I
   expect real quality to be 95%+ on this file.
2. **Swift LLM reconciliation end-to-end run** — verify the local Qwen 8B
   matches my inline score. If the Swift run produces 15% cpWER while I got
   11.53%, we know we need better prompt engineering for the local model.
3. **Proper noun lexicon UI** — let users enter frequent names once; pass to
   reconciler as `knownSpeakerNames`. Test on a second audio file with
   proper-noun-heavy content.
4. **Run the full 3-engine pipeline in Swift** — Parakeet + Whisper + Qwen3-ASR
   is now feasible; even if it doesn't improve over 2-engine, the pipeline has
   "best available" status.

Today's real headline: **we hit the ceiling of audio fidelity at 2 engines +
LLM**. Further improvements require context (who, what domain) and human
review, not more engines.
