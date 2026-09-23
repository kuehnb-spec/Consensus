#!/usr/bin/env bash
# Run every engine the Proving Ground compares over a corpus, skipping clips
# that already have output. Safe to re-run after adding clips.
#
#   run_engines.sh TestCorpus/oyez [engine ...]
#
# Engines: nemotron3 community1 parakeet vibevoice (default: all).
# Needs FLUIDAUDIO_CLI (a fluidaudiocli >= 0.17.0 binary) and the installed
# `consensus` CLI for VibeVoice. Outputs land in TestCorpus/runs/<engine>/;
# afterwards run combine_words_speakers.py and score_corpus.py.
set -euo pipefail

CORPUS="${1:?usage: run_engines.sh <corpus-dir> [engine ...]}"; shift || true
ENGINES=("${@:-nemotron3 community1 parakeet vibevoice}")
ENGINES=(${ENGINES[@]})
RUNS="$(dirname "$CORPUS")/runs"
FA="${FLUIDAUDIO_CLI:-fluidaudiocli}"
HERE="$(cd "$(dirname "$0")" && pwd)"

for engine in "${ENGINES[@]}"; do
  case "$engine" in
    nemotron3)  out="$RUNS/nemotron3-offline" ;;
    *)          out="$RUNS/$engine" ;;
  esac
  mkdir -p "$out"
  for wav in "$CORPUS"/*.wav; do
    id="$(basename "$wav" .wav)"
    start=$(date +%s)
    case "$engine" in
      nemotron3)
        [ -f "$out/$id.rttm" ] && continue
        "$FA" nemotron3-diarize "$wav" --variant offline --output "$out/$id.rttm" >/dev/null 2>&1 ;;
      community1)
        [ -f "$out/$id.rttm" ] && continue
        "$FA" process "$wav" --mode offline --output "$out/$id.raw.json" >/dev/null 2>&1
        python3 "$HERE/fluid_json_to_rttm.py" "$out/$id.raw.json" "$id" > "$out/$id.rttm" ;;
      parakeet)
        [ -f "$out/$id.raw.json" ] && continue
        "$FA" transcribe "$wav" --word-timestamps --output-json "$out/$id.raw.json" >/dev/null 2>&1 ;;
      vibevoice)
        [ -f "$out/$id.consensus.json" ] && continue
        consensus transcribe "$wav" --output-dir "$out" --json-only --quiet ;;
      *) echo "unknown engine: $engine" >&2; exit 2 ;;
    esac
    echo "$engine $id $(( $(date +%s) - start ))s"
  done
done
