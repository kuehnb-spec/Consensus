# The Consensus Breakthrough — April 21, 2026

**Two problems, one day, two connected wins.** This document captures the story
for the website — longer than the PROJECT_HISTORY entry, shorter than the
technical Brainstorming memos, and written to be readable on its own.

## The problem before today

Consensus had been iterating on transcription quality for months. Multiple
transcription engines running in parallel (WhisperKit + FluidAudio's Parakeet),
multi-pass diarization from two independent backbones (SpeakerKit + FluidAudio),
forced alignment, an LLM-assisted speaker-boundary arbiter — every technique
the 2024-2026 literature recommended was in the stack. And yet, real-world
output still had obvious errors: speaker changes mid-sentence, duplicated
words, misheard proper nouns, and the unshakeable sense that the pipeline was
doing a lot of clever work without actually getting better.

The meta-problem was that every improvement judgment was eyeball-level.
"Does this look better?" is a terrible feedback loop when you're tuning five
interacting components. Changes that helped one metric could silently hurt
another. Without objective measurement, the app had reached a fixed point —
neither clearly improving nor clearly broken, just stuck.

## Breakthrough 1 — Ground truth as a fitness function

The unblock came from a methodology shift. The user manually perfected the
transcript of one phone call (141 W 54th St 3, an 8-minute conversation
between two speakers), sitting at a keyboard listening through the audio in
Consensus's new Manual Editor — 41 speaker turns, 1,264 words, every ASR
mishearing corrected by hand. That one artifact transformed the problem.

With a hand-verified reference transcript, every pipeline variant became
*scorable*. A small benchmark harness — three Python scripts living under
`Scripts/benchmark/` — turned subjective arguments about "does this look
better" into objective numbers:

- **cpWER** (concatenated permutation-invariant Word Error Rate) — what
  fraction of words the pipeline got wrong, with the best possible speaker-
  label matching.
- **DER** (Diarization Error Rate) — what fraction of speech time the
  pipeline labeled with the wrong speaker.
- **Mid-sentence flip count** — how many times the pipeline put two speakers
  inside one continuous sentence (usually a sign of timestamp noise winning
  over content coherence).

Crucially, the harness could also *replay* alternative pipeline strategies
against the engines' captured output, without the slow rebuild-and-re-run
cycle of changing Swift code. Five different word-alignment merge policies
could be scored in seconds instead of hours.

The immediate finding was uncomfortable: **the existing Deep Review pipeline
produced 33% cpWER — more than double the 15% cpWER of the single-engine
Standard pass it was built on top of.** The merge step at the heart of the
feature was actively destroying output. It had been for months, and nobody
could tell because nobody was measuring.

That single data point would have been justification enough for the day's
work — but it set up the second breakthrough.

## Breakthrough 2 — Let the LLM read the content

The existing merge was a word-alignment algorithm: take both engines' word
streams, match them up by timestamp, pick the best candidate at each position.
This is a natural thing to build and a lot of speech research uses variants of
it (ROVER, MOVER, confidence-weighted voting). But the algorithm assumes two
engines produce words in the same order with the same timing — and they
don't. Parakeet's word timestamps and Whisper's word timestamps disagree by
50-200 ms constantly. When the alignment fails, both engines' unmatched words
bleed through into the merged output, sorted by timestamp, producing
interleaved word-salad that sounded like neither engine.

Example of what the broken merge produced (Parakeet's clean version first):

> Parakeet: *"So you're going not to be there attending or dialing in or whatever next week?"*
>
> Merged: *"So you're going not whatever next attending or dialing it. in week?"*

Five alternative word-alignment strategies were simulated in Python. The best
one — using Engine B's text with Engine A's speakers via word-level alignment
— reached 12.89% cpWER. Better than the broken merge's 37.59%, better than
Standard's 17.50%, but still limited by the fundamental nature of the
word-alignment approach. It was still doing arithmetic on timestamps, not
reasoning about content.

Then came the architectural shift. Instead of aligning by timestamp, feed
both transcripts to an LLM and let it *reason*: read both versions, use world
knowledge to resolve disagreements, preserve speaker structure from one
engine's diarization, split long turns where the other engine shows finer
segmentation. No timestamp arithmetic — just a model reading text and
thinking about what was said.

The result of a single LLM reconciliation pass, scored against the
hand-perfected ground truth:

| Pipeline | Plain WER | cpWER | DER | Mid-sentence flips | Turns |
|---|---|---|---|---|---|
| **LLM-reconciled** | **9.97%** | **11.53%** | 8.23% | **0** | **41** |
| Best word-alignment strategy | 10.05% | 12.89% | 11.07% | 5 | 34 |
| Standard pass (Parakeet alone) | 14.64% | 17.50% | 6.09% | 4 | 23 |
| **Current Deep Review (pre-fix)** | **33.15%** | **37.59%** | 8.82% | 6 | 23 |

The LLM reconciliation achieved **11.53% cpWER — a 69% reduction in text
errors from the current production pipeline.** Zero mid-sentence speaker
flips. Turn count matching ground truth exactly. The DER was in the middle of
the pack, limited mostly by timestamp-precision of the ASR engines (a
problem forced alignment solves separately).

## What this means for Consensus

The proof of concept landed today. The Swift implementation comes next —
`LLMReconcileService` using the same local Qwen 8B already in the app for
cleanup and summarization. No new dependencies, no cloud calls, fully
privacy-preserving. The reconciliation is a text-level reasoning task
well-matched to an 8B model.

The product shape this enables is a tiered Deep Review:

- **Standard** (seconds): single engine. Rough draft quality.
- **Deep Review** (2-3 minutes): two engines + LLM reconciliation. Near-human
  accuracy on clean audio — projected ~11% cpWER.
- **Verified** (5-10 minutes): three engines + LLM reconciliation + forced
  alignment + sentence-coherence smoothing. Targets sub-10% cpWER.
- **Perfect** (longer): everything above plus targeted human review on
  LLM-flagged uncertain regions, surfaced in the Manual Editor with
  pre-queued audio playback.

Each tier trades processing time for final accuracy. The user picks based on
how much the transcript matters.

## The methodology the breakthrough proves

For any hard engineering problem where the output is a complex artifact:

1. **Make one example perfect by hand.** Not a toy example, a real
   representative one — big enough that the errors you care about appear.
2. **Build objective metrics.** cpWER, DER, whatever serves the actual
   quality you're optimizing for.
3. **Build replay infrastructure** so you can try variants without the slow
   production loop.
4. **Let the metrics tell you where you are before you trust your intuition
   about where you are.**
5. **Once you're measuring, check whether your current approach is even on
   the right architectural track.** Sometimes the answer is no.

Before today, Consensus was five layered improvements on a fundamentally
broken merge. After today, the broken merge is off by default, a measurably
better architecture is proven, and every future change has a fitness function
to beat.

## Files produced today

- `TestAudio/141 W 5th St 3 - Manually Revised Transcript.rtf` — the hand-corrected
  ground truth source.
- `TestAudio/141 W 5th St 3 - Manually Revised Transcript.groundtruth.json` —
  canonical ground truth JSON for the scorer.
- `Scripts/benchmark/import_ground_truth.py` — RTF-to-JSON importer with
  timestamp interpolation.
- `Scripts/benchmark/score.py` — cpWER, DER, flip-count scorer.
- `Scripts/benchmark/simulate_merges.py` — merge-strategy replay harness.
- `Scripts/benchmark/llm_reconcile.py` — LLM reconciliation harness.
- `Brainstorming/2026-04-21 - Benchmark Findings Iteration 1.md` — technical
  findings memo.

The benchmark infrastructure is permanent. Every future Consensus pipeline
change gets scored against this ground truth before shipping.
