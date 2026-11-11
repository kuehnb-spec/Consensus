# Consensus CLI

The headless `consensus` binary: one audio file in, a diarized transcript out, unattended. Built to the contract in [10-consensus-spec.md](10-consensus-spec.md) so a watch-folder job on the Mac Studio can call it in a loop overnight.

## Build

```bash
cd TranscriboApp && swift build -c release --product consensus
```

Build the CLI product on its own: linking the app and CLI products in one
`swift build` can corrupt a link on a case-insensitive filesystem. The default
(swiftbuild) build system compiles mlx-swift's `.metal` shaders and so needs
Xcode's Metal Toolchain component; on 2026-11-11 the component was missing for
Xcode 27.2 (`xcodebuild -showComponent MetalToolchain` → uninstalled), and the
CLI was built with the legacy system instead, which the CLI does not need
shaders for (VibeVoice runs in the Python sidecar):

```bash
cd TranscriboApp && swift build -c release --product consensus --build-system native
# binary: TranscriboApp/.build/arm64-apple-macosx/release/consensus
```

Copy it somewhere on `PATH` (on the Studio: `~/.local/bin/consensus`). The
version lives in one place, `Transcribo/App/ConsensusVersion.swift`; the
packaging scripts read it from there.

## Usage

```bash
consensus transcribe "2026-07-25 Board Sync.m4a"
consensus transcribe argument.wav --witness parakeet        # adds disputes[]
consensus export argument.consensus.json --format md,legalPDF --roster roster.json
```

| Flag | Effect |
|---|---|
| `--output-dir DIR` | Where outputs go (default: alongside the input) |
| `--speakers N` | Expected speaker count hint (default: auto-detect) |
| `--language CODE` | Language code (default: `en`) |
| `--engine NAME` | Engine adapter; only `local` exists today |
| `--stt-hints "A, B"` | Proper-noun hints biasing recognition (names, jargon) |
| `--witness ID` | Run a second engine as word witness and emit `disputes[]` (ids: `parakeet`) |
| `--force` | Reprocess even if output already exists |
| `--json-only` | Skip the Markdown rendering |
| `--quiet` | Suppress progress; errors still go to stderr |
| `--version` | Print app, schema, and engine versions |

### `consensus export`

Re-renders an existing `.consensus.json` (schema 2.0 or 2.1) into any app export
format without re-running the engine: `txt, md, obsidianMarkdown, json, srt,
rtf, docx, legalPDF` (`--format` takes a comma list; default `md`).

| Flag | Effect |
|---|---|
| `--speaker A=Name` | Name one label (`A` is short for `SPEAKER_A`); repeatable; overrides the roster |
| `--roster FILE` | JSON object of label → name, or label → `{"name": …, "role": …}` |
| `--legal-header TEXT` | Header line of the court-style PDF (default `TRANSCRIPT`) |
| `--output-dir DIR` | Where exports go (default: next to the JSON) |

```json
{"SPEAKER_A": {"name": "Chief Justice Roberts", "role": "justice"},
 "B": {"name": "Paul D. Clement", "role": "counsel for petitioners"},
 "SPEAKER_C": "Justice Kagan"}
```

Naming a label that is not in the transcript fails (exit 1) and lists the
labels present, because a typo would otherwise produce an unnamed transcript.
Roles appear in the legal PDF's appearances list as `Name (role)`. Consensus
still makes no identity claim of its own: the roster is the caller's assertion.

### Exit codes

| Code | Meaning |
|---|---|
| `0` | Success |
| `1` | Unexpected failure |
| `2` | Input unreadable, unsupported, empty, or still syncing |
| `3` | Transcription failed (including a zero-segment parse) |
| `4` | Output already exists — pass `--force` to reprocess |

A calling script branches on these; nothing else is written to stdout except `--version` and `--help`.

## Outputs

For `Board Sync.m4a` the CLI writes `Board Sync.consensus.json` (authoritative, schema 2.1) and `Board Sync.consensus.md` (human-readable). Both are written to a temp file and renamed into place, so a watcher never sees a half-written artifact and a killed run leaves nothing behind.

Speaker labels (`SPEAKER_A`, `SPEAKER_B`, …) are assigned in order of first appearance and are stable within a file. They carry **no identity claim** — mapping a label to a person is the caller's job.

Segment and word `confidence` are the engine's own likelihoods, not calibrated accuracy estimates, and they are `null` when the engine provides none. **VibeVoice provides none**, so with the default engine every `confidence` is `null`. Up to 2.1.0 this sentence was false: the CLI wrote 0.951 on every segment and 0.95 on every word, both invented (fixed in 2.1.1).

Word times: VibeVoice reports only segment spans, so its `words[]` times are an even split of each segment. Since 2.1 each segment with words carries `"word_timing"` (`"interpolated"`, `"engine"`, or `"aligned"`) and the document carries the same field summarising all segments (`"mixed"` if they differ). The words are kept so downstream alignment still works; do not cite an interpolated word time as when a word was said.

### Schema 2.1 (CLI 2.1.1, 2026-11-11)

Changes from 2.0, and why a 2.0 reader keeps working:

| Field | 2.0 | 2.1 |
|---|---|---|
| `schema_version` | `"2.0"` | `"2.1"` |
| `segments[].confidence`, `segments[].words[].confidence` | always a number (invented for VibeVoice) | number from the engine, else `null` |
| `word_timing`, `segments[].word_timing` | absent | `"interpolated"` / `"engine"` / `"aligned"` / `"mixed"` / `null` |
| `provenance.engines[]` | `name` was a Swift property name (`"primaryEngine"`, `"diarizer"`, `"language"`), `version` was the app version | `{role, name, model, version}` with `role` in `asr`, `diarization`, `alignment`, `witness`; `version` is the engine's runtime (e.g. `mlx-audio 0.4.2`) or `null`; witnesses add `id` |
| `witness`, `disputes[]` | absent | present only when `--witness` ran |

Compatibility: every 2.0 key is still present with the same type, **except that
numbers which used to be invented are now `null`**. A reader that does
arithmetic on `confidence` must handle `null`; that is the one deliberate
break, and it replaces a false value with an honest absence. Everything else is
additive. The `engines[]` entries keep the `name`/`model`/`version` keys, but
their values changed meaning as described.

### Disputes (`--witness`)

The measured design (Proving Ground, 2026-10-29) is VibeVoice as primary and a
second engine as *word witness*: where the two disagree is where the
primary's errors are. `--witness parakeet` runs Parakeet TDT v3 in process
through FluidAudio after VibeVoice finishes, aligns the two word streams, and
writes:

```json
"witness": {"id": "parakeet", "normalization": "whisper-english+collapse-repeats",
            "primary_tokens": 1931, "witness_tokens": 1950, "disputed_tokens": 131,
            "dispute_rate": 0.0678, "processing_seconds": 9.4},
"disputes": [
  {"segment": 12, "word_start": 4, "word_end": 6, "primary": "Loper Bride", "witness": "Loper Bright",
   "witness_id": "parakeet", "kind": "substitution", "witness_start": 61.2, "witness_end": 61.9}
]
```

- `segment` indexes `segments[]`; `word_start`/`word_end` are a half-open range
  over that segment's `words[]`. A dispute never crosses segments.
- `primary` is the primary's words in the span; `witness` is what the witness
  heard there (`""` if it heard nothing). `kind` is `substitution`, `omission`
  (witness has no words there), `insertion` (witness heard extra words; both
  neighbouring primary words are disputed) or `mixed`.
- `witness_start`/`witness_end` are the witness's own (engine-measured) times
  for its words, or `null`.
- Both streams are normalised the way the scorer does (Whisper's English
  normaliser, then collapsing immediate 1–3-word repeats), so casing,
  punctuation, fillers, stutters, spelling variants and number formats are not
  disputes.
- `disputes: []` means the witness ran and agreed everywhere; no `disputes`
  key means nobody checked.
- A witness failure fails the run (exit 3, nothing written): a transcript
  silently missing its disputes would read as "no disputes".

The alignment step is `Scripts/WitnessSidecar/witness_align.py` (standard
library plus a vendored copy of the normaliser, MIT), run with the Consensus
Python; installed at `~/.consensus/sidecar/witness/`. It is the runtime port of
`Scripts/proving-ground/experiment_word_witness.py` and reproduces its numbers
offline (60.3% of VibeVoice's errors inside a dispute at a 6.4% flag rate over
15 clips, vs 59% / ~6% measured; see `TestCorpus/results-2026-11-11.md`). A
witness is one `WitnessEngine` case plus a `WordWitnessProvider`
(`Transcribo/CLI/WordWitness.swift`); `nemotron35` can be added behind the same
schema.

## Running from launchd

The CLI shares the app's core library but never starts an AppKit lifecycle, so it does not need a window server or a logged-in GUI session. Example agent — adjust paths, then `launchctl bootstrap gui/$UID ~/Library/LaunchAgents/com.bdk.consensus.watch.plist`:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>            <string>com.bdk.consensus.watch</string>
  <key>ProgramArguments</key>
  <array>
    <string>/usr/local/bin/consensus</string>
    <string>transcribe</string>
    <string>/Users/brantkuehn/Recordings/incoming.m4a</string>
    <string>--quiet</string>
  </array>
  <key>StandardErrorPath</key> <string>/tmp/consensus.err.log</string>
  <key>RunAtLoad</key>         <true/>
</dict>
</plist>
```

In practice the PADD watcher invokes the binary per file rather than hardcoding one path; Consensus deliberately owns no folder watching, scheduling, summarization, or notification logic.

## Logging policy

Progress goes to stderr as one machine-parsable line per event (`progress 44 Transcribing…`). **Transcript text never appears in logs** — only filenames, durations, timings, and errors.

## Architecture note

`swift build` produces two executables over one shared library:

- `ConsensusCore` — models, services, view models, and the SwiftUI scene. All the real code lives here.
- `Consensus` (GUI) — a launcher that calls `ConsensusApp.main()`.
- `consensus` (CLI) — a launcher that calls `ConsensusCLI.main()`.

The split exists so the CLI can drive the exact same pipeline the app uses without inheriting its AppKit lifecycle. The older `--smoke` launch mode still boots the SwiftUI app and is *not* launchd-safe; prefer the CLI for automation.
