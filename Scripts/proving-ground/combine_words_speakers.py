#!/usr/bin/env python3
"""
Re-attribute an ASR run's words to a diarizer's speakers.

This is the "decouple words from speakers" experiment: take the words (and
their timestamps) from one engine, take who-spoke-when from another, and
assign each word to the speaker whose segment overlaps it most (nearest
segment when none overlaps). Consecutive same-speaker words become a turn;
a pause over MAX_GAP seconds also starts a new turn.

    combine_words_speakers.py --words parakeet=TestCorpus/runs/parakeet \
        --speakers TestCorpus/runs/nemotron3-offline --out TestCorpus/runs/parakeet+nemotron3

--words accepts a Consensus CLI run (<id>.consensus.json, segments[].words)
or a FluidAudio transcribe run (<id>.raw.json, wordTimings). Output is
<id>.turns.json per clip, which score_corpus.py reads.
"""

from __future__ import annotations

import argparse
import bisect
import json
from pathlib import Path

MAX_GAP = 1.0


def load_words(path: Path) -> list[tuple[float, float, str]]:
    doc = json.loads(path.read_text(encoding="utf-8"))
    if "wordTimings" in doc:
        return [(float(w["startTime"]), float(w["endTime"]), w["word"]) for w in doc["wordTimings"]]
    words = []
    for seg in doc.get("segments", []):
        for w in seg.get("words") or []:
            words.append((float(w["start"]), float(w["end"]), w["word"].strip()))
    return [w for w in words if w[2]]


def load_rttm(path: Path) -> list[tuple[float, float, str]]:
    segs = []
    for line in path.read_text().splitlines():
        p = line.split()
        if len(p) >= 8 and p[0] == "SPEAKER":
            s = float(p[3])
            segs.append((s, s + float(p[4]), p[7]))
    return sorted(segs)


def assign(words, segs):
    starts = [s[0] for s in segs]
    out = []
    for ws, we, text in words:
        i = bisect.bisect_right(starts, we)
        best, best_ov = None, 0.0
        for s, e, spk in segs[max(0, i - 40):i]:
            ov = min(we, e) - max(ws, s)
            if ov > best_ov:
                best, best_ov = spk, ov
        if best is None and segs:
            mid = (ws + we) / 2
            best = min(segs, key=lambda x: 0 if x[0] <= mid <= x[1] else min(abs(mid - x[0]), abs(mid - x[1])))[2]
        out.append((ws, we, text, best or "UNKNOWN"))
    return out


def to_turns(tagged):
    turns = []
    for ws, we, text, spk in tagged:
        if turns and turns[-1]["speaker"] == spk and ws - turns[-1]["end"] <= MAX_GAP:
            turns[-1]["end"] = we
            turns[-1]["text"] += " " + text
        else:
            turns.append({"speaker": spk, "start": ws, "end": we, "text": text})
    return turns


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--words", required=True, help="dir of ASR outputs")
    ap.add_argument("--speakers", required=True, type=Path, help="dir of <id>.rttm")
    ap.add_argument("--out", required=True, type=Path)
    args = ap.parse_args()
    words_dir = Path(args.words.split("=", 1)[-1])
    args.out.mkdir(parents=True, exist_ok=True)
    n = 0
    for rttm in sorted(args.speakers.glob("*.rttm")):
        clip = rttm.stem
        src = next((p for p in (words_dir / f"{clip}.consensus.json", words_dir / f"{clip}.raw.json") if p.exists()), None)
        if not src:
            continue
        turns = to_turns(assign(load_words(src), load_rttm(rttm)))
        (args.out / f"{clip}.turns.json").write_text(json.dumps({"turns": turns}, indent=1), encoding="utf-8")
        n += 1
    print(f"{n} clips -> {args.out}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
