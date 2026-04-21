# Consensus — Fresh Attack Plan

**Date:** April 20, 2026
**Author:** Claude Opus 4.7
**Scope:** Take a fresh look at the diarization quality problem and propose a plan that cuts through the accumulated complexity. Also propose a two-mode UI (Simple / Advanced) that makes the product coherent.

**Status:** Phase-1 Slice 1 shipped April 20, 2026 — conversational-logic boundary proposer (`ConversationalBoundaryService.swift`) wired into `refineSpeakers()`, plus SpeakerKit confidence proxy replacing the hardcoded 1.0. Codex research response (`2026-04-20 - Codex Research Response.md`) reshaped the plan: LLM arbiter is now scoped to constrained edits over low-confidence spans only, voice library is reframed as identity continuity (not a boundary fix), MeetEval+dscore benchmarking is a gate, and LS-EEND CALLHOME ONNX becomes the single highest-leverage telephone-domain addition.

---

## 1. The honest diagnosis

The current pipeline is doing a lot of clever things and has high-quality components. The reason diarization still feels brittle is **not** a missing model — it's that every mechanism in the pipeline operates on the same kind of evidence (acoustic embeddings at segment level) and then votes among those. When the underlying acoustic signal is ambiguous (phone-band audio, same-gender speakers, short back-channels), more votes of the same kind don't help.

Three specific structural issues:

1. **Acoustic-only decisions at the bottom.** SpeakerKit + FluidAudio + multi-threshold passes all return *segment-level* speaker labels derived from clustering spectral embeddings. They disagree in different places but share the same failure modes on similar voices or short utterances.
2. **The LLM is used too narrowly.** It arbitrates *boundaries* and polishes *text*, but never looks at the full transcript-plus-labels as a document and reasons about attribution globally. That's the one signal channel that's *orthogonal* to acoustics, and it's been treated as a decoration.
3. **No self-enrollment.** Every recording starts cold — the pipeline re-discovers speakers from scratch even when the user has labeled the same people in prior projects, and even when the current recording has long high-confidence segments that could anchor shorter ones.

The good news: the existing stack is the right foundation. Everything below is an addition, not a rewrite. The forced-alignment scaffolding is the key piece that unlocks the next phase — word-accurate timings let us do things the old pipeline couldn't.

---

## 2. The fresh frame: "what signal are we actually using?"

Think of diarization as fusion across **five independent signal channels**. Today we use two. Adding the other three is how we break through the ceiling.

| Channel | What it measures | Today | Proposed |
|---|---|---|---|
| **Acoustic spectral** | Voiceprint-style embeddings | SpeakerKit + FluidAudio, multi-pass vote | Keep as-is |
| **Acoustic prosodic** | Pitch (F0), speaking rate, pause patterns | Unused | Small, fast, 10–20 ms resolution; use as parallel boundary detector |
| **Lexical/conversational** | Question→answer patterns, back-channels, self-reference pronouns, introductions | Used only at LLM polish stage | Make it a *first-class* signal with its own scorer |
| **Semantic coherence** | Whether a "turn" is internally consistent in topic/stance | Unused | LLM arbiter pass — re-scores every attribution against full-transcript context |
| **Cross-session memory** | Voiceprints of known people from prior projects | Unused | Voiceprint library — recognize recurring speakers by name on first pass |

Every one of these is cheap. Combined, they turn a segment-level classifier into a multi-signal attribution engine with the LLM as global arbiter instead of janitor.

---

## 3. The proposal (ranked by leverage)

I'm ordering these by expected impact *per unit of work*, not by effort. Items labeled **[SHIP]** are high-confidence gains; **[EXPERIMENT]** are speculative but cheap to try; **[RESEARCH]** need deeper exploration before committing.

### 3.1 LLM-as-Arbiter, not polisher  **[SHIP]**

**Core idea.** Instead of running the LLM on individual boundaries (current `confirmSpeakerBoundaries`), run it once on the whole attributed transcript and ask it to propose attribution fixes. Modern Qwen 3 8B at 4-bit handles ≥16K tokens on an M-series machine — a 60-minute transcript fits.

**The prompt is the product.** A well-designed prompt gives the model:

- The full transcript with provisional speaker labels and timestamps
- Per-word confidence (where available)
- Known speaker metadata (number of speakers, names if provided, call type)
- Explicit rules for what to flag: questions that answer themselves, back-channels attributed to the main speaker, impossible pronoun chains ("I was there" → "I agreed with myself"), missing intros ("Hi, this is X" attributed to the wrong speaker)

It returns a JSON list of proposed edits:

```json
[
  { "start": 127.3, "end": 128.1, "current": "SPEAKER_0",
    "proposed": "SPEAKER_1", "reason": "back-channel 'mhm' inside Speaker 0's turn" },
  { "start": 892.4, "end": 905.7, "current": "SPEAKER_1",
    "proposed": "SPEAKER_0", "reason": "answer follows Speaker 0's question; content refers to Speaker 0's earlier claim" }
]
```

The acoustic pipeline then *verifies* each proposed edit by extracting a short embedding and comparing against the enrolled speaker centroids. If acoustic verification agrees or is ambiguous, the edit is applied. If acoustic verification strongly disagrees, the edit is flagged for user review.

**Why this is different from what's there.** `refineSpeakers` today proposes acoustic candidates, then asks the LLM to confirm. This inverts that — the LLM proposes attribution changes based on **transcript logic**, and acoustics confirms. The LLM is far better at catching "this is a question without an answer" than any acoustic diarizer will ever be.

### 3.2 Self-enrollment on first pass  **[SHIP]**

**Core idea.** After first-pass diarization, identify the most confident "gold" segments for each speaker (long, isolated, high multi-pass agreement). Extract a WeSpeaker embedding for each. For every *disputed* segment (short, near a boundary, multi-pass disagreement), re-score it against those gold centroids.

This converts the problem from "cluster these embeddings" (hard on phone audio) to "verify this embedding against a known centroid" (easy). It uses nothing new — SpeakerKit already has the embedding model internally, or we can use WeSpeaker from `speech-swift`.

**Bonus.** The same gold embeddings become the voiceprint library (see 3.6).

### 3.3 Pitch (F0) as a parallel boundary signal  **[SHIP]**

**Core idea.** Run `librosa.pyin`-equivalent F0 tracking (any Swift DSP port, or a tiny Accelerate-backed implementation) at 10 ms resolution. A sudden ≥30% F0 shift is a strong speaker-change signal, independent of embedding windows.

Phone audio is 300–3400 Hz bandlimited, which squashes spectral embeddings together — but F0 is in that exact band and stays clean. This is the single most underused signal for our use case.

Add F0 boundaries to the candidate pool going into Deep Diarization. Many of the 4.5-minute "blocks where the model didn't detect a speaker change" that the project history calls out will break up on F0 shifts alone.

### 3.4 Conversational-logic boundary proposer  **[SHIP]**

**Core idea.** A tiny rule-based pass that scans the transcript for patterns that *imply* a speaker change, then adds them to the candidate boundary pool alongside acoustic and F0 candidates.

Rules (examples):
- Previous sentence ends with `?` → high prior of change at next word
- Previous sentence ends with "right?", "correct?", "okay?", "does that make sense?" → very high prior
- Current phrase is a short back-channel ("yeah", "mhm", "right", "uh-huh") → almost certainly different speaker than the surrounding turn
- "Hi, this is \<name\>", "Hello, \<name\> speaking" → speaker change + name hint
- Mid-turn switch from first-person to direct address ("Well, I think..." → "Bob, what's your view?") → turn-closing cue

Each rule has a weight. Candidates accumulate scores. The evidence-graph decoder (see 3.7) uses acoustic + F0 + conversational as weighted evidence.

**Cost:** a few hundred lines of Swift, runs in milliseconds.

### 3.5 The **Anchor Speaker** UX move  **[SHIP]**

This is the creative UX idea I'm most excited about.

**Core idea.** In Settings, the user designates "My voice" with a short enrollment (60 seconds of audio, or automatically extracted from labeled past projects). From that moment on, *one speaker is always known* in every recording the user makes themselves.

Implications:
- First-pass diarization can skip clustering for the user's voice — it goes directly into speaker verification mode
- For 2-person phone calls, this solves half the problem by definition: if it's not the user, it's the other person
- For meetings, "My voice" gets correctly labeled even if other speakers are ambiguous
- The UI can label this speaker as the user's name automatically, making transcripts look right without any post-processing

**Extension.** A per-contact voiceprint library: the user can tag a speaker with a contact name once ("this is Clayton"), and that voiceprint is saved to a library. Next call with Clayton, he's auto-identified. Over a few months, the app quietly learns the user's frequent callers.

This is the single biggest qualitative improvement a user will feel. It turns "the AI can't tell who's who" into "the AI recognized Clayton immediately."

### 3.6 Voiceprint library (corollary to 3.5)  **[SHIP]**

**Core idea.** Every speaker the user manually labels in any project gets an embedding saved to `~/Library/Application Support/Consensus/VoiceLibrary/`. On next diarization, each new speaker is first checked against the library before clustering runs. Matches get the library name; misses become new speakers.

Storage is tiny (~256 floats per voiceprint). The UI shows a "People" section where the user can manage known voices, listen to their sample clip, rename, or delete.

### 3.7 Evidence-graph boundary fusion  **[EXPERIMENT]**

Already recommended in the performance memo. Implementing 3.3 and 3.4 is the prerequisite because they give you real non-acoustic candidates. Once you have multiple signal channels voting, the right structure is a graph with frames as nodes, transitions weighted by signal agreement, and speaker labels chosen by Viterbi. Defer this until the signals are in place.

### 3.8 Telephone-domain hardening  **[EXPERIMENT]**

**Observation.** `pyannote/speaker-diarization-community-1` and FluidAudio's pyannote v1 are trained on broadband mixed-domain data. Phone calls are bandlimited, compressed, and often codec-artifacted — not the same distribution. NeMo's `diar_msdd_telephonic` checkpoint exists specifically for this domain, and FluidAudio reportedly ships multiple diarization backends.

**Action items:**
- Audit FluidAudio's diarization backend options — does it expose telephone-tuned weights?
- Preprocess phone audio: upsample to 16 kHz with bandwidth extension (Demucs-vocals or a tiny learned model) before embedding extraction — this moves phone audio closer to the training distribution.
- If an MLX port of `diar_msdd_telephonic` is feasible, test it against SpeakerKit on our phone-call test files.

### 3.9 Use the transcript to discover speaker *names*  **[SHIP]**

**Core idea.** A dedicated LLM pass that scans the first 2 minutes of the transcript for name-introduction patterns:

- "Hi, this is [Name]" → speaker at that moment = Name
- "Hello [Name], thanks for joining" → other speaker = Name
- "Good morning, [Name] Kuehn" → the person addressed by that name starts replying next
- Legal: "For the record, [Name], counsel for the defense" → self-introduction

When matches are found, the app pre-fills speaker names in the rename UI. The user confirms with one click instead of manually typing.

Combines beautifully with 3.5 / 3.6: once named, Clayton's voiceprint enters the library.

### 3.10 "Voice review" — 30-second interactive step  **[SHIP]**

**Core idea.** A dedicated review step, not text review — *voice* review. The UI plays a 3-second representative clip from each detected speaker and asks the user: "who is this?" The user picks from the voiceprint library or types a new name. Three speakers × 3 seconds = done in under 20 seconds.

This is the highest-bandwidth channel between user and app for speaker identity. Humans recognize voices instantly; getting that judgment into the system in seconds, once, drives every downstream attribution forward.

### 3.11 Whisper cross-attention DTW as a second aligner  **[EXPERIMENT]**

Already on the deferred list (WORD-TIMELINE-REBUILD-PLAN.md slice 4+). Worth doing as an A/B against Qwen3-ForcedAligner because it's free — no model download, uses WhisperKit's existing attention weights. If it's competitive, we can offer it as the default for users who don't want the 500 MB model download.

### 3.12 Sortformer v2.1 via FluidAudio  **[EXPERIMENT]**

Performance memo P2 item. Sort Loss is architecturally different from clustering. Worth wiring in as a third independent diarization voice once self-enrollment and LLM arbiter are in place — the diversity multiplies.

### 3.13 DiCoW / diarization-conditioned ASR  **[RESEARCH]**

Highest ceiling, biggest port effort. Keep parked per the performance memo's recommendation. Don't start until everything above is operational — and arguably not until a community MLX port exists.

---

## 4. What I'd explicitly *not* do

- **More passes of the same diarizer.** We've shown that 3 SpeakerKit + 2 FluidAudio passes don't meaningfully help. Adding a 6th pass of the same architecture gets nothing new.
- **Aggressive thresholds by default.** They catch interjections but create phantom speakers and fragmented segments. Keep defaults conservative, solve interjections via F0 and conversational-logic candidates.
- **Stereo channel separation as a primary path.** Your test files are mostly mono. Even the stereo file in the set appears to be mixed, not split-channel. Channel separation is a niche optimization, not a platform.
- **Cloud LLM arbiter.** Breaks the privacy-first promise. The local MLX LLM is good enough for this — the prompt engineering matters more than the model size past Qwen 3 8B.
- **Training our own models.** Even with good data, training or fine-tuning a diarizer is weeks of work, and the ceiling is probably bounded by the same "same-voice-phone-audio" limits the pretrained ones hit. Use pretrained; fuse signals better.

---

## 5. Recommended attack plan (phased)

### Phase 1 — "Fix the work product" (2 weeks)

Goal: measurable, user-visible improvement in diarization on the existing test corpus without any UI disruption.

1. **Real diarization confidence propagation.** Replace hardcoded `qualityScore: 1.0` with per-pass agreement × duration. This unblocks real voting downstream. (Half a day.)
2. **Conversational-logic boundary proposer** (3.4). Plain Swift, no dependencies. (2 days.)
3. **F0 parallel boundary detector** (3.3). Accelerate / Swift DSP; small. (2–3 days.)
4. **LLM-as-arbiter pass** (3.1). New service `TranscriptArbiterService.swift`; prompt design is the hard part. Runs after Deep Diarization; gated behind a toggle first, promoted to default if eval passes. (4–5 days.)
5. **Self-enrollment** (3.2). Reuse SpeakerKit's embedding model; compute gold centroids on first pass; re-score disputed segments. (3 days.)
6. **Parse the Clayton Everett PDF into ground truth** — or use the existing `project.json` consensus pass. Wire up tcpWER and DER into the benchmark harness so every change above gets a real number. (1–2 days.)

End state: a measurably better single-pass diarization with a real eval number to back it up.

### Phase 2 — "Name the people" (1 week)

Goal: turn transcripts from "SPEAKER_0/1/2" into "Brant / Clayton / Sarah" naturally.

1. **Anchor Speaker** (3.5). Settings UI + enrollment capture + first-class use in pipeline.
2. **Voiceprint library** (3.6). Storage format, auto-save on user labels, check-before-cluster on new recordings.
3. **Transcript-derived name discovery** (3.9). LLM prompt to find intro patterns, pre-fill names.
4. **Voice review step** (3.10). New UI surface in the Review phase — 3-second clips, one-click assignment.

End state: the average call, after Phase 2, opens with speaker names already filled in. The user's main interaction is confirming, not typing.

### Phase 3 — "Widen the evidence" (3–4 weeks, optional)

1. **Evidence-graph boundary decoder** (3.7).
2. **Telephone-domain preprocessing / model audit** (3.8).
3. **Whisper attention DTW alternate aligner** (3.11).
4. **Sortformer v2.1 ensemble entry** (3.12).

Only start this after Phase 1 + 2 are stable and the benchmark numbers justify further investment.

### Phase 4 — "Simple mode that actually earns its name" (1 week)

UI only — see next section.

---

## 6. UI workflow: Simple and Advanced

The existing `SIMPLE-MODE-DESIGN.md` has the right skeleton. Here's how it should feel once the pipeline improvements above are in place.

### 6.1 Simple Mode — one-touch, zero decisions

A **single screen**, no sidebar, no modes within modes.

```
┌─────────────────────────────────────────────────────┐
│                                                     │
│   ◉ Drop a recording                                │
│     (or click to browse)                            │
│                                                     │
│   Or pick one you've already done:  ▼               │
│                                                     │
└─────────────────────────────────────────────────────┘
```

On drop:

```
┌─────────────────────────────────────────────────────┐
│   Clayton Everett · 19 min · recorded Mar 19        │
│                                                     │
│   [■■■■■■■■■■■■■■░░░░░░░] Transcribing...  ~4 min   │
│                                                     │
│   Listening for Brant, Clayton                      │
│                                                     │
└─────────────────────────────────────────────────────┘
```

"Listening for..." is the Anchor Speaker + voiceprint library showing its work. This single line communicates "I know who you are, and I'm looking for Clayton because he's in my library."

On completion:

```
┌─────────────────────────────────────────────────────┐
│   Clayton Everett · 19 min                          │
│                                                     │
│   Brant    Hey Clayton, thanks for calling back...  │
│   Clayton  No problem, glad we could connect...     │
│   Brant    So I wanted to ask you about the Kirby...│
│   ...                                               │
│                                                     │
│   ─ 2 spots flagged ─                               │
│   ◉ 04:22  Was this Brant or Clayton?               │
│   ◉ 11:08  Unclear speaker change                   │
│                                                     │
├─────────────────────────────────────────────────────┤
│   ⬆ Flags resolved      [Export PDF]  [Verify]      │
└─────────────────────────────────────────────────────┘
```

Only two buttons in the action bar. The LLM-arbiter's low-confidence flags appear inline; each is one click to resolve (play clip, pick speaker). "Verify" re-runs with a second engine if the user wants extra certainty.

**What's auto-selected:**
- Transcription model (hardware-aware; already implemented)
- Diarization engine (SpeakerKit; already default)
- Speaker count (auto from anchor + library + clustering)
- Speaker names (from library + name discovery)
- Export format: Plain PDF + text to Desktop on "Export"
- LLM arbiter: always on
- Forced alignment: always on (once 500 MB model is downloaded; one-time consent dialog on first run)

**What's hidden:** absolutely everything else.

### 6.2 Advanced Mode — the workstation

Everything currently in the Advanced Mode stays. One addition: a **Pipeline Inspector** panel that shows, for the current project, exactly which signals voted for each boundary (acoustic engines, F0, conversational logic, LLM arbiter) and what the consensus was. This is the one thing power users want when diarization surprises them — to see *why* the attribution came out the way it did. A transparency view, not a configuration surface.

Advanced mode also gets:
- Voice library manager (add/remove/rename/re-sample voiceprints)
- Prompt template editor for the LLM arbiter (for users who want to tune the legal vs. meeting vs. interview prior)
- Per-project overrides for every auto-selected setting

### 6.3 Mode toggle

Already designed (`SIMPLE-MODE-DESIGN.md`). Keep the existing pill in the toolbar. New users default to Simple. Advanced users who toggle back to Simple keep the same data, just rendered minimally.

### 6.4 A small product identity move

Every call opens with a single sentence, auto-generated, at the top of the transcript:

> *19-minute call between Brant and Clayton Everett on March 19, 2026, about the Kirby bankruptcy filing.*

That's the `generateProjectSummary` feature that already exists. Move it from "dashboard card metadata" to "top-of-transcript headline." It's the thing that makes a transcript feel finished.

---

## 7. What to ask Codex / ChatGPT to research

See companion file: `2026-04-20 - Codex Research Brief.md`. In brief, the questions I'd delegate (they're literature-heavy and would cost a lot of tokens here):

1. Current SOTA for speaker diarization on telephone audio specifically (CallHome/Switchboard benchmarks, NIST SRE-style evaluations) — which models have phone-domain training?
2. Best practice prompt patterns for LLM-as-arbiter in speech transcription — who's done this well recently, and what's in their prompts?
3. MLX / CoreML ports of WeSpeaker, Sortformer, MossFormer2, or any similar speaker models suitable for the Apple Silicon stack.
4. Any 2025–2026 publications on using conversational-logic priors (question-answer patterns, back-channels) for diarization improvement.
5. Evaluation of the "Anchor Speaker" approach in the literature — this isn't novel academically but may have a formal name and known failure modes.

---

## 8. Summary — the single-sentence version

**Stop asking the same acoustic question five different ways; add orthogonal signals (prosodic, lexical, semantic, cross-session memory) and let a local LLM arbitrate them, anchored by one voiceprint the user enrolls once.**

That's the whole move.
