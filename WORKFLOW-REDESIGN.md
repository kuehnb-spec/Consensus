# Consensus — Workflow & Pipeline Redesign

## Date: March 25, 2026

This document captures the full redesign plan for Consensus's workflow, UI structure, and Deep Review pipeline. It addresses three interconnected problems discovered during testing:

1. The reconciliation UI was overwhelming (558 disputed segments on a 53-minute call)
2. The workflow steps are confusing (5 numbered steps with "optional" middle steps)
3. Transcription and diarization are entangled in ways that make comparison meaningless

---

## Part 1: UI & Workflow Restructuring

### Problem

The sidebar presents 5 numbered steps: Transcribe, Review Speakers, Deep Review (optional), Reconcile, Export. This creates confusion:

- "Optional" steps 3-4 aren't optional additions to a linear pipeline — they're a completely different workflow path. The UI presents one pipeline with skippable steps instead of two distinct workflows.
- "Deep Review" and "Reconcile" are implementation concepts, not user goals. Nobody thinks "I want to reconcile two transcription passes." They think "I want to make sure this transcript is accurate."
- After transcription finishes, there's no explicit decision point — just a list of grayed-out steps.
- The Quality view does too many things: metrics dashboard + Deep Review configuration + pass comparison + hotspot browser.

### Solution: Two Clear Paths, One Decision Point

After transcription completes, present an explicit fork:

```
                    ┌─── Export Now ──────────────────→ Export
Transcribe → Review │
                    └─── Verify Accuracy ─→ Review ─→ Export
                         (runs 2nd engine,
                          auto-merges,
                          flags ~20 spots)
```

### New Sidebar Structure (3 Phases, Not 5 Steps)

**Phase 1: Transcribe**
- Same as today. Drop audio, pick model, run.
- Checkmark when done.

**Phase 2: Review**
- Speaker renaming (same as today).
- After renaming, a **decision card** appears at the top of the view:

> **Your transcript is ready.**
> 8,432 words across 4 speakers, 87% average confidence.
>
> [Export Now]  — Use this transcript as-is
> [Verify Accuracy] — Run a second engine to catch mistakes
>                      (adds ~5 min, typically finds 15-25 spots to check)

"Export Now" jumps to Export. "Verify Accuracy" launches the verification sub-flow.

**Phase 3: Export**
- Same as today, always available once a transcript exists.

### The "Verify Accuracy" Sub-Flow

This is NOT a sidebar step — it's a modal workflow launched from the decision card in Review. It:

1. Shows a brief configuration (engine choice, with smart default) + "Start" button
2. Runs the second engine with a progress screen
3. Auto-merges using confidence-weighted word alignment
4. Shows the merged transcript with inline flags at ambiguous spots
5. User resolves flags (keyboard-driven) or accepts all
6. Saves consensus → returns to Review with the improved transcript
7. User proceeds to Export

### Contextual Guidance Banners

Each phase shows a one-line banner explaining what happened and what to do:

- After transcription: "Transcript complete with [N] speakers detected. Review and rename speakers below."
- After speaker renaming: "Speaker names saved. Export your transcript or verify accuracy with a second engine."
- During verification: "Running second engine for comparison... [progress]"
- After merge: "[N] spots flagged for review out of [M] words."
- After flags resolved: "All flags resolved. Save to update your transcript, then export."
- After export: "Exported to [path]."

### Quality Metrics Become an Inspector

The Quality dashboard (confidence gauges, heatmap, pass history) moves from a required workflow step to an **info panel** — a button or disclosure in the Review phase. Always available for power users, never blocking the workflow.

### Deep Review Configuration Simplifies

The engine/model picker becomes part of the "Verify Accuracy" launch. When the user clicks it, an inline section expands with:
- Engine choice (defaulted to recommended)
- "Start" button
- One sentence about what will happen
- "Advanced" disclosure for power users wanting threshold control

---

## Part 2: Pipeline Architecture Redesign

### Problem Discovered in Testing

Running WhisperKit Large v3 + Parakeet on a 53-minute call produced:
- Text Agreement: **5%**
- Speaker Agreement: **31%**
- Disputed Segments: **558**

The 5% text agreement doesn't mean the transcripts are 95% wrong — it means the comparison algorithm is too literal. The engines produce the same *meaning* but with different punctuation, filler words, sentence boundaries, and formatting. String-level comparison amplifies trivial differences into hundreds of "disputes."

Additionally, trying to reconcile transcription AND diarization simultaneously creates cascading disagreements — a 0.5-second speaker boundary difference ripples through neighboring segments.

### Root Cause: Transcription and Diarization Are Entangled

The current pipeline runs transcription + diarization as a unit for each engine, then tries to compare the combined result. This means:
- Different segmentation → different word groupings → different text blocks → text disagreement
- Different diarization → different speaker labels → speaker disagreement even when both heard the same words
- These compound: a segment that's attributed to different speakers AND has slightly different text looks like a major dispute, but it's just boundary noise

### Solution: Separate Transcription Merge from Diarization

**New Pipeline:**

```
Step 1: Get Text (multiple engines)
  ├── Engine A (WhisperKit): words + timestamps + confidence
  └── Engine B (Parakeet): words + timestamps + confidence
         ↓
Step 2: Merge Text (semantic, not string-level)
  Use ROVER-style word alignment or LLM-assisted merge
  to produce a single best transcript with word timings
         ↓
Step 3: Run Fresh Diarization (on merged text)
  Apply diarization to the merged result, not to each engine's output
  Use the existing multi-engine diarization (SpeakerKit + FluidAudio)
         ↓
Step 4: Re-apply Speaker Names
  Match new diarization labels to existing speaker mapping
  by comparing time-overlap patterns with the original labeled run
         ↓
Step 5: Flag Only Genuine Ambiguities
  - Low-confidence words where both engines scored poorly
  - Missing phrases (one engine heard something the other didn't)
  - Named entity disagreements (names, numbers, dates)
  - Speaker boundary disputes from diarization
```

### Why This Order Matters

- **Text first, speakers later**: The question "what was said?" is independent of "who said it?" Solving them separately produces better results for both.
- **Fresh diarization on final text**: Instead of reconciling two different diarization runs that were based on two different transcripts, run diarization once on the best text. One set of speaker boundaries, one set of labels.
- **Speaker name mapping carries forward**: The user already named speakers in Step 2. After re-diarization, match new speaker IDs to old ones by time overlap (e.g., if SPEAKER_0 in the new run covers 85% of the time that "Sarah" covered in the old run, the new SPEAKER_0 is Sarah).

### Merge Approaches to Investigate

**ROVER (Recognition Output Voting Error Reduction)**
- Classic approach from NIST speech recognition evaluations
- Creates a "word transition network" by aligning all transcripts using dynamic programming
- At each position, multiple word hypotheses compete
- Confidence-weighted voting picks the winner
- Produces a single merged transcript
- Well-studied, reliable, but needs adaptation for our word-timing data

**LLM-Assisted Semantic Merge**
- Send time-aligned chunks (~30 seconds each) from both transcripts to the local LLM
- Prompt: "Here are two transcripts of the same 30-second audio segment. Produce the most accurate version."
- Pro: Handles semantic equivalence naturally (e.g., "$14.8 million" vs "14.8 million dollars")
- Con: Token limits for long transcripts; local LLM quality varies; adds processing time
- Could be used as a second pass after ROVER to clean up remaining disagreements

**Chunk-Based Semantic Comparison**
- Split both transcripts into time-aligned chunks (~30 sec) based on word timestamps
- Normalize each chunk: strip filler words, normalize numbers, lowercase
- Compare chunks semantically (jaccard on word sets, not exact strings)
- Where chunks are semantically equivalent (>80% word overlap after normalization), pick the higher-confidence version wholesale
- Only flag chunks where there's genuine semantic divergence
- This reduces 558 disputes to maybe 10-20 real disagreements

**Hybrid Approach (Recommended)**
1. Word-level alignment using timestamps (what ConfidenceMergeService already does)
2. Chunk-level semantic comparison to filter out trivial differences
3. LLM assist for the ~10-20 genuinely ambiguous spots
4. Fresh diarization on the merged result
5. Speaker name re-mapping

---

## Part 3: Implementation Priority

### Phase A: Pipeline Fix (highest impact)
1. Separate transcription merge from diarization
2. Implement chunk-based semantic merge (much less noisy than word-level or sentence-level)
3. Run fresh diarization on merged result
4. Re-apply speaker names from existing mapping

### Phase B: UI Restructuring
1. Collapse sidebar to 3 phases (Transcribe, Review, Export)
2. Add decision card after speaker naming
3. Make "Verify Accuracy" a sub-flow within Review
4. Move Quality metrics to an inspector panel
5. Add contextual guidance banners

### Phase C: Merge Quality Improvements
1. Research and potentially implement ROVER
2. Add LLM-assisted disambiguation for remaining ambiguous spots
3. Improve flag detection (named entities, numbers, proper nouns)

---

## Open Questions (Resolved)

- Chunk size: adaptive based on speaker turns (implemented)
- LLM pass: automatic during Deep Review wizard (user reviews results, not process)
- Speaker re-mapping: automatic by time overlap, user confirms in Step 3
- Engine abstraction: show the user what engines ran in the status pane, but don't require them to configure it

---

## Part 4: Advanced Mode Workflow Rewrite (March 27, 2026)

### Problem

The workflow was cobbled together over multiple sessions. It has:
- Dead code paths (old QualityView Deep Review config, old 3-column reconciliation)
- Unclear navigation (when is a project "done"? what should I click next?)
- Scattered status information (GlobalStatusBar, floating ProcessLogView, inline progress in views)
- No guided sequencing for Deep Review (user can jump between Quality, Reconcile, Review freely)

### Solution: Two Phases, Guided Wizard, Unified Status Pane

**Phase 1: Standard Transcription**

```
Upload audio → Pick engine (WhisperKit/Parakeet) → Transcribe + Diarize
→ Review transcript → Label speakers
→ Terminal Point 1: "Export as Standard" or "Enter Deep Review"
```

**Phase 2: Deep Review (guided wizard, all-or-nothing)**

```
Step 1: Deep Transcription
  - Run second engine (auto-selected)
  - Confidence-weighted merge
  - Show summary + flags for review

Step 2: Deep Diarization
  - Multi-pass SpeakerKit + FluidAudio
  - LLM boundary confirmation
  - Show summary of changes

Step 3: Confirm Speakers
  - Auto-mapped names from Phase 1
  - User confirms or adjusts

Step 4: Review & Compare
  - Before/after summary
  - Final transcript preview
  - Terminal Point 2: "Export as Verified"
```

**Unified Status Pane (right side, always visible during processing)**

Shows in one place:
- Overall progress (which phase, which step, visual step indicator)
- Current operation (what's running, progress bar, ETA)
- Next steps preview
- Live transcription output as it streams
- Quality metrics as computed
- Process log entries (replaces floating ProcessLogView)
- CPU/GPU usage indicators (if feasible)

Not interactive — all interaction in the main work area. The user can look at the status pane at any time and know exactly what's happening.

**Quality Tier in Export**

Optional checkbox in export settings: "Include quality tier badge"
- Standard Transcript: first-pass transcription
- Verified Transcript: completed Deep Review

### Implementation

Six phases:
1. Model layer (WorkflowPhase enum, quality tier, export preferences)
2. Sidebar rewrite (two-phase layout, Deep Review step indicators)
3. Deep Review wizard views (4 new step views + ViewModel refactor)
4. Unified Status Pane (replaces GlobalStatusBar + floating ProcessLogView)
5. Export changes (quality tier checkbox + badge)
6. Dead code removal (ReconciliationService, old models, QualityView gut)

### Dead Code to Remove

- `ReconciliationService.swift` — entirely superseded by ConfidenceMergeService
- Old `ReconciliationDraft`, `ReconciliationRow`, `ReconciliationSourceChoice` types — dead
- `PassComparisonService` — absorbed into DeepReviewCompareView
- `QualityView` deep review config section — replaced by DeepTranscriptionView
- ViewModel properties: `reconciliationDraft`, `reconciliationSelectedRowID`, `reconciliationPlayingRowID`, all old reconciliation methods
- Floating `ProcessLogView` — absorbed into StatusPaneView
