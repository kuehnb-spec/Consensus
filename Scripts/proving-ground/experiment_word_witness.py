#!/usr/bin/env python3
"""
Experiment A (word level): when one engine's words are the primary transcript
and a second engine is the witness, how many of the primary's word errors fall
inside the spans where the two disagree?

Primary and witness are aligned to each other with no reference (this is what
the app can do at runtime); every primary word the witness substitutes or
drops, and both neighbours of a word the witness inserts, is "disputed". The
reference is used only to grade, by aligning it to the primary:

  WER           the primary's content WER alone
  dispute rate  share of primary words disputed (the review burden)
  recall        share of the primary's word errors inside a dispute; an error
                outside one is shared by both engines and nobody would flag it
  precision     share of disputed words where the primary really was wrong
  oracle WER    WER if a reviewer resolved every dispute correctly
  ROVER WER     automatic resolution: a third engine breaks ties; a primary
                word is replaced only when witness and tie-breaker agree on
                something else (insertions likewise need both)

Everything runs on pg_text.content(), the same normalization the scorer uses.

    experiment_word_witness.py --corpus TestCorpus/oyez --runs TestCorpus/runs \
        --pair nemotron35-saa:vibevoice:parakeet --pair vibevoice:nemotron35-saa:parakeet \
        [--report out.md] [--json out.json]
"""

from __future__ import annotations

import argparse
import json
from collections import defaultdict
from pathlib import Path

import jiwer
from pg_text import content


def engine_text(runs: Path, engine: str, clip: str) -> str | None:
    d = runs / engine
    for suffix in (".consensus.json", ".turns.json"):
        p = d / f"{clip}{suffix}"
        if p.exists():
            doc = json.loads(p.read_text(encoding="utf-8"))
            return " ".join(t.get("text", "") for t in doc.get("segments") or doc.get("turns") or [])
    p = d / f"{clip}.raw.json"
    if p.exists():  # fluidaudiocli transcribe (Parakeet)
        return json.loads(p.read_text(encoding="utf-8"))["text"]
    return None


def chunks(ref: list[str], hyp: list[str]):
    return jiwer.process_words(" ".join(ref), " ".join(hyp)).alignments[0]


def disputes(primary: list[str], witness: list[str]) -> set[int]:
    flagged: set[int] = set()
    for c in chunks(primary, witness):
        if c.type in ("substitute", "delete"):
            flagged.update(range(c.ref_start_idx, c.ref_end_idx))
        elif c.type == "insert":
            flagged.update(i for i in (c.ref_start_idx - 1, c.ref_start_idx) if 0 <= i < len(primary))
    return flagged


def errors(ref: list[str], primary: list[str]) -> list[tuple[int, set[int]]]:
    """Each error as (word count, primary positions it touches)."""
    out = []
    for c in chunks(ref, primary):
        if c.type in ("substitute", "insert"):
            for i in range(c.hyp_start_idx, c.hyp_end_idx):
                out.append((1, {i}))
        elif c.type == "delete":
            gap = {i for i in (c.hyp_start_idx - 1, c.hyp_start_idx) if 0 <= i < len(primary)}
            out.append((c.ref_end_idx - c.ref_start_idx, gap))
    return out


def slot_map(primary: list[str], other: list[str]):
    """Per primary position, the other engine's token ('' if dropped), plus its insertions per gap."""
    tok = list(primary)
    ins: dict[int, tuple[str, ...]] = {}
    for c in chunks(primary, other):
        if c.type == "substitute":
            for k, i in enumerate(range(c.ref_start_idx, c.ref_end_idx)):
                tok[i] = other[c.hyp_start_idx + k]
        elif c.type == "delete":
            for i in range(c.ref_start_idx, c.ref_end_idx):
                tok[i] = ""
        elif c.type == "insert":
            ins[c.ref_start_idx] = tuple(other[c.hyp_start_idx:c.hyp_end_idx])
    return tok, ins


def rover(primary: list[str], witness: list[str], breaker: list[str]) -> list[str]:
    wt, wi = slot_map(primary, witness)
    bt, bi = slot_map(primary, breaker)
    out: list[str] = []
    for i in range(len(primary) + 1):
        if i in wi and wi.get(i) == bi.get(i):
            out.extend(wi[i])
        if i < len(primary):
            out.append(wt[i] if wt[i] == bt[i] else primary[i])
    return [w for w in out if w]


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--corpus", type=Path, required=True)
    ap.add_argument("--runs", type=Path, required=True)
    ap.add_argument("--pair", action="append", required=True, help="primary:witness[:tiebreaker]")
    ap.add_argument("--report", type=Path)
    ap.add_argument("--json", type=Path)
    ap.add_argument("--examples", type=int, default=12)
    args = ap.parse_args()

    clips = [c["id"] for c in json.loads((args.corpus / "manifest.json").read_text())["clips"]]
    results, examples = {}, defaultdict(list)
    for spec in args.pair:
        primary_name, witness_name, *rest = spec.split(":")
        breaker_name = rest[0] if rest else None
        tot = defaultdict(float)
        per_clip = {}
        for clip in clips:
            fx = json.loads((args.corpus / f"{clip}.fixture.json").read_text())
            ref = content(" ".join(t["text"] for t in fx["turns"])).split()
            texts = [engine_text(args.runs, n, clip) for n in (primary_name, witness_name, breaker_name) if n]
            if any(t is None for t in texts):
                continue
            p, w, *b = [content(t).split() for t in texts]
            flagged = disputes(p, w)
            errs = errors(ref, p)
            n_err = sum(n for n, _ in errs)
            caught = sum(n for n, pos in errs if pos & flagged)
            wrong = set().union(*(pos for _, pos in errs)) if errs else set()
            row = {"ref_words": len(ref), "words": len(p), "errors": n_err, "caught": caught,
                   "flagged": len(flagged), "flagged_wrong": len(flagged & wrong)}
            if b:
                row["rover_errors"] = jiwer.process_words(" ".join(ref), " ".join(rover(p, w, b[0]))).wer * len(ref)
            per_clip[clip] = row
            for k, v in row.items():
                tot[k] += v
            # Listen-list examples: disputed spans where the primary was wrong
            if len(examples[spec]) < args.examples:
                for c in chunks(p, w):
                    if c.type == "substitute" and set(range(c.ref_start_idx, c.ref_end_idx)) & wrong:
                        lo, hi = max(0, c.ref_start_idx - 4), min(len(p), c.ref_end_idx + 4)
                        examples[spec].append({
                            "clip": clip,
                            "primary": " ".join(p[lo:c.ref_start_idx]) + " [" + " ".join(p[c.ref_start_idx:c.ref_end_idx]) + "] " + " ".join(p[c.ref_end_idx:hi]),
                            "witness": " ".join(w[c.hyp_start_idx:c.hyp_end_idx])})
                        if len(examples[spec]) >= args.examples:
                            break
        r = {
            "clips": len(per_clip),
            "wer": tot["errors"] / tot["ref_words"],
            "dispute_rate": tot["flagged"] / tot["words"],
            "recall": tot["caught"] / tot["errors"],
            "precision": tot["flagged_wrong"] / tot["flagged"],
            "oracle_wer": (tot["errors"] - tot["caught"]) / tot["ref_words"],
            "rover_wer": tot["rover_errors"] / tot["ref_words"] if breaker_name else None,
            "per_clip": per_clip,
        }
        results[spec] = r

    lines = ["| primary : witness : tie-breaker | WER | dispute rate | recall | precision | oracle WER | ROVER WER |",
             "|---|---:|---:|---:|---:|---:|---:|"]
    for spec, r in results.items():
        rov = f"{100 * r['rover_wer']:.2f}%" if r["rover_wer"] is not None else "—"
        lines.append(f"| {spec} | {100 * r['wer']:.2f}% | {100 * r['dispute_rate']:.1f}% | {100 * r['recall']:.1f}% "
                     f"| {100 * r['precision']:.1f}% | {100 * r['oracle_wer']:.2f}% | {rov} |")
    for spec, ex in examples.items():
        lines += ["", f"Disputes where the primary was wrong ({spec}):", ""]
        lines += [f"- `{e['clip']}` primary: {e['primary']} — witness: **{e['witness']}**" for e in ex]
    report = "\n".join(lines)
    print(report)
    if args.report:
        args.report.write_text(report + "\n", encoding="utf-8")
    if args.json:
        args.json.write_text(json.dumps({"results": results, "examples": examples}, indent=1), encoding="utf-8")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
