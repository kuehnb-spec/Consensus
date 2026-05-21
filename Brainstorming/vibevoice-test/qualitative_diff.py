"""Print side-by-side ground truth vs hypothesis turns, aligned by overlapping time, with diff markers."""
import json
import sys
import difflib
from pathlib import Path


def overlap(a_s, a_e, b_s, b_e):
    return max(0.0, min(a_e, b_e) - max(a_s, b_s))


def best_match(turn, candidates):
    best, score = None, 0
    for c in candidates:
        ov = overlap(turn["start"], turn["end"], c["start"], c["end"])
        if ov > score:
            best, score = c, ov
    return best, score


def normalize_hypothesis(raw):
    if "turns" in raw:
        return raw
    for key in ("transcription", "segments", "results"):
        if key in raw and isinstance(raw[key], list):
            turns = []
            for item in raw[key]:
                turns.append({
                    "speaker": str(item.get("speaker_id") or item.get("speaker") or item.get("speakerID") or "S0"),
                    "start": float(item.get("start_time") or item.get("start") or 0),
                    "end": float(item.get("end_time") or item.get("end") or 0),
                    "text": str(item.get("text") or ""),
                })
            return {"turns": turns}
    raise ValueError(f"Unknown format: {list(raw.keys())}")


def main():
    if len(sys.argv) != 3:
        print("Usage: qualitative_diff.py <hypothesis.json> <groundtruth.json>")
        sys.exit(1)
    hyp = normalize_hypothesis(json.loads(Path(sys.argv[1]).read_text()))
    gt = json.loads(Path(sys.argv[2]).read_text())

    print(f"{'GT (start-end)':<20} {'GT speaker':<14} | {'HYP speaker':<14} {'HYP (start-end)':<20}")
    print("-" * 100)
    mismatches = 0
    for ref in gt["turns"]:
        cand, ov = best_match(ref, hyp["turns"])
        if cand is None:
            print(f"{ref['start']:>5.1f}-{ref['end']:<5.1f} {ref['speaker']:<14} | <NO MATCH>")
            mismatches += 1
            continue
        ref_text = ref["text"].strip()
        cand_text = cand["text"].strip()
        differ = difflib.SequenceMatcher(None, ref_text.lower(), cand_text.lower())
        ratio = differ.ratio()
        marker = " " if ratio > 0.85 else ("~" if ratio > 0.6 else "!")
        print(f"{marker} GT [{ref['start']:>5.1f}-{ref['end']:<5.1f}] {ref['speaker']:<14}: {ref_text[:90]}")
        print(f"  HY [{cand['start']:>5.1f}-{cand['end']:<5.1f}] {cand['speaker']:<14}: {cand_text[:90]}")
        if ratio < 0.85:
            mismatches += 1
        print()
    print(f"\nTotal mismatches (similarity < 0.85): {mismatches}/{len(gt['turns'])}")


if __name__ == "__main__":
    main()
