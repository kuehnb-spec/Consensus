# Consensus v2 spec: a headless transcription + diarization engine

Written **2026-07-25**. This document is self-contained: it can be handed to a coding session with no other context.

## Context (read this first)

Consensus is an existing personal app that transcribes and diarizes meeting audio. Today it is operated by hand: record a meeting on an iPad, manually export the audio to a laptop, run Consensus, manually save the transcript.

It is being folded into a larger personal system (PADD) with this automated pipeline, which runs on an always-on Mac Studio:

```text
iPhone/iPad recorder (Voice Memos or Just Press Record)
    → iCloud-synced folder
    → watch-folder job on the Mac Studio detects a new audio file
    → invokes Consensus  ◄── this spec
    → LLM post-pass (title, summary, actions, speaker-name guesses, tags)
    → Markdown note written into an Obsidian vault
    → Telegram notification "transcript ready"
```

**Consensus's only job in this pipeline is the boxed step**: given one audio file, produce an accurate, diarized, machine-readable transcript, unattended. The orchestration around it (folder watching, LLM summarization, vault writing, speaker naming, calendar matching, notifications) is handled elsewhere and must NOT be built into Consensus.

## Goal

Turn Consensus into a **single-shot, headless, idempotent CLI engine** that a script can call in a loop overnight without supervision. Keep (or improve) the existing transcription/diarization core — the required changes are about *interface and robustness*, not accuracy. If the current core is GUI-bound, extract it into a library with a thin CLI on top; a GUI can remain as an optional shell over the same library.

## Non-goals (explicitly out of scope)

- No folder watching, daemon mode, or scheduling (the pipeline owns that).
- No LLM summarization, tagging, or title generation.
- No speaker *identification* (mapping "Speaker A" to a real person) — labels only.
- No cloud storage, vault writing, or notifications.
- No GUI requirements.

## CLI contract

```text
consensus transcribe <input-audio> [--output-dir DIR] [--speakers N]
                     [--language CODE] [--force] [--json-only] [--quiet]
consensus --version
```

- **`transcribe <input-audio>`** — process exactly one file, then exit.
- **`--output-dir DIR`** — where outputs go; default: alongside the input file.
- **`--speakers N`** — optional hint for expected speaker count; without it, auto-detect.
- **`--language CODE`** — optional; default auto-detect.
- **`--force`** — reprocess even if output already exists.
- **`--engine NAME`** — select the transcription/diarization engine (e.g. `local`, `assemblyai`, `voxtral`, `pyannoteai`). Default `local`. Engines are adapters producing the identical output schema; see [11-hosted-transcription-research.md](11-hosted-transcription-research.md) for the candidate list and rationale.
- **`--json-only`** — skip the Markdown rendering.
- **`--quiet`** — suppress progress; errors still go to stderr.
- **`--version`** — print app, model, and engine versions (needed for provenance).

Exit codes: `0` success; `2` input unreadable/unsupported; `3` transcription failed; `4` output already exists (and `--force` not given); `1` anything else. The invoking script branches on these.

## Input handling

- Accept at minimum: `.m4a` (Apple Voice Memos default), `.mp3`, `.wav`, `.aac`, `.caf`, `.flac`. Normalize internally (e.g., via ffmpeg) — the caller never pre-converts.
- Handle long recordings: 2+ hours must work; chunk internally if the engine requires it, but output must be one continuous, correctly-timestamped transcript.
- Never modify or move the input file.
- If the file looks incompletely synced (size still changing), fail cleanly with exit 2 rather than transcribing a truncated file. (The watcher also guards for this, but defense in depth.)

## Output contract

For input `2026-07-25 Board Sync.m4a`, write two files:

1. **`2026-07-25 Board Sync.consensus.json`** — the authoritative artifact:

```json
{
  "schema_version": "2.0",
  "source": {
    "filename": "2026-07-25 Board Sync.m4a",
    "sha256": "…",
    "duration_seconds": 3722.4,
    "file_created": "2026-07-25T14:02:11-04:00"
  },
  "provenance": {
    "app_version": "2.0.0",
    "engines": [{ "name": "…", "model": "…", "version": "…" }],
    "config": { "speakers_hint": null, "language": "en" },
    "processed_at": "2026-07-25T16:40:03-04:00",
    "processing_seconds": 412.7
  },
  "speakers": ["SPEAKER_A", "SPEAKER_B", "SPEAKER_C"],
  "segments": [
    {
      "start": 12.48,
      "end": 19.02,
      "speaker": "SPEAKER_A",
      "text": "Let's get started — Sam, where did the contractor bid land?",
      "confidence": 0.94
    }
  ]
}
```

2. **`2026-07-25 Board Sync.consensus.md`** — a human-readable rendering: a small header (source file, duration, date, speaker count), then the transcript as `**SPEAKER_A** [00:12] text…` paragraphs, merging consecutive same-speaker segments. No summary — downstream owns that.

Rules:

- **Atomic writes**: write to a temp name, rename on completion. The watcher must never see a half-written output.
- **Idempotent**: if the `.consensus.json` for this input already exists (match by name and source hash), exit 4 without work unless `--force`.
- **Timestamps are start-of-segment seconds** from the beginning of the recording; keep them accurate across any internal chunking.
- Confidence per segment if the engine provides it; `null` otherwise — do not fabricate.
- Speaker labels are stable within a file (`SPEAKER_A` is the same voice throughout) and carry no identity claim.

## Configuration and secrets

- Defaults in a config file (e.g., `~/.consensus/config.toml`): engine selection, model paths/sizes, output preferences. CLI flags override config.
- If any hosted engine is offered as an option, API keys come from the environment or macOS Keychain — never hardcoded, never in the config file, never in output files or logs.
- A pure-local mode must exist (target machine is an Apple Silicon Mac Studio with ample RAM) so private recordings never leave the machine. Local should be the default.

## Robustness requirements

- No interactive prompts, dialogs, or GUI dependencies in the CLI path — it must run from launchd/cron with no session UI.
- Progress to stderr (or a log file), machine-parsable one-line-per-event preferred; nothing but errors when `--quiet`.
- Log content policy: log filenames, durations, timings, and errors — never transcript text.
- A crash or kill mid-run leaves no partial outputs (temp files cleaned or ignorable) and a re-run succeeds.
- Faster-than-realtime processing on the target machine is the goal for a 1-hour file; overnight batch tolerance is acceptable for longer material.

## Acceptance checklist

*Status as of July 25, 2026 (first CLI implementation). `[x]` verified, `[~]` verified by construction but not yet on real launchd, `[ ]` untested. Implementation notes in [CLI.md](CLI.md).*

- [~] `consensus transcribe meeting.m4a` on a 60-minute, 3-speaker recording produces valid JSON + Markdown with no interaction. *(Verified on 11s, 7.6min, and 36min 3-speaker files; no 60-minute fixture on hand.)*
- [x] Re-running the same command exits 4 quickly; `--force` reprocesses.
- [x] Kill the process mid-transcription: no partial output files remain; re-run succeeds.
- [ ] A 2-hour recording produces one continuous transcript with monotonic timestamps.
- [x] An unsupported/corrupt file exits 2 with a clear stderr message; input untouched.
- [ ] Two people talking over each other yields reasonable segmentation (spot-check, not perfection).
- [x] `--version` reports app + engine/model versions matching the JSON provenance block.
- [~] Runs from a bare launchd job (no logged-in GUI assumptions) on macOS.
- [x] No transcript text appears in logs; no secrets appear anywhere in output.

## Nice-to-haves (only after the checklist passes)

- Word-level timestamps in the JSON.
- `--stt-hints "Brant, Kuehn, PADD"` — a proper-noun hint list to improve name/term accuracy.
- Language auto-detection reported in provenance.
- Multi-engine "consensus" reconciliation surfaced in the JSON (per-segment alternates), if that is what the existing core already does.

---

## Implementation status — July 25, 2026

Built. `TranscriboApp` now produces one shared library (`ConsensusCore`) and two thin executables: the GUI app and the headless `consensus` binary. The CLI drives the same VibeVoice + FluidAudio pipeline the app uses, but never starts an AppKit lifecycle, which is what makes launchd operation possible.

Verified: full round trip on real audio (JSON + Markdown, schema 2.0), exit codes 0/2/3/4, idempotency by name **and** source hash, `--force`, `--json-only`, `--quiet`, `--output-dir`, `--speakers`, `--stt-hints`, atomic writes, SIGKILL mid-run leaving no partial files with a clean re-run, and a detached no-controlling-terminal run.

Deferred / not yet true:
- **`--engine`** accepts only `local`; hosted adapters are rejected with a clear error rather than silently falling back. The companion `11-hosted-transcription-research.md` referenced by this spec does not exist in the repo.
- **Config file** (`~/.consensus/config.toml`) is not implemented — all settings come from flags and defaults. No secrets exist to protect yet because no hosted engine is wired.
- **2-hour audio** is untested; the longest fixture on hand is 36 minutes. VibeVoice's own ceiling is 60 minutes / 64K tokens, so anything longer needs internal chunking that does not exist yet — a real gap for the spec's "2+ hours must work" requirement.
- **Bare launchd** verified only by construction (no `NSApplication` is ever instantiated) plus a detached run; a true `launchctl` daemon test on the Mac Studio is still worth doing.
- Word-level timestamps *are* emitted when the engine provides them (listed in the spec as a nice-to-have).
