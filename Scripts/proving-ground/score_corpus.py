#!/usr/bin/env python3
"""
Score one or more engine runs against a Proving Ground corpus.

    score_corpus.py --corpus TestCorpus/oyez --run vibevoice=TestCorpus/runs/vibevoice \
        --run nemotron3=TestCorpus/runs/nemotron3-offline [--report out.md] [--json out.json]

A run directory holds one hypothesis per clip, matched by clip id:
    <id>.consensus.json   Consensus CLI output (words + speakers)  -> WER, cpWER, DER
    <id>.turns.json       {"turns":[{speaker,start,end,text}]}     -> WER, cpWER, DER
    <id>.rttm             diarization only                         -> DER

Metrics (all computed on pg_text.content(): Whisper's EnglishTextNormalizer,
which lowercases, strips punctuation and fillers, and unifies spellings and
numbers — because the references are official-reporter style, not verbatim):
    WER    content word error rate, speakers ignored
    cpWER  concatenated minimum-permutation WER (meeteval): words AND speakers
    DER    diarization error rate (md-eval-22 via meeteval), 0.25 s collar
"""

from __future__ import annotations

import argparse
import json
import sys
import tempfile
from pathlib import Path

import jiwer
import meeteval
from pg_text import content

COLLAR = 0.25


def norm(text: str) -> str:
    return content(text)


def load_turns(path: Path) -> list[dict]:
    doc = json.loads(path.read_text(encoding="utf-8"))
    raw = doc.get("turns") or doc.get("segments") or []
    turns = []
    for t in raw:
        spk = t.get("speaker") or t.get("speaker_label") or t.get("speakerID") or "UNKNOWN"
        if isinstance(spk, dict):
            spk = spk.get("label") or spk.get("id") or "UNKNOWN"
        turns.append({"speaker": str(spk), "start": float(t["start"]),
                      "end": float(t["end"]), "text": t.get("text", "")})
    return turns


def load_rttm(path: Path) -> list[dict]:
    turns = []
    for line in path.read_text().splitlines():
        p = line.split()
        if len(p) >= 8 and p[0] == "SPEAKER":
            s, d = float(p[3]), float(p[4])
            turns.append({"speaker": p[7], "start": s, "end": s + d, "text": ""})
    return turns


def write_stm(turns: list[dict], clip: str, path: Path) -> None:
    with open(path, "w", encoding="utf-8") as f:
        for t in turns:
            text = norm(t["text"])
            if text:
                f.write(f"{clip} 1 {t['speaker']} {t['start']:.3f} {t['end']:.3f} {text}\n")


def write_rttm(turns: list[dict], clip: str, path: Path) -> None:
    with open(path, "w", encoding="utf-8") as f:
        for t in turns:
            if t["end"] > t["start"]:
                f.write(f"SPEAKER {clip} 1 {t['start']:.3f} {t['end'] - t['start']:.3f} "
                        f"<NA> <NA> {t['speaker']} <NA> <NA>\n")


def score_clip(ref: list[dict], hyp: list[dict], clip: str, has_text: bool) -> dict:
    clip = "_".join(clip.split())  # RTTM/STM fields are whitespace-delimited
    out: dict = {}
    with tempfile.TemporaryDirectory() as tmp:
        tmp = Path(tmp)
        write_rttm(ref, clip, tmp / "ref.rttm")
        write_rttm(hyp, clip, tmp / "hyp.rttm")
        der = meeteval.der.md_eval_22(str(tmp / "ref.rttm"), str(tmp / "hyp.rttm"), collar=COLLAR)
        d = der[clip]
        out["der"] = float(d.error_rate)
        out["der_parts"] = {"miss": float(d.missed_speaker_time), "fa": float(d.falarm_speaker_time),
                            "conf": float(d.speaker_error_time), "scored": float(d.scored_speaker_time)}
        out["hyp_speakers"] = len({t["speaker"] for t in hyp})
        if has_text:
            ref_text = norm(" ".join(t["text"] for t in ref))
            hyp_text = norm(" ".join(t["text"] for t in hyp))
            m = jiwer.process_words(ref_text, hyp_text)
            out["wer"] = m.wer
            out["wer_parts"] = {"sub": m.substitutions, "del": m.deletions, "ins": m.insertions,
                                "ref_words": len(ref_text.split())}
            write_stm(ref, clip, tmp / "ref.stm")
            write_stm(hyp, clip, tmp / "hyp.stm")
            cp = meeteval.wer.cpwer(str(tmp / "ref.stm"), str(tmp / "hyp.stm"))
            out["cpwer"] = float(cp[clip].error_rate)
    return out


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--corpus", type=Path, required=True)
    ap.add_argument("--run", action="append", required=True, help="name=dir")
    ap.add_argument("--report", type=Path)
    ap.add_argument("--json", type=Path)
    args = ap.parse_args()

    manifest = json.loads((args.corpus / "manifest.json").read_text())
    clips = [c["id"] for c in manifest["clips"]]
    results: dict[str, dict[str, dict]] = {}

    for spec in args.run:
        name, _, d = spec.partition("=")
        run_dir = Path(d)
        results[name] = {}
        for clip in clips:
            ref = load_turns(args.corpus / f"{clip}.fixture.json")
            for suffix, loader, has_text in ((".consensus.json", load_turns, True),
                                             (".turns.json", load_turns, True),
                                             (".rttm", load_rttm, False)):
                p = run_dir / f"{clip}{suffix}"
                if p.exists():
                    results[name][clip] = score_clip(ref, loader(p), clip, has_text)
                    results[name][clip]["ref_speakers"] = len({t["speaker"] for t in ref})
                    break

    lines = ["| run | clips | WER | cpWER | DER | miss / FA / confusion |", "|---|---:|---:|---:|---:|---|"]
    for name, per in results.items():
        if not per:
            continue
        scored = sum(r["der_parts"]["scored"] for r in per.values())
        der = sum(r["der_parts"]["miss"] + r["der_parts"]["fa"] + r["der_parts"]["conf"] for r in per.values()) / scored
        parts = " / ".join(f"{100 * sum(r['der_parts'][k] for r in per.values()) / scored:.1f}"
                           for k in ("miss", "fa", "conf"))
        texted = [r for r in per.values() if "wer" in r]
        if texted:
            refw = sum(r["wer_parts"]["ref_words"] for r in texted)
            wer = sum(r["wer"] * r["wer_parts"]["ref_words"] for r in texted) / refw
            cpw = sum(r["cpwer"] * r["wer_parts"]["ref_words"] for r in texted) / refw
            wer_s, cpw_s = f"{100 * wer:.2f}%", f"{100 * cpw:.2f}%"
        else:
            wer_s = cpw_s = "—"
        lines.append(f"| {name} | {len(per)} | {wer_s} | {cpw_s} | {100 * der:.2f}% | {parts} |")

    lines += ["", "Per clip (DER% · WER% · hyp/ref speakers):", ""]
    lines.append("| clip | " + " | ".join(results) + " |")
    lines.append("|---|" + "---|" * len(results))
    for clip in clips:
        cells = []
        for name in results:
            r = results[name].get(clip)
            if not r:
                cells.append("—")
                continue
            w = f" · {100 * r['wer']:.1f}" if "wer" in r else ""
            cells.append(f"{100 * r['der']:.1f}{w} · {r['hyp_speakers']}/{r['ref_speakers']}")
        lines.append(f"| {clip} | " + " | ".join(cells) + " |")

    report = "\n".join(lines)
    print(report)
    if args.report:
        args.report.write_text(report + "\n", encoding="utf-8")
    if args.json:
        args.json.write_text(json.dumps(results, indent=1), encoding="utf-8")
    return 0


if __name__ == "__main__":
    sys.exit(main())
