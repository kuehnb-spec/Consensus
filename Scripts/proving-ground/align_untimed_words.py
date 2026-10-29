#!/usr/bin/env python3
"""
Give an untimed engine's words (Nemotron 3.5 Transcribe emits text only) the
timestamps and speakers of a timed engine, by aligning the two texts.

Each untimed word that lines up with a timed word (match or substitution)
takes that word's start, end and speaker; a word the timed engine missed takes
its neighbours' (previous word's end, or the next word's start at the head).
Speaker changes, and pauses over MAX_GAP seconds, start a new turn. This is
how a text-only primary engine would sit on the Record: its words, the
witness's clock and voices.

    align_untimed_words.py --words TestCorpus/runs/nemotron35-asr \
        --timed TestCorpus/runs/vibevoice --out TestCorpus/runs/nemotron35+vibevoice

--words reads <id>.turns.json (run_nemotron35.py output; speaker tags are
dropped). --timed reads a Consensus CLI run (<id>.consensus.json) or a
FluidAudio transcribe run (<id>.raw.json, no speakers: every word gets "A").
Writes <id>.turns.json per clip for score_corpus.py.
"""

from __future__ import annotations

import argparse
import json
import re
from pathlib import Path

import jiwer

MAX_GAP = 1.0


def key(word: str) -> str:
    return re.sub(r"[^\w']", "", word.lower()) or "_"


def timed_words(path: Path) -> list[tuple[float, float, str, str]]:
    doc = json.loads(path.read_text(encoding="utf-8"))
    if "wordTimings" in doc:
        return [(float(w["startTime"]), float(w["endTime"]), w["word"], "A") for w in doc["wordTimings"]]
    out = []
    for seg in doc.get("segments", []):
        for w in seg.get("words") or []:
            if w["word"].strip():
                out.append((float(w["start"]), float(w["end"]), w["word"].strip(), seg["speaker"]))
    return out


def align(words: list[str], timed: list[tuple[float, float, str, str]]):
    anchor: list[int | None] = [None] * len(words)
    a = jiwer.process_words(" ".join(key(t[2]) for t in timed), " ".join(key(w) for w in words)).alignments[0]
    for c in a:
        if c.type in ("equal", "substitute"):
            for k in range(c.hyp_end_idx - c.hyp_start_idx):
                anchor[c.hyp_start_idx + k] = c.ref_start_idx + k
    out, prev = [], None
    for i, w in enumerate(words):
        j = anchor[i]
        if j is not None:
            s, e, _, spk = timed[j]
            prev = (e, spk)
        elif prev is not None:
            s = e = prev[0]
            spk = prev[1]
        else:
            nxt = next((anchor[k] for k in range(i, len(words)) if anchor[k] is not None), None)
            s, _, _, spk = timed[nxt] if nxt is not None else (0.0, 0.0, "", "A")
            e = s
        out.append((s, e, w, spk))
    return out


def to_turns(tagged):
    turns = []
    for s, e, w, spk in tagged:
        if turns and turns[-1]["speaker"] == spk and s - turns[-1]["end"] <= MAX_GAP:
            turns[-1]["end"] = max(turns[-1]["end"], e)
            turns[-1]["text"] += " " + w
        else:
            turns.append({"speaker": spk, "start": s, "end": e, "text": w})
    return turns


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--words", type=Path, required=True)
    ap.add_argument("--timed", type=Path, required=True)
    ap.add_argument("--out", type=Path, required=True)
    args = ap.parse_args()
    args.out.mkdir(parents=True, exist_ok=True)
    n = 0
    for p in sorted(args.words.glob("*.turns.json")):
        clip = p.name[: -len(".turns.json")]
        src = next((args.timed / f"{clip}{s}" for s in (".consensus.json", ".raw.json")
                    if (args.timed / f"{clip}{s}").exists()), None)
        if src is None:
            continue
        text = " ".join(t["text"] for t in json.loads(p.read_text(encoding="utf-8"))["turns"])
        words = re.sub(r"<spk:\d+>", " ", text).split()
        turns = to_turns(align(words, timed_words(src)))
        (args.out / f"{clip}.turns.json").write_text(json.dumps({"turns": turns}, indent=1), encoding="utf-8")
        n += 1
    print(f"wrote {n} clips to {args.out}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
