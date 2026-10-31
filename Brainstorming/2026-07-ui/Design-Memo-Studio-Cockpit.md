# Studio Mode Design Memo — "The Instrument"

*Design agent memo, July 25, 2026. Grounded in `DeepReadViewModel.swift`, `StandardPassRunner.swift`, `PatchReviewRunner.swift`, `PipelineInspectorView.swift`, `ConsensusType.swift`, and the Studio sections of `UI-OVERHAUL-PLAN.md` / `CONSENSUS-REMAKE-PLAN.md`. Companion memo: `Design-Memo-Three-Mode-Identity.md`.*

> **Note on conflict:** this memo retains an indigo/cyan channel convention; the companion memo argues for killing indigo entirely in favour of a warm carbon/ivory/amber palette. See the synthesis in `CONSENSUS-REMAKE-PLAN.md` — the resolution taken was the warm palette, with this memo's Loom, region architecture, and telemetry engineering adopted and recoloured.

## 0. Design stance — what kind of object is this?

The generic failure mode is known: a grid of frosted cards with sparklines. Studio should instead be **one purpose-built instrument**: a bench machine whose only job is to watch two transcription engines argue and a referee settle it. The physical reference set is the dual-trace oscilloscope and the broadcast master-control console: a machine has a **bezel** (matte, structural), **screens** (recessed, dark, glowing), **meters** (bar + peak-hold, not sparklines), and a **transport** (one strip saying what the machine is doing right now). Nothing floats. Nothing is glass. Every region is either bezel or screen-well.

**Standing theme rules this direction breaks:**

1. **No glassmorphism in Studio.** `.ultraThinMaterial` reads as consumer SaaS. Studio panels are opaque matte bezel (`#11151A`) with recessed screen-wells (`#07090B`, 1px inner shadow).
2. **Darker floor than Deep Slate** — `#0A0C0E`, so screen-wells can be darker still and glows have headroom.
3. **A channel-color convention.** Considered the authentic Tektronix CH1-yellow / CH2-cyan scope convention, but amber already means "warning/dispute" in ConsensusTheme, so overloading it would poison existing semantics.

**Studio palette as originally proposed (superseded on the warm-palette decision, retained for reference):**

| Role | Hex | Notes |
|---|---|---|
| Floor | `#0A0C0E` | below Deep Slate |
| Bezel | `#11151A` | matte, opaque |
| Bezel highlight | white 4%, 1px, top edge only | machined edge |
| Screen-well | `#07090B` | recessed; inner shadow + faint radial vignette |
| Hairline dividers | white 6% | |
| Engraved micro-labels | `#79828F` | Inter 9.5pt, uppercase, +8% tracking |
| Strand A (canonical) | `#818CF8` | indigo-400 |
| Strand B (second opinion) | `#22D3EE` | cyan-400 |
| Fused consensus line | `#E2E8F0` core + `#6366F1` glow | white-hot wire with halo |
| Dispute (open) | `#FBBF24` 60% stroke / 10% fill | |
| Verdict: accepted | `#34D399` | |
| Verdict: rejected/held | `#64748B` | a rejection is not an error |
| Live lamp | amber running / green complete / red fault | tally-light triple |

**Texture:** one pre-rendered 128×128 tiling noise PNG at 5% opacity multiplied over bezel surfaces only (never wells). Kills the flat-vector look at zero runtime cost. No scanlines, no CRT curvature — those tip into kitsch.

**Type:** JetBrains Mono for every numeral; Inter for labels; Source Serif 4 in exactly two places — the live transcript wire and the cloze sentence on the Bench — so *human speech is always serif, machine data is always mono*. That rule alone does more for identity than any color.

---

## 1. Layout — `StudioRootView`

Minimum window 1280×800; breathes at 1512×982. Five fixed regions; only the center column scrolls.

```
┌──────────────────────────────────────────────────────────────┐
│ TRANSPORT BAR (52pt, fixed)                                  │
├──────────────────────────────────────────────────────────────┤
│ THE LOOM (168pt, fixed, full width)  ← signature element     │
├───────────┬──────────────────────────────┬───────────────────┤
│ SEQUENCER │  CENTER STAGE                │  THE BENCH        │
│ RAIL      │  (flex, min 520pt, scrolls)  │  (336pt, fixed)   │
│ (264pt)   │  live: The Wire              │  live: cloze card │
│ fixed     │  post: Patch Audit           │  post: Review     │
│           │                              │  Trace detail     │
├───────────┴──────────────────────────────┴───────────────────┤
│ TICKER (28pt, fixed) — event log strip                       │
└──────────────────────────────────────────────────────────────┘
```

**Transport bar** — left: project title + `STUDIO` engraved badge. Center: current stage + elapsed clock (mono 22pt). Right: RTF readout (`0.21× RT`), thermal pip driven by `ProcessInfo.thermalState`, and the run lamp (10pt circle, 20pt glow, amber while running). RTF = elapsed ÷ (fraction × audioDuration).

**Sequencer rail** — a vertical mission-sequencer replacing the progress bar: one row per pipeline stage (Model prep, Transcribe A, Diarize, Merge, Second opinion load, Second opinion run, Diff, Verify, Gate), each with a state jewel (hollow pending / amber pulsing active / green done with wall-clock time / slate skipped). This is `stageTimings` made live. Below it, rack modules: **Process Rack** (rows per process with PID and RSS bar meter, 1.5s peak-hold pip) and **Environment** (memory-pressure lamp + thermal state — no fake "GB free" numbers).

**Center stage** — during a run, **The Wire**: the live transcript feed (`liveTranscriptionSnippets`) as Source Serif 15pt lines with a mono timestamp gutter, drawing downward, auto-scroll pausing on hover. During the second-opinion pass the Wire dims to 60% and Engine B's coverage draws as a progress rule alongside. Post-run, swaps to the Patch Audit table.

**The Bench (right rail)** — live: the adjudication card for the dispute under review. Post-run: the full Review Trace for the selected patch. When idle: "ADJUDICATOR — STANDING BY," engraved, with verifier model name and quantization.

**Ticker** — a 28pt mono strip showing the humanized last event from the sidecar's stderr NDJSON stream; click to freeze and pop a scrollable, copyable log sheet. Where the raw `{message, fraction}` lines the app already parses become visible instead of discarded.

**Live vs. finished run:** the same screen, two dispositions. Finished runs load the persisted flight record: clock freezes, lamp goes green, Loom becomes a scrubber, Wire becomes Audit, Bench becomes Trace detail. No separate "results screen" — the instrument shows what it recorded, like a scope in STOP mode.

**Idle state:** the Loom shows a flat fused line breathing a slow 0.4Hz glow, meters at zero with pilot-light pips lit, jewels hollow, Bench standing by. The machine is warm.

---

## 2. The signature element — **The Loom** (`ConsensusLoomView`)

One visualization carries the thesis: *consensus is forged from disagreement*. A dual-trace, full-duration timeline where the two engines' outputs are drawn as physical strands that fuse where they agree and split where they don't — and you watch the verifier weld the splits shut.

**Geometry.** Full-width screen-well, 168pt tall, content inset 16pt. X maps linearly to audio time. Centerline at y = 84. Layers, back to front:

1. **Waveform ghost** — audio envelope (decoded once at import via `AVAudioFile`, downsampled to ~2 samples/pt, cached per project), filled symmetric band around the centerline, white at 4%. Context only; never brighter.
2. **Speaker lane** — an 8pt band 12pt above the well floor: contiguous tinted blocks per diarized speaker at 70% opacity, 1pt gaps at turn boundaries. Draws in when diarization lands.
3. **The strands.** Where the engines agree: a single 1.5pt line at the centerline; once corroborated by both, the **fused wire** (bright core + additive glow, `.blendMode(.plusLighter)` — phosphor-like). Where they disagree, the line **splits into a vesica** (an "eye"): strand A arcs up, strand B arcs down, each a cubic Bézier with 12pt ease-in/lead-out at the dispute's boundaries. Aperture maps to dispute kind: text 10pt, speaker 12pt, both 16pt, missing segment 18pt — matching `PassDisagreement.Kind`. The open eye's interior fills amber at 10% with a 60% hairline while unresolved.
4. **Verdict scars.** When the gate rules, the eye collapses over 0.45s (spring, response 0.35, damping 0.8) back into the fused wire, firing a one-shot 250ms spark — an 8pt radial flash at the weld point. It leaves a permanent **scar tick**: 3pt×6pt under the line, green if a patch was accepted, slate if the canonical text held. Hover → tooltip with time + summary; click → selects the patch in the Bench/Audit.
5. **The beam head.** While an engine streams, its trace terminates in a 2.5pt bright dot with a 12pt glow — the scope's writing beam. During pass 1 only strand A draws (the pipeline is genuinely sequential; the design embraces that honestly). During the second-opinion pass, strand B's beam re-traverses the whole timeline left-to-right, fusing or splitting the line as it goes: **the single most satisfying live moment in the app** — you watch agreement literally form. During verification, no beam; eyes weld shut one at a time in review order.

**Post-run:** the Loom is the run's fingerprint — a bright wire with a constellation of scars — and doubles as a scrubber: click to seek, a 1pt playhead tracks playback, dragging across an eye/scar plays exactly that span.

**Implementation:** one `Canvas` inside `TimelineView(.animation(minimumInterval: 1/30))`, active only while running; static (event-redraw only) otherwise. Strand paths precomputed on data change; per-frame work is only the beam head, glow pulse, and in-flight collapses. Target < 1ms/frame; single layer, no view-per-segment.

---

## 3. The patch trace — the Bench and the Audit

**Live: `AdjudicationBenchView`.** One card, one dispute, laid out like a specimen on a bench:

- **Header:** `PATCH 07 / 23` · time span `12:34.2–12:37.9` · source badge (`SECOND OPINION` / `RE-LISTEN`).
- **The cloze.** The disputed sentence in Source Serif 15pt with `find` masked, the blank a recessed underline slot — a literal empty socket in the sentence.
- **Two candidate slugs**, stacked: 1px-edged chips (one edge per origin engine) containing candidate text in serif, with origin and confidence in mono beneath. They read as two pieces of type waiting to be set.
- **Audio strip:** a 24pt mini-waveform of the disputed window with a play button; plays just that span (the context-playback plumbing already exists).
- **Verdict row:** seal icon, the **public rationale** (`PatchEvent.reason`), confidence, and the guardrail line (`GATE: protected-term check passed`). On accept, the winning slug snaps into the socket — scale 1.06→1.00, 180ms, a letterpress stamp — and the loser dims to 30%. The card slides up into a "recent verdicts" stack (last 3) as the next dispute loads.

Framing: every string shown comes from the audit schema. The panel is titled **Review Trace**, its sections are `EVIDENCE` / `VERDICT` / `GATE`, and nothing is presented as the model's inner monologue — satisfying the no-chain-of-thought constraint structurally, not by relabeling.

**Post-run: `PatchAuditTable`** (center) + `ReviewTraceDetailView` (right rail). Table: one row per reviewed dispute — time, `find → replace` (strikethrough on the loser), source, confidence, verdict seal. Filters: All / Accepted / Held / By source. Selecting a row (or a Loom scar) fills the rail with the chain as a numbered evidence ledger: 1 Candidate origin → 2 Second-opinion source → 3 Re-listen result → 4 Cloze options → 5 Model + confidence → 6 Rationale → 7 Gate result → 8 Final disposition — each a hairline-separated row, mono labels, serif quotations, audio strip pinned top, "Locate in transcript" at bottom. Steps the pipeline skipped simply don't render.

---

## 4. Motion and refresh — three clock domains

An instrument is calm because different readouts move at different, *fixed* rates:

| Domain | Rate | What lives there |
|---|---|---|
| **Beam** (continuous) | 30fps via `TimelineView`, only while running | Loom beam head, glow breathing, collapses |
| **Meters** (sampled) | 10Hz publish, EMA-smoothed (α = 0.2) | tokens/sec bars, RSS bars, RTF; peak-hold pips hold 1.5s then decay 20pt/s |
| **Numerals** (quantized) | 2Hz max | every printed number; `.contentTransition(.numericText())`; fixed-width mono fields so layout never shifts |
| **Events** (discrete) | on occurrence | stage jewels, verdicts, ticker lines, welds — these get the springs |

Anti-jitter rules: continuous values never use springs; discrete events always do. A number and its bar may disagree for up to 500ms — correct instrument behavior (needle vs. digital readout), not a bug. `TelemetryCenter` (new actor) samples process stats at 1Hz on a `.utility` queue, keeps a 600-sample ring buffer, publishes an immutable snapshot; SwiftUI observes the snapshot, never the buffer.

---

## 5. Customization — a rack, not a canvas

"Completely customizable" should mean *configurable like a modular rack*, not a drag-anywhere dashboard builder. A free-grid layout engine is weeks of work and guarantees the generic look.

**Configurable** (persisted as `StudioLayoutConfig` JSON in `@AppStorage`):
- **Rack modules** in the left rail and post-run right rail: toggle + reorder from a fixed registry (`StudioModule` protocol: id, title, symbol, minHeight). Launch set: Sequencer (always on), Process Rack, Environment, Engine Meters, Run Manifest (the current `PipelineInspectorView` content folded in — the inspector sheet is retired), Recent Verdicts.
- **Loom overlays:** waveform ghost, speaker lane, scar ticks, swap strand colors.
- **Density:** Comfortable / Dense.
- **Numerals:** Smoothed (default) / Raw — Raw disables the EMA for people who want the twitch.
- **Ticker verbosity:** Verdicts only / All events / Off.
- **Audit table columns** and default filter.

**Opinionated, not configurable:** the five-region skeleton, the Loom's presence and position (a signature is non-negotiable or it isn't a signature), palette, typography, animation timings, and tick rates (letting users raise sample rates is how "must not slow inference" gets violated by settings).

---

## 6. Honest feasibility notes

1. **The biggest gap: the live review trace does not stream today.** `PatchReviewSidecar` emits only `{message, fraction}` progress lines; the full `Audit` (applied patches only) arrives once, from `audit.json`, after the process exits. The live Bench, live welds, and accept/reject tallies all require extending the sidecar's stderr protocol with typed NDJSON events (`dispute_opened`, `verdict`, carrying cloze candidates, re-listen text, rationale, guardrail result) — **and the audit schema must start recording rejected patches, which it currently doesn't** (`appliedPatches` only). Fully within our control (`run_patch_review.py` is ours) but real pipeline work, not UI work. Without it, v1 Studio can still weld eyes shut in batch when the audit lands — acceptable, not magical.
2. **Tokens/sec exists only for VibeVoice.** WhisperKit reports only a fraction — derive and label honestly as "audio s/s" and RTF; never fake a token rate. Verifier throughput needs the sidecar to parse `llama-mtmd-cli` timing output — cheap, same protocol extension.
3. **Process stats:** own-process RSS via `task_info` is public. Child RSS via `proc_pid_rusage()` works for same-user children and is fine for direct-download distribution — it would *not* survive App Store sandboxing (already ruled out). Grandchildren (llama, ffmpeg) need the sidecar to report their PIDs, or a `proc_listchildpids` walk.
4. **"Memory headroom" as a GB number doesn't exist as a public API.** Ship memory-pressure state (public `DispatchSource` events) plus per-process RSS; skip invented headroom figures. CPU/GPU die temperatures are SMC/private — `thermalState`'s four levels are the shippable truth.
5. **Performance:** 1Hz rusage sampling and 10Hz UI publishing are microseconds; the ML processes are separate OS processes, so UI cost cannot slow inference. The only real risk is the Loom's 30fps canvas competing for GPU on battery — hence beam animation only while running, static otherwise, paths precomputed off the render loop.
6. **Post-run persistence:** stage timings and patch notes persist on `TranscriptPass`, but time-series (tokens/sec curve, RSS) and the full trace do not. Add a `FlightRecorder` writing a downsampled `studio-trace.json` (~100–200KB cap) beside the project so a finished run replays faithfully; without it, reopened projects show scars and the audit but empty meters — graceful degradation.
7. **Waveform ghost** needs a one-time envelope decode at import (tens of ms per hour of audio) cached per project — trivial, but a new import step.

**Build order matching value:** Loom (batch welds from existing audit) + transport + sequencer first; sidecar NDJSON protocol second (unlocks live Bench and live welds); process rack + flight recorder third; rack customization last.
