# Consensus CLI

The headless `consensus` binary: one audio file in, a diarized transcript out, unattended. Built to the contract in [10-consensus-spec.md](10-consensus-spec.md) so a watch-folder job on the Mac Studio can call it in a loop overnight.

## Build

```bash
cd TranscriboApp && swift build -c release --product consensus
```

The binary lands at `TranscriboApp/.build/release/consensus`. Copy or symlink it somewhere on `PATH` (e.g. `/usr/local/bin/consensus`).

## Usage

```bash
consensus transcribe "2026-07-25 Board Sync.m4a"
```

| Flag | Effect |
|---|---|
| `--output-dir DIR` | Where outputs go (default: alongside the input) |
| `--speakers N` | Expected speaker count hint (default: auto-detect) |
| `--language CODE` | Language code (default: `en`) |
| `--engine NAME` | Engine adapter; only `local` exists today |
| `--stt-hints "A, B"` | Proper-noun hints biasing recognition (names, jargon) |
| `--force` | Reprocess even if output already exists |
| `--json-only` | Skip the Markdown rendering |
| `--quiet` | Suppress progress; errors still go to stderr |
| `--version` | Print app, schema, and engine versions |

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

For `Board Sync.m4a` the CLI writes `Board Sync.consensus.json` (authoritative, schema 2.0) and `Board Sync.consensus.md` (human-readable). Both are written to a temp file and renamed into place, so a watcher never sees a half-written artifact and a killed run leaves nothing behind.

Speaker labels (`SPEAKER_A`, `SPEAKER_B`, …) are assigned in order of first appearance and are stable within a file. They carry **no identity claim** — mapping a label to a person is the caller's job.

Segment `confidence` is the engine's own average token likelihood, not a calibrated accuracy estimate. It is `null` when the engine provides nothing; the CLI never fabricates a value.

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
