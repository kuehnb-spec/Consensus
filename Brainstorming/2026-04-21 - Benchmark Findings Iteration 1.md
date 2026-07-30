# Benchmark Findings — Iteration 1

**Date:** April 21, 2026
**Source data:** `141 W 54th St 3.m4a` (7m 36s phone call, 2 speakers)
**Ground truth:** `TestAudio/141 W 5th St 3 - Manually Revised Transcript.rtf` (41 turns, 1264 words, hand-corrected)

## Headline

**The Deep Review pipeline, as currently wired, produces dramatically worse output than either source engine alone.** The `ConfidenceMergeService.mergeAlignedWords` step is shuffling words between the two engines' streams whenever their timestamps disagree, turning coherent sentences into word salad.

| Output | Plain WER | cpWER | DER | Mid-sentence flips |
|---|---|---|---|---|
| **Current Deep Review (consensus)** | **33.15%** | **37.59%** | **8.82%** | **6** |
| `standard` pass (Parakeet alone) | 14.64% | 17.50% | 6.09% | 4 |
| `deepReviewComparison` pass (Whisper alone, no diarization) | 10.36% | — | — | — |

Standard transcription is 2.25× more accurate than the Deep Review output it feeds into. Something is very wrong.

## Diagnosis

Looking at a sample from the consensus pass, compared to what Engine A (Parakeet) produced on its own:

> **Parakeet standard:** "So you're going not to be there attending or dialing in or whatever next week?"
>
> **Deep Review consensus:** "So you're going not whatever next attending or dialing it. in week?"

Words are reordered, duplicated, and broken across adjacent segments. This is `ConfidenceMergeService.alignWords` failing to match words between the two engines (because their timestamps disagree by 50-200ms), then emitting BOTH engines' unmatched words in the output, sorted by timestamp — producing an interleaving that doesn't preserve either engine's actual word order.

The `candidateOnly` path in `mergeAlignedWords` is the smoking gun:

```swift
case .candidateOnly(let cand):
    // ... returns MergedWord(word: cand.word, ...)
```

Unless a word is both low-confidence AND a filler, Engine B's unmatched words get appended to the merged stream and sorted by timestamp. When Engine A and Engine B disagree on word segmentation (which they often do), this produces interleaved garbage.

## Alternative merge strategies tested

I simulated five alternative strategies in Python against the same input streams, scoring each against the ground-truth RTF:

| Strategy | Plain WER | cpWER | DER | Flips | Turns |
|---|---|---|---|---|---|
| `aligned_b_text_a_speakers` | **10.05%** | **12.89%** | 11.07% | 5 | 34 |
| `b_text_a_speakers` | 10.05% | 13.45% | 11.39% | 8 | 35 |
| `a_only` (= Standard pass) | 14.64% | 17.50% | **6.09%** | **4** | 23 |
| `a_fill_gaps_with_b` | 14.64% | 17.50% | 6.09% | 4 | 23 |
| `a_replace_low_conf_with_b` | 14.64% | 17.50% | 6.09% | 4 | 23 |
| Swift consensus (current) | 33.15% | 37.59% | 8.82% | 6 | 23 |

Key observations:

- **Any strategy beats the current merge.** Even the most trivial "just use Engine A" is 2× better on every metric.
- **The best-WER strategy uses Engine B's text + Engine A's speakers** (via word-level alignment to pull speaker labels). 12.89% cpWER is 2.9× better than the current 37.59%.
- **The best-DER strategy is Engine A alone** — because its speaker labels are locked in, while B-text strategies introduce small timing drift on boundaries.
- `a_fill_gaps_with_b` and `a_replace_low_conf_with_b` didn't help on this clip because Engine A had no big gaps and no words below 0.5 confidence. They may help on noisier audio.

There's a genuine WER-vs-DER trade-off: using Engine B's text improves words but hurts boundaries. Pick based on what matters most.

## Recommendation

**Immediate fix**: Default the Deep Review path to a new strategy `engineAOnly` that skips `mergeAlignedWords` entirely. Engine A's text and speakers flow through unchanged. Engine B still runs and its output is available for confidence flagging — just not for text substitution.

This should move Deep Review consensus from **37.59% cpWER** to **17.50% cpWER** and from **8.82% DER** to **6.09% DER** on this test file — a 53% reduction in text errors and 31% reduction in diarization errors, by simply removing a harmful step.

**Follow-up**: Re-investigate whether any B-derived substitution can help at all. The theoretical ceiling from this data is ~13% cpWER (aligned_b_text_a_speakers), but that loses 5 points of DER. A careful engineering task would be to preserve Engine A's timestamps while adopting Engine B's word choices where the alignment is high-confidence.

## What's next on the iteration loop

1. Ship the `engineAOnly` default in Swift.
2. Re-score. If consensus drops to ~17% cpWER, we've knocked out the biggest leak.
3. Then iterate on the sentence-coherence smoother against this new baseline (there's probably still juice in the 17% → ~13% range).
4. Forced alignment is still off-by-default because I set it to on-by-default yesterday without verifying it's helpful; benchmark the difference separately before committing.
