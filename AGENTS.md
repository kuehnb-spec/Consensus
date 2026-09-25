# Consensus (formerly BDK Transcribo)

A privacy-first macOS transcription app with speaker diarization, multi-engine Deep Review, and reconciliation workspace. Built with SwiftUI, WhisperKit, and FluidAudio. macOS 15+.

## Active Work: "Consensus Next" identity (approved 2026-09-25)

The UI is being rebuilt around the legal record. Brant approved the direction
in `Brainstorming/2026-09-next/consensus-next.html` (proposal + interactive
mockup + motion reel). It **replaces** the older indigo/glassmorphism rules and
`UI-OVERHAUL-PLAN.md`'s styling (kept only as history).

Design rules for all UI work:
- **Two materials.** The *Desk* is the dark instrument chrome (flat, hairline
  rules, no blur). The *Record* is the transcript as a sheet of paper, day
  (bond white) or night (umber), set inside the desk.
- **The Record is typeset like a certified transcript:** page:line numbers in
  the gutter, speaker names in small caps with a colon, citable positions
  ("Cite 14:7").
- **Uncertainty is highlighter, not alarm.** Disputed spans get a highlighter
  stroke; settled spans keep only a faint dotted underline. Red is reserved
  for real failures.
- **Type roles:** Source Serif 4 for the Record, titles and speaker names;
  JetBrains Mono for every number that can change, timecodes and engraved
  labels; SF Pro for controls only. Inter is retired.
- **No indigo, no glassmorphism (`.ultraThinMaterial`), no Tailwind palette,
  no chip rows.** Speakers use the muted archival tones, shown as margin rules
  and lanes, not filled dots.
- **Motion reports events, never decorates:** threads converge (signature),
  wet ink dries, highlighter swipe/erase, re-listen loupe, speaker lanes,
  line counter and one seal on Verified. Honor Reduce Motion with instant
  state changes.
- **Use `ConsensusTheme`** for every color, font, spacing and motion value.
  No hardcoded values.
- **No emojis.** SF Symbols, thin-stroke, for chrome only.

## Project History Logging

**At the end of every coding session**, append a dated entry to `PROJECT_HISTORY.md` in this project's root directory summarizing what was worked on. Include:
- The date
- What was built, changed, or fixed
- Key design decisions made and why
- Any direction changes or pivots
- Problems encountered and how they were resolved

Keep entries concise (3-8 lines). Write in past tense, narrative style. This log feeds the project's page on brantkuehn.com.
