# Consensus CLI — install

Headless transcription and diarization for Apple Silicon Macs. Everything runs
locally; no audio leaves the machine.

## Requirements

- Apple Silicon Mac (M-series), macOS 15 or later
- Xcode command line tools (`xcode-select --install`)
- ~7 GB free disk: ~700 MB of Python wheels + ~5.3 GB model

## Install

```bash
./install.sh
```

This installs the `consensus` binary to `~/.local/bin`, sets up a Python
environment and the VibeVoice model under `~/.consensus/`, writes
`~/.consensus/config.toml`, and runs a verification check.

Options: `--skip-model` if you already have the model somewhere,
`--reinstall` to rebuild the environment, `PREFIX=/usr/local/bin` to install
the binary elsewhere.

## Verify

```bash
consensus doctor
```

Prints every dependency, where it was found, and how to fix anything missing.

## Use

```bash
consensus transcribe "meeting.m4a"
```

Writes `meeting.consensus.json` (authoritative) and `meeting.consensus.md`
(readable) next to the input. Useful flags: `--output-dir`, `--speakers N`,
`--stt-hints "Name, Term"`, `--force`, `--json-only`, `--quiet`.

Exit codes: `0` success, `2` input unreadable, `3` transcription failed,
`4` output already exists, `1` other.

## Gatekeeper

This build is ad-hoc signed, not notarized. `install.sh` clears the quarantine
flag on the binary. If macOS still objects:

```bash
xattr -d com.apple.quarantine ~/.local/bin/consensus
```

## Configuration

`~/.consensus/config.toml` holds the paths. Environment variables override it:
`CONSENSUS_PYTHON`, `CONSENSUS_SIDECAR`, `CONSENSUS_MODEL`, `CONSENSUS_CONFIG`.
Handy if you keep the model on external storage:

```bash
CONSENSUS_MODEL=/Volumes/NAS/models/vibevoice-asr-4bit consensus doctor
```

## Unattended use

The CLI never prompts and needs no GUI session, so it runs from launchd. See
`CLI.md` in the repository for a sample plist.
