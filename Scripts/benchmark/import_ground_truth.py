#!/usr/bin/env python3
"""
Import a hand-perfected transcript (RTF or plain text) as canonical ground truth.

Format accepted:
    [SPEAKER_NAME @ HH:MM:SS]
    Turn text on one or more lines.

    [SPEAKER_NAME @ MM:SS]
    ...

    [SPEAKER_NAME]
    Untimed turn — timestamp will be interpolated from neighbors.

Output: a JSON file with structured turns, ready to feed the benchmark scorer.

Usage:
    ./import_ground_truth.py <rtf-or-txt-path> [--output <json-path>]

Notes:
  * RTF is converted via `textutil -convert txt -stdout`.
  * Headers with missing timestamps are interpolated using word-weighted spacing
    between neighboring timestamped anchors. Leading/trailing unsanchored headers
    extrapolate at ~0.35s per word (rough conversational pace).
  * This mirrors the Swift codec's loose-header parsing so the two stay in sync.
"""

from __future__ import annotations

import argparse
import json
import re
import subprocess
import sys
from dataclasses import dataclass, asdict
from pathlib import Path

HEADER_RE = re.compile(
    r"^\s*\[(?P<speaker>[^\]@]+?)(?:\s*@\s*(?P<time>\d{1,2}:\d{2}(?::\d{2})?))?\s*\]\s*$"
)


@dataclass
class Turn:
    speaker: str                # uppercase label, e.g. "BRANT KUEHN"
    start: float                # seconds from audio start
    end: float                  # seconds from audio start (exclusive)
    text: str                   # trimmed turn text
    timestamp_was_explicit: bool


def _read_text(path: Path) -> str:
    """Load text from RTF (via textutil) or plain text."""
    if path.suffix.lower() == ".rtf":
        result = subprocess.run(
            ["textutil", "-convert", "txt", "-stdout", str(path)],
            capture_output=True,
            check=True,
            text=True,
        )
        text = result.stdout
    else:
        text = path.read_text(encoding="utf-8")
    # Strip stray leading `[[` that textutil sometimes emits.
    return text.replace("[[", "[")


def _parse_timestamp(s: str) -> float:
    parts = [int(x) for x in s.split(":")]
    if len(parts) == 2:
        return parts[0] * 60 + parts[1]
    if len(parts) == 3:
        return parts[0] * 3600 + parts[1] * 60 + parts[2]
    raise ValueError(f"bad timestamp: {s!r}")


def _parse_header(line: str) -> tuple[str, float | None] | None:
    m = HEADER_RE.match(line.strip())
    if not m:
        return None
    speaker = m.group("speaker").strip().upper()
    time_str = m.group("time")
    if time_str is None:
        return speaker, None
    return speaker, _parse_timestamp(time_str)


def parse_transcript(text: str, tail_word_seconds: float = 0.35) -> list[Turn]:
    # First pass: collect turns with possibly-missing timestamps.
    partial: list[tuple[str, float | None, list[str]]] = []
    cur_speaker: str | None = None
    cur_time: float | None = None
    cur_lines: list[str] = []

    def flush():
        nonlocal cur_lines
        if cur_speaker is None:
            cur_lines = []
            return
        joined = " ".join(l.strip() for l in cur_lines).strip()
        if joined:
            partial.append((cur_speaker, cur_time, [joined]))
        cur_lines = []

    for raw in text.splitlines():
        line = raw.strip()
        if not line:
            continue
        header = _parse_header(line)
        if header:
            flush()
            cur_speaker, cur_time = header
        else:
            cur_lines.append(line)
    flush()

    if not partial:
        return []

    word_counts = [len(p[2][0].split()) for p in partial]
    anchor_times: list[float | None] = [p[1] for p in partial]

    # Back-fill leading missing timestamps.
    if anchor_times[0] is None:
        first_explicit = next((i for i, t in enumerate(anchor_times) if t is not None), None)
        if first_explicit is not None:
            first_time = anchor_times[first_explicit]
            cursor = first_time
            for i in range(first_explicit - 1, -1, -1):
                cursor = max(0.0, cursor - max(1, word_counts[i]) * tail_word_seconds)
                anchor_times[i] = cursor

    # Fill nil gaps between explicit anchors using word-weighted interpolation.
    # The model is: turn k occupies a chunk of time proportional to its word count.
    # Anchor turn last_anchor starts at start_time; anchor turn i starts at end_time;
    # therefore ppw = gap / sum(word_counts[last_anchor:i]), and each intermediate
    # turn j starts at start_time + sum(word_counts[last_anchor:j]) * ppw.
    last_anchor: int | None = None
    for i in range(len(anchor_times)):
        if anchor_times[i] is None:
            continue
        if last_anchor is not None and last_anchor < i - 1:
            start_time = anchor_times[last_anchor]
            end_time = anchor_times[i]
            gap = end_time - start_time
            total_words_in_span = sum(word_counts[last_anchor:i])
            for j in range(last_anchor + 1, i):
                words_before_j = sum(word_counts[last_anchor:j])
                if total_words_in_span > 0:
                    ratio = words_before_j / total_words_in_span
                else:
                    ratio = (j - last_anchor) / max(1, (i - last_anchor))
                anchor_times[j] = start_time + gap * ratio
        last_anchor = i

    # Extrapolate trailing missing timestamps.
    if last_anchor is not None and last_anchor < len(anchor_times) - 1:
        cursor = anchor_times[last_anchor]
        for i in range(last_anchor + 1, len(anchor_times)):
            cursor += max(1, word_counts[i]) * tail_word_seconds
            anchor_times[i] = cursor

    # Build end times: each turn ends when the next turn starts (or +word_count*0.35s for the last).
    turns: list[Turn] = []
    for idx, (speaker, orig_time, text_list) in enumerate(partial):
        start = max(0.0, anchor_times[idx] or 0.0)
        if idx + 1 < len(anchor_times):
            end = anchor_times[idx + 1]
        else:
            end = start + max(1, word_counts[idx]) * tail_word_seconds
        turns.append(Turn(
            speaker=speaker,
            start=round(start, 3),
            end=round(max(start + 0.1, end), 3),
            text=text_list[0],
            timestamp_was_explicit=orig_time is not None,
        ))
    return turns


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("source", type=Path, help="RTF or plain text transcript")
    parser.add_argument("--output", type=Path, default=None,
                        help="Output JSON path (default: <source>.groundtruth.json)")
    parser.add_argument("--audio", type=Path, default=None,
                        help="Optional audio file path to record in the output metadata")
    args = parser.parse_args()

    if not args.source.exists():
        print(f"error: {args.source} does not exist", file=sys.stderr)
        return 1

    text = _read_text(args.source)
    turns = parse_transcript(text)

    if not turns:
        print("error: no turns parsed", file=sys.stderr)
        return 1

    output_path = args.output or args.source.with_suffix(".groundtruth.json")
    speakers = sorted({t.speaker for t in turns})

    doc = {
        "sourceFile": str(args.source.name),
        "audioFile": args.audio.name if args.audio else None,
        "turns": [asdict(t) for t in turns],
        "speakers": speakers,
        "totalTurns": len(turns),
        "totalWords": sum(len(t.text.split()) for t in turns),
        "durationSecondsCovered": round(turns[-1].end, 2),
    }

    output_path.write_text(json.dumps(doc, indent=2) + "\n", encoding="utf-8")

    interp_count = sum(1 for t in turns if not t.timestamp_was_explicit)
    print(f"Wrote {output_path}")
    print(f"  {doc['totalTurns']} turns across {len(speakers)} speakers ({speakers})")
    print(f"  {doc['totalWords']} words total, {doc['durationSecondsCovered']}s covered")
    print(f"  {interp_count} headers had timestamps interpolated from neighbors")
    return 0


if __name__ == "__main__":
    sys.exit(main())
