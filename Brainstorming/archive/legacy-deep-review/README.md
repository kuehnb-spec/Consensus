# Legacy Deep Review Archive

Archived on May 1, 2026 when Consensus pivoted its active Deep Review architecture from full-transcript LLM reconciliation to the patch-centered tool editor.

The archived `DeepPassRunner.full-llm-reconcile.swift` records the prior rewritten-UI Deep pass:

- Engine A produced a Standard transcript.
- WhisperKit produced a full second transcript.
- `LLMReconcileService` read both complete transcripts and wrote a new reconciled transcript.

That path is no longer part of the active app flow. The current app centers Deep Review on VibeVoice as the canonical transcript, a second ASR as a disagreement heatmap, local VibeVoice re-listen, masked-cloze audio verification, and deterministic exact patches.
