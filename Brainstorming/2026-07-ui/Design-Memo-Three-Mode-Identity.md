# Consensus UI Revamp — Design Direction Memo

*Design agent memo, July 25, 2026. Grounded in the 15 live views in `App/Views/`, `Theme/ConsensusTheme.swift`, `App/Theme/ConsensusType.swift`, `App/Model/ModeState.swift`, `CONSENSUS-REMAKE-PLAN.md` (Goal B), `UI-OVERHAUL-PLAN.md`, `SIMPLE-MODE-DESIGN.md`. Companion memo: `Design-Memo-Studio-Cockpit.md`.*

---

## 1. Diagnosis: why the current aesthetic reads as "AI-generated"

The confidence colors `#34D399`, `#FBBF24`, `#F87171` are, verbatim, Tailwind CSS `emerald-400`, `amber-400`, `red-400`. The accent `#6366F1` is Tailwind `indigo-500`. The background is the blue-gray near-black every 2025-era generated app converged on. This isn't a criticism of the earlier work — it followed the spec — but the spec itself *is* the house style of AI-coded software. The tells:

1. **Tailwind token palette on a desaturated slate ground.** Indigo accent + emerald/amber/red traffic lights is the single most recognizable signature.
2. **Card-on-card glassmorphism.** `.ultraThinMaterial` + 1px `white/8%` border + continuous rounded corners, nested. Everything floats; nothing is anchored.
3. **Chip proliferation.** At least five capsule-chip rows (mode, speed, engine, domain, clean/verbatim). Chips are the generated-UI answer to every choice.
4. **The metric-tile grid.** Icon + uppercase eyebrow + big number in a rounded rect, repeated ×4 (`TranscriptionMetricTile`).
5. **Indigo→green gradient progress capsule.** Decoration pretending to be information.
6. **Inter for everything, opacity-fade transitions everywhere.**

The good news: the typography layer already contains the escape hatch. `ConsensusType.swift` bundles **Source Serif 4** and **JetBrains Mono**, and the transcript already renders in serif. The identity below is mostly promoting what's latent and deleting the Tailwind layer.

---

## 2. Visual identity: **"Instrument & Record"**

**The metaphor:** Consensus takes competing machine testimony, cross-examines it against the audio, and enters a verdict into the record. The interface is built from exactly two materials:

- **The Instrument** — the machine world: engines, telemetry, disagreement, progress. Broadcast/measurement hardware: flat matte panels, hairline rules, engraved monospaced labels, meters and lamps. Disagreement lives here.
- **The Record** — the human world: the transcript. A typeset deposition under a reading lamp: warm ivory serif on dark umber, ruled margins, line-numbered gutter, editorial marks. Consensus lands here.

The core visual event is *text graduating from Instrument to Record* — disputed spans carry instrument markings until the verifier's verdict clears them.

### 2.1 Palette (replaces the Tailwind set)

| Token | Hex | Use |
|---|---|---|
| `carbon` (app ground) | `#151311` | Warm near-black. Not blue. |
| `panel` (instrument surface) | `#1C1916` | Flat, opaque. No materials, no blur. |
| `hairline` | `#F5EDE0` @ 10% | 1px rules — the structural element |
| `recordSurface` | `#211D17` | The transcript "paper" — dark umber |
| `recordInk` | `#E8DFCC` | Transcript ivory (not white) |
| `meterAmber` | `#E8A33D` | Live telemetry numerals, in-progress state |
| `signalRed` | `#D9482B` | Disagreement, recording lamp, unresolved patches |
| `ledgerGreen` | `#5F8F6B` | Verdict stamps only — never fills, never badges |
| `gutter` | `#8A8272` | Timecodes, line numbers |

Speaker identity: kill the 12-color candy dot palette. Six muted archival tones (`oxide #6E8CA0`, `sienna #B07A50`, `olive #8F9464`, `plum #96738F`, `teal #6E9C94`, `ochre #C0A05C`) rendered as a **2px left rule in the margin** of each speaker's turns plus a small-caps name — deposition style — not filled circles.

The warm axis matters: blue-black + indigo is the generated look; warm carbon + ivory + amber/vermilion reads as hardware and print. Nothing here is neon.

### 2.2 Materials and structure — the rules this breaks

- **Glassmorphism is deleted.** No `.ultraThinMaterial` anywhere. Instrument panels are flat `#1C1916` separated by hairlines; the Record is a single continuous sheet, not a card. *Breaks the standing "glassmorphism cards" rule.*
- **Indigo is deleted.** Meter amber is the working accent; signal red is the alert ink. *Breaks the "#6366F1 accent" rule.*
- **Corner radius: 2px on instrument elements, 0 on the Record sheet.** Softness reads as consumer SaaS; hardware and paper have edges.

All three are deliberate. Dark, no-emoji, public-facing, identity-tied-to-function all hold. Take the trade as a package — cherry-picking (e.g. keeping indigo on the new materials) produces the worst of both.

### 2.3 Typography

All three families are already bundled — this is a role reassignment in one file:

- **Source Serif 4 (Display optical sizes) becomes the display voice.** Wordmark, screen titles, speaker names. A serif-titled dark app is nearly extinct among generated UIs; it also *is* the legal-record voice. Wordmark: "Consensus" in Source Serif 4 Display semibold with a double hairline rule beneath, letterhead-style.
- **JetBrains Mono is the instrument voice.** All numerals, all micro-labels — uppercase, 10–11pt, +6% tracking, engraved (`gutter`). Rule: *if a number can change, it is mono.*
- **Inter demotes to controls only** — buttons, toggles, form text, 13pt, quiet.
- **Editorial sigils as iconography accent:** patched turns get a superscripted dagger (†¹, †²) in the Record margin, resolving to the exhibit card. SF Symbols remain for chrome, thin-stroke only.

Optional later spend: a licensed distinctive mono (e.g. Berkeley Mono, ~$75). Not required.

### 2.4 How disagreement and agreement render

- **The Record Strip** (port and promote `DisagreementHeatmapView`): a full-width chart-recorder strip under the header — downsampled waveform in `hairline`, disagreement spans as `signalRed` ticks above the trace (text disputes above, speaker disputes underslung), playhead a 1px amber needle. As patches are reviewed, ticks are **struck** — a 120ms pen-stroke wipe to `gutter` — so the strip literally clears as consensus forms. The signature image of the app.
- **In the Record:** disputed spans get a dotted `signalRed` underline + margin dagger — proofreader's marks, not amber-filled rounded boxes. Resolved spans drop all marking; agreement is the *absence* of ink, which is correct semantics.
- **The exhibit card** (evolved from the current uncertainty popover, which already has the right content): flat panel, ruled header in mono caps — `EXHIBIT 3 — TURN 14 — 00:12:41` — candidates A/B in serif, verifier verdict line, and a small `ledgerGreen` `VERIFIED` or `signalRed` `REVERTED` stamp on action.

### 2.5 Motion

- **No opacity/scale crossfades.** Stage advances move one direction — content feeds upward 20px, 180ms ease-out, like paper through a platen. Pipeline order = spatial order.
- Mode switch detent: 80ms snap, no bounce. Meters move continuously (driven by real token streams). Strikes and stamps are fast (≤120ms) and singular. Nothing pulses, breathes, or shimmers.

---

## 3. Mode architecture: one surface, two depths, plus a rack

**Recommendation: keep the three named modes, but implement them as (a) a window-level three-position switch in the header — `QUICK / DEEP / STUDIO` in engraved mono caps — governing depth of a single shared flow, and (b) Studio surfaces as a toggleable "rack" (bottom console drawer + trailing trace rail) that can open on any project, not a third parallel UI.**

`ModeState.swift`'s own doc comment says all three modes share the same nine-stage pipeline and "the mode only governs how many stages are interactive." Studio today is already just gated extras. Formalize that truth instead of fighting it.

- **Quick = the flow asks nothing** (auto tier, no setup stage, simplified progress/result).
- **Deep = the flow asks its five questions** (today's setup card, naming, review).
- **Studio = Deep + the rack open + all knobs revealed.** The rack (⌘\) is available in Deep too — a place you open, not a fork you pre-commit to.
- **Telemetry records in every mode** (cheap JSON the pipeline already produces). Movement between modes is lossless.
- **Mid-project movement is monotonic upward:** Quick Take's result carries one quiet affordance — "Open full review" — re-rendering the same saved project at Deep depth. No re-processing, no downgrade path needed.

**Rejected alternatives:**

1. **Separate windows/apps per mode.** Kills the "Quick Take finished → dig in" handoff, triples chrome, hides depth. The CLI already covers "different launcher for a different audience."
2. **Status quo: mode chips as per-project setting on the drop screen.** Mode-as-content invites three diverging UIs, and greeting every user — including the foolproof-tier user — with a three-way taxonomy decision is self-defeating. Mode belongs in chrome, chosen rarely, remembered.
3. **Pure progressive disclosure, no named modes.** Cleanest in theory, but Quick Take's contract ("never a scary alert") needs a hard flag the error layer can check, not a hope that panels stayed collapsed.

---

## 4. Quick Take — the actual screens

**Screen 1 — Drop.** Wordmark + double rule, one drop plate, up to three recent projects as ruled rows, footer: "All processing happens on this device." Dropping a file **starts immediately**; there is no setup screen in Quick Take.

**The 2–3 options, none of which block the start:**
1. **Clean / Word-for-word** — two-position switch on the *result* screen, applied instantly post-hoc (the `StylePair` architecture keeps both renderings; zero recompute).
2. **Speaker names** — after processing, one optional pass: "Who is Speaker 1?" with a play button and text field per voice, `Skip` always visible. The one input only the human has.
3. **Copy / Save** — large `Copy transcript` and a `Save…` menu.

**Cut, and why:** speed tier (auto-gate on duration, logic already exists); engine choice (meaningless to this user); domain hint; summary/to-dos (useful, but a fourth decision plus added wait — revisit as automatic post-export); the verifier-missing alert (already decided June 30: degrade silently).

**Progress for the 8-minute wait** (36-min file at the validated 0.21× RTF):
- **A trustworthy ETA, biggest element on screen** — "About 6 minutes left," computable from measured RTF within ~30s, amber mono. Honest countdowns beat percentages for long waits.
- **The live transcript feed** — already built; the best reassurance possible. Strip the update-counter and engine chrome; render snippets on the Record surface in serif so the user watches *their document being typed*.
- **Plain-language stage line:** "Listening to the recording… / Writing the draft… / Double-checking the hard parts… / Tidying up." Never an engine name, never tokens/sec.
- **Leave-it-running support:** dock-icon progress and a completion notification. For an 8-minute wait this is the design, not polish.
- On failure of any optional stage: no dialog, ever.

---

## 5. Studio — where the identity pays for itself

Replace the current `PipelineInspectorView` modal (a key-value list in a 560×520 box) with two docked regions:

- **The Console** (bottom drawer, ~220px): one **channel strip per engine** — engraved nameplate, live meter (tokens/sec as a VU-style amber bar), RTF readout, stage lamp (idle / running amber / done gray / flagged red), stage timings.
- **The Trace** (trailing rail, ~360px): the chronological Review Trace — every flag → playable audio evidence → candidate A/B → verdict → stamp, as exhibit cards. Goal A5's "LLM proposes, gates dispose" architecture feeds this UI for free.
- The Record Strip becomes fully interactive in Studio: click any tick to scrub and open its exhibit.

---

## 6. The single highest-leverage change

**Build the persistent frame — header + Record Strip — and make every stage render inside it, replacing the stage-teleport and the six modal sheets.**

Today `DeepReadRootView` is a stage router that swaps the *entire screen* eight times, plus six disconnected `.sheet`s. That is, literally, "a set of screens." The fix: from the moment audio lands until export, the top of the window is constant — project title (serif), duration, mode switch, Record Strip — and stages change only the region beneath. Import draws the waveform; transcription fills it left-to-right behind the amber needle; review shows red ticks being struck; export slides up under the strip, not over it. The strip is simultaneously the identity element, progress indicator, review navigator, and audio scrubber — one object carrying the whole narrative of consensus being forged.

**Risk/cost flags:**
1. The persistent frame is the one genuinely structural item — roughly a rewrite of `DeepReadRootView`'s routing plus panel plumbing. Everything else is skinning and token changes.
2. Waveform rendering needs downsampled peak extraction at import and a virtualized strip for 2-hour files — bound it to ~2,000 peak buckets computed once and cached in the project bundle.
3. The warm palette needs WCAG AA checking at small mono sizes (`#8A8272` on `#1C1916` is borderline for body text; keep to labels ≥10pt medium or lighten one step).
4. Killing indigo/glassmorphism contradicts standing written rules — get explicit owner sign-off, and update `CLAUDE.md` and `ConsensusTheme.swift` in the same commit so the old style can't reassert itself.
