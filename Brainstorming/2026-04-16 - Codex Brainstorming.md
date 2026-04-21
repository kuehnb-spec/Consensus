# Codex Brainstorming: Diarization and Transcription

Prepared: April 14, 2026

## Executive Take

The app is already architecturally ahead of most local transcription tools: it separates transcription from diarization, supports a real Deep Review flow, and now does word-aware speaker assignment. The current ceiling is not "we need one better model" so much as "the pipeline is still baseline-anchored and single-timeline."

My strongest conclusion is this: the next big gain probably comes from rebuilding the speaker timeline around better word timing, better evidence fusion, and explicit overlap handling, not from adding one more clustering threshold.

## Current Pipeline Snapshot

The current app still runs a fundamentally linear first-pass pipeline: audio load -> model download -> transcription -> diarization -> merge. See [TranscriptionPipeline.swift](/Users/brantkuehn/Projects/Consensus/TranscriboApp/Transcribo/Services/TranscriptionPipeline.swift#L17) and [TranscriptionPipeline.swift](/Users/brantkuehn/Projects/Consensus/TranscriboApp/Transcribo/Services/TranscriptionPipeline.swift#L215).

Deep diarization is more sophisticated than the first pass. It runs multiple diarization passes, gathers candidate boundaries, asks the local LLM to confirm them from transcript context, then acoustically verifies them before inserting them back into the baseline diarization. See [DiarizationService.swift](/Users/brantkuehn/Projects/Consensus/TranscriboApp/Transcribo/Services/DiarizationService.swift#L142) and [TranscriptionViewModel.swift](/Users/brantkuehn/Projects/Consensus/TranscriboApp/Transcribo/ViewModels/TranscriptionViewModel.swift#L607).

The main structural limits I see in the current code:

1. The app still collapses everything to a single speaker label per transcript region, even though overlap is one of the hardest real-world diarization failure modes. The current merge model is still a one-label timeline. See [SegmentMerger.swift](/Users/brantkuehn/Projects/Consensus/TranscriboApp/Transcribo/Services/SegmentMerger.swift#L43).
2. Deep diarization is still baseline-first. New boundaries are only inserted if they are far enough from the first pass, so the first pass still defines reality more than the evidence does. See [TranscriptionViewModel.swift](/Users/brantkuehn/Projects/Consensus/TranscriboApp/Transcribo/ViewModels/TranscriptionViewModel.swift#L671).
3. Deep transcript reconciliation keeps speaker labels entirely from the reference pass, which means better text from other engines does not improve the speaker timeline. See [ConfidenceMergeService.swift](/Users/brantkuehn/Projects/Consensus/TranscriboApp/Transcribo/Services/ConfidenceMergeService.swift#L44).
4. SpeakerKit segments are currently converted with `qualityScore: 1.0`, so the system has no real diarization confidence signal to reason about. See [SpeakerKitDiarizationService.swift](/Users/brantkuehn/Projects/Consensus/TranscriboApp/Transcribo/Services/SpeakerKitDiarizationService.swift#L55).
5. The app has a custom word-aware merge layer, but the upstream SpeakerKit docs now describe native transcript reconciliation modes that may be better aligned with the model's own assumptions. See [SegmentMerger.swift](/Users/brantkuehn/Projects/Consensus/TranscriboApp/Transcribo/Services/SegmentMerger.swift#L252).

## Research Highlights

These are the most relevant current developments I found from primary sources.

1. SpeakerKit / WhisperKit now documents explicit transcript reconciliation options.
   The official WhisperKit repo says `PyannoteDiarizationOptions` includes `useExclusiveReconciliation`, and that combining diarization with transcription supports both `.subsegment` and `.segment` strategies. The default documented strategy is `.subsegment`, which is especially relevant because your app currently implements its own speaker merge layer instead. Source: [WhisperKit README](https://github.com/argmaxinc/WhisperKit) opened at [lines 676-712](https://github.com/argmaxinc/WhisperKit).
2. pyannote's current stack is emphasizing exclusive diarization, word-level output, and confidence.
   The official pyannote docs describe word-level speaker-attributed transcription, and their confidence tutorial exposes sample-level and turn-level confidence scores. Inference: the broader ecosystem is moving toward confidence-aware, word-level speaker attribution rather than only turn-level post hoc smoothing. Sources: [STT + diarization tutorial](https://docs.pyannote.ai/tutorials/speech-to-text-diarization), [confidence scores](https://docs.pyannote.ai/tutorials/confidence-scores), [models](https://docs.pyannote.ai/models).
3. Local Apple Silicon speech tooling has moved fast in early 2026.
   The official `speech-swift` repo now advertises on-device ASR, forced alignment, VAD, diarization, and speaker embeddings on Apple Silicon. Its README lists `Qwen3-ForcedAligner`, `Speaker Diarization`, `Sortformer`, and speaker embeddings, and the repo news section highlights February 26, 2026 diarization/VAD work and March 20, 2026 ASR benchmark work. Source: [speech-swift README](https://github.com/soniqo/speech-swift) at [lines 322-340](https://github.com/soniqo/speech-swift) and [lines 395-405](https://github.com/soniqo/speech-swift).
4. Diarization-conditioned ASR is becoming a serious research direction.
   DiCoW was submitted on December 30, 2024 and explicitly conditions Whisper on diarization labels, arguing that cascaded diarization -> ASR pipelines suffer from weak generalization and overlap problems. The paper says it handles overlapping speech better by integrating diarization signals directly into the model. Source: [DiCoW on arXiv](https://arxiv.org/abs/2501.00114).
5. Newer joint ASR + diarization papers are challenging the cascade assumption directly.
   A January 25, 2026 paper on end-to-end joint ASR and speaker role diarization extends Whisper with serialized speaker tags, a frame-level diarization head, diarization-guided silence suppression, and constrained decoding, and reports better multi-talker performance than cascaded baselines. Source: [End-to-End Joint ASR and Speaker Role Diarization](https://arxiv.org/abs/2601.17640).
6. NVIDIA NeMo continues to formalize both cascaded and end-to-end diarization flows.
   The current NeMo docs expose Sortformer diarization, multi-scale diarization, and tutorials that combine ASR transcriptions, speaker labels, and voice activity timestamps. Inference: the strongest production pipelines are no longer treating diarization as an isolated post-process. Source: [NeMo speaker diarization guide 25.02](https://docs.nvidia.com/nemo-framework/user-guide/25.02/nemotoolkit/asr/speaker_diarization/intro.html).
7. Voiceprints help identity continuity, but they do not improve core diarization accuracy by themselves.
   pyannote's own docs explicitly say voiceprints are for identification only and do not improve diarization accuracy. That matters because speaker memory is still useful for UX and label stability, but it should not be mistaken for a DER improvement strategy. Source: [pyannote voiceprints tutorial](https://docs.pyannote.ai/tutorials/identification-with-voiceprints).

## What I Think Has Changed Since We Last Looked

The two most important changes are:

1. The local Apple Silicon ecosystem is more credible now than it was even a few months ago.
   `speech-swift` is the clearest example: diarization, embeddings, forced alignment, and newer ASR models are now available in a Swift-native Apple Silicon world instead of only in Python-heavy stacks.
2. The field is increasingly moving away from "transcribe first, then slap a speaker label on segments."
   The research and docs are converging on word-level attribution, exclusive reconciliation, overlap-aware decoding, and even joint modeling.

## Ten Change Ideas

### 1. Replace the custom merge layer with SpeakerKit's native reconciliation path

What it is: use SpeakerKit's official transcript reconciliation instead of relying primarily on the custom `SegmentMerger`, ideally with `.subsegment` matching and experimentation around `useExclusiveReconciliation`.

Why it might help: your current custom merge logic is smart, but it is still heuristic-heavy. Upstream reconciliation may better reflect the model's native frame/subsegment assumptions.

Why it maps to your code: [SpeakerKitDiarizationService.swift](/Users/brantkuehn/Projects/Consensus/TranscriboApp/Transcribo/Services/SpeakerKitDiarizationService.swift#L38) currently sets only `numberOfSpeakers` and `clusterDistanceThreshold`, while [SegmentMerger.swift](/Users/brantkuehn/Projects/Consensus/TranscriboApp/Transcribo/Services/SegmentMerger.swift#L252) does the heavy lifting locally.

Complexity: medium.

### 2. Add a dedicated forced-alignment stage after final text selection

What it is: after Deep Transcription chooses the best final text, run a local forced aligner to rebuild word timings before speaker assignment.

Why it might help: diarization performance in practice is often capped by weak word timing more than weak clustering. Better timestamps would improve speaker attribution, boundary insertion, subtitle accuracy, and disagreement clustering.

Why it maps to your code: both [SegmentMerger.swift](/Users/brantkuehn/Projects/Consensus/TranscriboApp/Transcribo/Services/SegmentMerger.swift#L252) and [ConfidenceMergeService.swift](/Users/brantkuehn/Projects/Consensus/TranscriboApp/Transcribo/Services/ConfidenceMergeService.swift#L41) depend heavily on word timing quality.

Local candidate: `Qwen3-ForcedAligner` from the official `speech-swift` stack.

Complexity: medium to high.

### 3. Introduce real diarization confidence throughout the app

What it is: carry forward confidence per frame, word, boundary, and turn, whether from the diarizer itself or from a derived agreement score across passes.

Why it might help: right now the system cannot distinguish "speaker flip with strong evidence" from "speaker flip after a weak heuristic." That limits both automation and UI review quality.

Why it maps to your code: [SpeakerKitDiarizationService.swift](/Users/brantkuehn/Projects/Consensus/TranscriboApp/Transcribo/Services/SpeakerKitDiarizationService.swift#L55) hardcodes `qualityScore: 1.0`, and [TranscriptionViewModel.swift](/Users/brantkuehn/Projects/Consensus/TranscriboApp/Transcribo/ViewModels/TranscriptionViewModel.swift#L668) currently treats pass agreement as a simple vote count.

Complexity: medium.

### 4. Make overlap a first-class transcript concept

What it is: keep both an exclusive timeline and an overlap timeline instead of forcing all speech into one `speakerID`.

Why it might help: a lot of the remaining "bad diarization" complaints are actually overlap and interruption failures. Flattening those to one label guarantees information loss.

Why it maps to your code: the current segment model still assumes one speaker per displayed transcript unit.

Complexity: high.

### 5. Replace baseline-first boundary insertion with an evidence graph

What it is: treat each diarization pass as evidence, build a boundary graph or lattice over time, weight edges by confidence and agreement, and decode the best speaker path rather than editing the first pass.

Why it might help: your current Deep Diarization is good at discovering missing boundaries, but it still uses the first pass as the anchor truth. An evidence graph would let the final timeline emerge from all passes instead.

Why it maps to your code: [TranscriptionViewModel.swift](/Users/brantkuehn/Projects/Consensus/TranscriboApp/Transcribo/ViewModels/TranscriptionViewModel.swift#L689) explicitly looks for boundaries that the baseline missed, which bakes in asymmetry.

Complexity: high.

### 6. Add ASR-conditioned VAD and timestamp cleanup before diarization merge

What it is: use word timings, silence spans, and transcript structure to help split or clean the diarization timeline before final merge.

Why it might help: diarizers often get hurt by long homogeneous regions and weak boundary timing; ASR can provide structure the diarizer alone does not have.

Why it maps to your code: it would slot naturally between Deep Transcription and Deep Diarization.

External cue: NeMo's documentation explicitly includes tutorials that combine ASR transcriptions, speaker labels, and voice activity timestamps.

Complexity: medium.

### 7. Add a channel-aware and separation-aware fast path

What it is: detect stereo or dual-mono recordings and split by channel when appropriate; optionally add a local source-separation branch for hard-overlap cases.

Why it might help: when the recording format already contains speaker separation information, model-based diarization should not be doing the entire job alone.

Why it maps to your code: this could sit right at audio ingest before the first diarization pass.

Complexity: medium.

### 8. Run a local alternate-ASR matrix, not just a diarization matrix

What it is: let Deep Review compare WhisperKit against at least one newer local ASR stack such as Qwen3-ASR or Parakeet.

Why it might help: better punctuation, word timing, and silence behavior can improve diarization even if the diarizer itself stays the same.

Why it maps to your code: Deep Review already compares multiple transcription passes; this would widen the search space without changing the UX model.

External cue: the official `speech-swift` repo now exposes `Qwen3-ASR`, `Parakeet TDT`, and `Qwen3-ForcedAligner` locally.

Complexity: medium to high.

### 9. Add persistent local speaker memory with embeddings

What it is: keep per-project or cross-project speaker embeddings so the app can stabilize speaker identity and naming across retries, passes, and imported sessions.

Why it might help: this will not fix raw diarization accuracy on its own, but it can reduce speaker label drift and make deep review more coherent.

Why it maps to your code: current remapping is driven mostly by segment overlap and prior labels rather than voice representation.

Important caveat: pyannote's own docs say voiceprints do not improve diarization accuracy directly, so this is more about continuity than DER.

Complexity: medium.

### 10. Create a research-track rewrite toward joint diarization-conditioned ASR

What it is: build an experimental sidecar pipeline inspired by DiCoW or the January 2026 joint Whisper paper, where speaker tags are generated or conditioned during decoding rather than attached afterward.

Why it might help: it attacks the root problem of error propagation between ASR and diarization.

Why it maps to your code: your current app is already modular enough that a sidecar experiment could coexist with the current pipeline.

Complexity: very high.

## My Three Most Interesting Proposals

These are not necessarily the easiest. They are the three I think have the best mix of upside, novelty, and strategic value.

### 1. Rebuild the word timeline before rebuilding the speaker timeline

This is the proposal I would personally start with.

Scope:

1. Keep Deep Transcription as the text-selection stage.
2. Add a forced-alignment stage to rebuild accurate word timings from the selected final transcript.
3. Re-run word-level speaker attribution on those aligned words.
4. Carry forward confidence on each word and each speaker turn.

Why it is interesting:

1. It directly attacks the place where your current diarization quality is probably leaking most: uncertain word boundaries and fuzzy merge timing.
2. It stays fully local.
3. It improves both diarization and export quality without requiring a total rewrite.

Why I think it could outperform "just another diarizer pass":

Inference from the code and sources: your app already has enough diarization diversity to discover many boundaries. What it lacks is a precise enough timeline to assign those boundaries cleanly back onto final words.

Expected upside: high.

Implementation complexity: medium to high.

### 2. Replace baseline-first Deep Diarization with an evidence graph

This would be the most interesting architectural improvement without changing the ASR model family.

Scope:

1. Collect all candidate boundaries and all speaker hypotheses from every pass.
2. Weight them using pass reliability, local confidence, and optional LLM support.
3. Decode the best speaker path over time instead of inserting boundaries into pass 0.
4. Preserve an overlap-aware side channel where evidence is strong.

Why it is interesting:

1. It changes Deep Diarization from "patch the first answer" into "infer the best answer from all evidence."
2. It is much closer to how stronger diarization research systems think about uncertainty.
3. It makes the local LLM a supporting voter, not a structural crutch.

Why it fits this app:

You already have multiple passes, candidate boundary collection, and acoustic verification. The app is one abstraction away from an actual evidence decoder.

Expected upside: high.

Implementation complexity: high.

### 3. Start a research sidecar for joint diarization-conditioned ASR

This is the most radical and the most speculative, but it is the one with the highest long-term ceiling.

Scope:

1. Keep the current production pipeline intact.
2. Build a sidecar experiment around diarization-conditioned decoding or serialized speaker-tag decoding.
3. Test it only on a benchmark set first.

Why it is interesting:

1. The research direction is clearly moving away from pure cascades.
2. Your app is already modular enough to host an experimental branch.
3. If it works, it could simplify large parts of Deep Review instead of endlessly making the cascade smarter.

Why I would not start here first:

It is expensive, risky, and likely requires Python-side experimentation or a much heavier rewrite before it becomes product-ready on macOS.

Expected upside: very high.

Implementation complexity: very high.

## What I Would Actually Do Next

If we want the best near-term win while staying local, I would sequence the work this way:

1. Prototype "word timeline rebuild" on a small benchmark set.
2. In parallel, test whether SpeakerKit native `.subsegment` plus `useExclusiveReconciliation` beats the current custom merge on the same files.
3. If both help, combine them.
4. Only then decide whether to invest in the evidence-graph rewrite.

## Practical Recommendation for Tomorrow's Discussion

If we want one actionable plan, I would propose this:

1. Short-term candidate: try SpeakerKit native reconciliation plus a forced-alignment stage.
2. Medium-term candidate: redesign Deep Diarization as an evidence graph.
3. Long-term research track: test a joint diarization-conditioned ASR sidecar.

That gives us one incremental path, one architectural path, and one moonshot.

## Sources

1. WhisperKit official repository and SpeakerKit docs: [https://github.com/argmaxinc/WhisperKit](https://github.com/argmaxinc/WhisperKit)
2. pyannote STT + diarization tutorial: [https://docs.pyannote.ai/tutorials/speech-to-text-diarization](https://docs.pyannote.ai/tutorials/speech-to-text-diarization)
3. pyannote confidence scores tutorial: [https://docs.pyannote.ai/tutorials/confidence-scores](https://docs.pyannote.ai/tutorials/confidence-scores)
4. pyannote models overview: [https://docs.pyannote.ai/models](https://docs.pyannote.ai/models)
5. pyannote voiceprints tutorial: [https://docs.pyannote.ai/tutorials/identification-with-voiceprints](https://docs.pyannote.ai/tutorials/identification-with-voiceprints)
6. speech-swift official repository: [https://github.com/soniqo/speech-swift](https://github.com/soniqo/speech-swift)
7. Qwen3-ASR official toolkit repo: [https://github.com/QwenLM/Qwen3-ASR-Toolkit](https://github.com/QwenLM/Qwen3-ASR-Toolkit)
8. NVIDIA NeMo speaker diarization guide 25.02: [https://docs.nvidia.com/nemo-framework/user-guide/25.02/nemotoolkit/asr/speaker_diarization/intro.html](https://docs.nvidia.com/nemo-framework/user-guide/25.02/nemotoolkit/asr/speaker_diarization/intro.html)
9. DiCoW paper on arXiv, submitted December 30, 2024: [https://arxiv.org/abs/2501.00114](https://arxiv.org/abs/2501.00114)
10. End-to-End Joint ASR and Speaker Role Diarization paper on arXiv, submitted January 25, 2026: [https://arxiv.org/abs/2601.17640](https://arxiv.org/abs/2601.17640)
