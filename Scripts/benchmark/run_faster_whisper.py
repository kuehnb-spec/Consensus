#!/usr/bin/env python3
"""
Run faster-whisper on an audio file and emit a transcript in our common
engine-output JSON format (list of turns with timestamps).

Used to generate a 3rd or 4th engine's output for multi-engine LLM reconciliation
experiments — the model chosen here (large-v2, with CTranslate2 backend) is
architecturally distinct from the WhisperKit Large v3 run the app already did,
giving us truly independent errors.

Usage:
    ./run_faster_whisper.py <audio-path> --model large-v2 --output <json-path>
"""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

try:
    from faster_whisper import WhisperModel
except ImportError:
    print("error: faster-whisper not installed", file=sys.stderr)
    sys.exit(1)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("audio", type=Path)
    parser.add_argument("--model", default="large-v2",
                        help="model size: tiny, base, small, medium, large-v1, large-v2, large-v3")
    parser.add_argument("--output", type=Path, default=None)
    parser.add_argument("--compute-type", default="int8",
                        help="int8 / int8_float16 / float16 / float32 (int8 is fastest on Apple Silicon)")
    args = parser.parse_args()

    print(f"Loading faster-whisper ({args.model}, {args.compute_type})...", file=sys.stderr)
    model = WhisperModel(args.model, device="cpu", compute_type=args.compute_type)

    print(f"Transcribing {args.audio.name}...", file=sys.stderr)
    segments, info = model.transcribe(
        str(args.audio),
        language="en",
        beam_size=5,
        vad_filter=True,
        word_timestamps=True,
    )

    turns = []
    total_words = 0
    for seg in segments:
        words = [
            {
                "word": w.word.strip(),
                "start": float(w.start),
                "end": float(w.end),
                "probability": float(w.probability),
            }
            for w in (seg.words or [])
        ]
        turns.append({
            "speaker": "UNKNOWN",  # faster-whisper doesn't do diarization
            "start": float(seg.start),
            "end": float(seg.end),
            "text": seg.text.strip(),
            "words": words,
        })
        total_words += len(seg.text.split())

    out = args.output or args.audio.with_suffix(f".faster-whisper-{args.model}.json")
    out.write_text(json.dumps({
        "audioFile": args.audio.name,
        "engine": f"faster-whisper {args.model}",
        "language": info.language,
        "languageProbability": info.language_probability,
        "duration": info.duration,
        "turns": turns,
    }, indent=2))

    print(f"Wrote {out}", file=sys.stderr)
    print(f"  {len(turns)} segments, {total_words} words, {info.duration:.1f}s audio", file=sys.stderr)
    return 0


if __name__ == "__main__":
    sys.exit(main())
