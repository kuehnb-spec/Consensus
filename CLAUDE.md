# Consensus (formerly BDK Transcribo) — Claude Code Context

A privacy-first macOS transcription app with speaker diarization, multi-engine Deep Review, and reconciliation workspace. Built with SwiftUI, WhisperKit, and FluidAudio. macOS 15+.

## Active Work: UI/UX Overhaul

The app is undergoing a comprehensive visual redesign from "utility" to "high-end workstation" (Linear/Raycast quality). See `UI-OVERHAUL-PLAN.md` for the full phased plan with file manifest, phase status, and architectural decisions.

Key design rules for all new UI work:
- **Dark mode enforced** — Deep Slate background, no light mode assumptions
- **Accent color** — Indigo (#6366F1) for primary actions and AI highlights
- **Typography** — SF Pro for body, SF Mono for timestamps/percentages/metadata
- **Cards** — Glassmorphism (`.ultraThinMaterial` + 1px border), no GroupBox
- **Use `ConsensusTheme`** — All colors, fonts, spacing from the centralized theme. No hardcoded values.
- **No emojis** — Use SF Symbols for all icons

## Project History Logging

**At the end of every coding session**, append a dated entry to `PROJECT_HISTORY.md` in this project's root directory summarizing what was worked on. Include:
- The date
- What was built, changed, or fixed
- Key design decisions made and why
- Any direction changes or pivots
- Problems encountered and how they were resolved

Keep entries concise (3-8 lines). Write in past tense, narrative style. This log feeds the project's page on brantkuehn.com.
