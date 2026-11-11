#!/usr/bin/env python3
"""
Grade the disputes[] a `consensus transcribe --witness ID` run wrote (schema 2.1)
against the Oyez references: flag rate (share of primary words inside a
dispute, the review burden) and recall (share of the primary's true word
errors that fall inside one). Same definitions as experiment_word_witness.py;
the only difference is that the disputes come from the shipped CLI instead of
being recomputed here.

    eval_cli_disputes.py --corpus TestCorpus/oyez --run TestCorpus/runs/cli-2.1.1-witness \
        [--clip 2023_22-451_03364 ...]

`--simulate DIR` grades disputes computed offline from stored runs instead:
primary words from --run (schema 2.0 is fine), witness words from DIR's
fluidaudiocli `.raw.json` files (the Proving Ground's Parakeet runs).
"""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

import jiwer

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
sys.path.insert(0, str(HERE.parents[1] / "TranscriboApp/Scripts/WitnessSidecar"))
from pg_text import content as pg_content  # noqa: E402
from witness_align import find_disputes, normalize_with_origin  # noqa: E402


def primary_tokens(doc: dict) -> tuple[list[str], dict[tuple[int, int], list[int]]]:
    toks, where = [], {}
    for s, seg in enumerate(doc["segments"]):
        words = [w["word"] for w in seg.get("words") or []] or seg["text"].split()
        t, origin = normalize_with_origin(words)
        for tok, o in zip(t, origin):
            where.setdefault((s, o), []).append(len(toks))
            toks.append(tok)
    return toks, where


def errors(ref: list[str], hyp: list[str]):
    out = []
    for c in jiwer.process_words(" ".join(ref), " ".join(hyp)).alignments[0]:
        if c.type in ("substitute", "insert"):
            out += [(1, {i}) for i in range(c.hyp_start_idx, c.hyp_end_idx)]
        elif c.type == "delete":
            out.append((c.ref_end_idx - c.ref_start_idx,
                        {i for i in (c.hyp_start_idx - 1, c.hyp_start_idx) if 0 <= i < len(hyp)}))
    return out


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--corpus", type=Path, required=True)
    ap.add_argument("--run", type=Path, required=True)
    ap.add_argument("--simulate", type=Path)
    ap.add_argument("--clip", action="append")
    args = ap.parse_args()

    clips = args.clip or [c["id"] for c in json.loads((args.corpus / "manifest.json").read_text())["clips"]]
    tot = dict(ref=0, words=0, errors=0, caught=0, flagged=0, flagged_wrong=0)
    print("| clip | words | disputes | flag rate | errors | caught | recall | precision |")
    print("|---|---:|---:|---:|---:|---:|---:|---:|")
    for clip in clips:
        p = args.run / f"{clip}.consensus.json"
        if not p.exists():
            continue
        doc = json.loads(p.read_text())
        if args.simulate:
            raw = json.loads((args.simulate / f"{clip}.raw.json").read_text())
            witness = [{"word": w["word"], "start": w["startTime"], "end": w["endTime"]} for w in raw["wordTimings"]]
            prim = [[w["word"] for w in s.get("words") or []] or s["text"].split() for s in doc["segments"]]
            disputes = find_disputes(prim, witness, "parakeet")["disputes"]
        else:
            disputes = doc.get("disputes") or []
        toks, where = primary_tokens(doc)
        flagged = set()
        for d in disputes:
            for w in range(d["word_start"], d["word_end"]):
                flagged.update(where.get((d["segment"], w), []))
        fx = json.loads((args.corpus / f"{clip}.fixture.json").read_text())
        ref = pg_content(" ".join(t["text"] for t in fx["turns"])).split()
        errs = errors(ref, toks)
        n_err = sum(n for n, _ in errs)
        caught = sum(n for n, pos in errs if pos & flagged)
        wrong = set().union(*(pos for _, pos in errs)) if errs else set()
        row = dict(ref=len(ref), words=len(toks), errors=n_err, caught=caught,
                   flagged=len(flagged), flagged_wrong=len(flagged & wrong))
        for k in tot:
            tot[k] += row[k]
        print(f"| {clip} | {row['words']} | {len(disputes)} | {100*row['flagged']/max(1,row['words']):.1f}% "
              f"| {n_err} | {caught} | {100*caught/max(1,n_err):.1f}% | {100*row['flagged_wrong']/max(1,row['flagged']):.1f}% |")
    print(f"| **all** | {tot['words']} | | {100*tot['flagged']/max(1,tot['words']):.1f}% | {tot['errors']} | {tot['caught']} "
          f"| {100*tot['caught']/max(1,tot['errors']):.1f}% | {100*tot['flagged_wrong']/max(1,tot['flagged']):.1f}% |")
    print(f"\nprimary WER on this token stream: {100*tot['errors']/max(1,tot['ref']):.2f}%")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
