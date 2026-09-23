#!/usr/bin/env python3
"""
Audit a corpus's reference transcripts using independent engines as witnesses.

The idea (Brant's "many consistent transcripts" instinct, applied with
machines): two ASR engines built by different teams on different data make
different mistakes. Where BOTH agree with each other but NOT with the
reference, the reference is the likely odd one out — an edit by the court
reporter, a mis-timed turn, or a genuine transcription slip. Those spans go
on a short listen-list for a human spot-check; everything else is trusted.

    audit_reference.py --corpus TestCorpus/oyez \
        --witness vibevoice=TestCorpus/runs/vibevoice \
        --witness parakeet=TestCorpus/runs/parakeet \
        --out TestCorpus/oyez/_audit

Writes <out>/listen-list.md (one entry per suspect turn, with a snippet
file to play) and <out>/audit.json (per-turn agreement scores). A turn is
suspect when every witness differs from the reference by at least
SUSPECT_REF_WER, the witnesses agree with each other within
WITNESS_AGREE_WER, and the turn has at least MIN_WORDS words.
"""

from __future__ import annotations

import argparse
import json
import subprocess
from pathlib import Path

import jiwer
from pg_text import content

SUSPECT_REF_WER = 0.30
WITNESS_AGREE_WER = 0.15
MIN_WORDS = 4
PAD = 0.15  # seconds of slack when collecting a witness's words for a turn


def norm(text: str) -> str:
    return content(text)


def witness_words(run_dir: Path, clip: str) -> list[tuple[float, float, str]]:
    for name in (f"{clip}.consensus.json", f"{clip}.raw.json", f"{clip}.turns.json"):
        p = run_dir / name
        if not p.exists():
            continue
        doc = json.loads(p.read_text(encoding="utf-8"))
        if "wordTimings" in doc:
            return [(w["startTime"], w["endTime"], w["word"]) for w in doc["wordTimings"]]
        words = []
        for seg in doc.get("segments", []) + doc.get("turns", []):
            ws = seg.get("words")
            if ws:
                words += [(w["start"], w["end"], w["word"]) for w in ws]
            else:  # no word timings: spread the segment's words evenly
                toks = seg["text"].split()
                step = (seg["end"] - seg["start"]) / max(1, len(toks))
                words += [(seg["start"] + i * step, seg["start"] + (i + 1) * step, t) for i, t in enumerate(toks)]
        return words
    return []


def text_in(words, start, end) -> str:
    return " ".join(w for s, e, w in words if start - PAD <= (s + e) / 2 <= end + PAD)


def wer(ref: str, hyp: str) -> float:
    if not ref:
        return 0.0 if not hyp else 1.0
    return jiwer.wer(ref, hyp) if hyp else 1.0


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--corpus", type=Path, required=True)
    ap.add_argument("--witness", action="append", required=True, help="name=run_dir (at least two)")
    ap.add_argument("--out", type=Path, required=True)
    args = ap.parse_args()
    witnesses = [(w.split("=", 1)[0], Path(w.split("=", 1)[1])) for w in args.witness]
    args.out.mkdir(parents=True, exist_ok=True)
    (args.out / "snippets").mkdir(exist_ok=True)

    manifest = json.loads((args.corpus / "manifest.json").read_text())
    rows, suspects, total_turns, total_words = [], [], 0, 0
    for clip in (c["id"] for c in manifest["clips"]):
        fixture = json.loads((args.corpus / f"{clip}.fixture.json").read_text())
        words = {name: witness_words(d, clip) for name, d in witnesses}
        if not all(words.values()):
            continue
        for i, turn in enumerate(fixture["turns"]):
            ref = norm(turn["text"])
            if len(ref.split()) < MIN_WORDS:
                continue
            total_turns += 1
            total_words += len(ref.split())
            hyps = {n: norm(text_in(w, turn["start"], turn["end"])) for n, w in words.items()}
            ref_wers = {n: wer(ref, h) for n, h in hyps.items()}
            names = list(hyps)
            agree = max(wer(hyps[a], hyps[b]) for a in names for b in names if a != b)
            row = {"clip": clip, "turn": i, "start": turn["start"], "end": turn["end"],
                   "speaker": turn["speaker"], "ref": turn["text"], "witnesses": hyps,
                   "ref_wer": ref_wers, "witness_disagreement": agree}
            rows.append(row)
            if min(ref_wers.values()) >= SUSPECT_REF_WER and agree <= WITNESS_AGREE_WER:
                suspects.append(row)

    lines = [f"# Reference audit — {args.corpus.name}", "",
             f"{total_turns} turns ({total_words} words) checked against {len(witnesses)} witnesses "
             f"({', '.join(n for n, _ in witnesses)}). **{len(suspects)} suspect turns** "
             f"({100 * len(suspects) / max(1, total_turns):.1f}%) — the witnesses agree with each other "
             f"but not with the reference. Listen to each snippet and mark it.", ""]
    for n, s in enumerate(suspects, 1):
        snip = args.out / "snippets" / f"{n:03d}_{s['clip']}_{int(s['start'])}.m4a"
        subprocess.run(["ffmpeg", "-loglevel", "error", "-y", "-ss", f"{max(0, s['start'] - 0.5):.2f}",
                        "-t", f"{s['end'] - s['start'] + 1.0:.2f}", "-i", str(args.corpus / f"{s['clip']}.wav"),
                        "-c:a", "aac", "-b:a", "64k", str(snip)], check=True)
        lines += [f"## {n}. {s['clip']} @ {s['start']:.1f}s — {s['speaker']}",
                  f"`snippets/{snip.name}`", "",
                  f"- **Reference:** {s['ref']}"]
        lines += [f"- **{w}:** {t}" for w, t in s["witnesses"].items()]
        lines += ["- Verdict: [ ] reference right  [ ] reference wrong  [ ] can't tell", ""]
    (args.out / "listen-list.md").write_text("\n".join(lines), encoding="utf-8")
    (args.out / "audit.json").write_text(json.dumps({"suspects": suspects, "turns": rows}, indent=1), encoding="utf-8")
    print(f"{total_turns} turns checked, {len(suspects)} suspect -> {args.out / 'listen-list.md'}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
