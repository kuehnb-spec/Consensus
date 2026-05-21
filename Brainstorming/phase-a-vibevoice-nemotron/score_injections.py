"""Score a Phase-A run against the injected-error manifest.

For every reviewed segment in the audit log, classify:
  - TP: segment had an injected error AND the reviewer flagged it (any conf > 0)
  - FN: segment had an injected error AND the reviewer said correct=true
  - FP: segment had NO injected error AND the reviewer flagged it
  - TN: segment had NO injected error AND the reviewer said correct=true

Then report detection rate (TP / (TP + FN)) and false-positive rate
(FP / (FP + TN)) at multiple confidence thresholds. Also print per-injection
specifics so we can see WHICH errors the model caught and which it missed.
"""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path


def load_review_log(path: Path) -> list[dict]:
    return [json.loads(line) for line in path.read_text().splitlines() if line.strip()]


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--manifest", type=Path, required=True)
    parser.add_argument("--review-log", type=Path, required=True)
    parser.add_argument("--label", type=str, required=True)
    args = parser.parse_args()

    manifest = json.loads(args.manifest.read_text())
    injected_indices = {rec["segment_index"]: rec for rec in manifest["injections"]}
    review_records = load_review_log(args.review_log)

    print(f"=== {args.label} ===")
    print(f"Injected errors:  {len(injected_indices)}")
    print(f"Reviewed segments: {len(review_records)}")
    print()

    # Classify each review record at the actual decision threshold (whatever
    # the runner used). We also compute counts as if various thresholds were
    # applied to surface calibration.
    THRESHOLDS = [0.0, 0.25, 0.5, 0.65, 0.75, 0.9]

    print(f"{'Threshold':>10} {'TP':>4} {'FN':>4} {'FP':>4} {'TN':>4} {'Recall':>8} {'FPR':>8}")
    for t in THRESHOLDS:
        tp = fn = fp = tn = 0
        for rec in review_records:
            idx = rec["segment_index"]
            is_injected = idx in injected_indices
            # "Flagged" means: reviewer said correct=false AND confidence_wrong >= t
            # AND a non-empty corrected. (We're measuring engagement, not the
            # full standard-of-proof gate.)
            said_wrong = rec.get("nemotron_correct") is False
            conf = float(rec.get("confidence_wrong") or 0)
            corrected = (rec.get("nemotron_corrected") or "").strip()
            flagged = said_wrong and conf >= t and bool(corrected)

            if is_injected and flagged:
                tp += 1
            elif is_injected and not flagged:
                fn += 1
            elif not is_injected and flagged:
                fp += 1
            else:
                tn += 1

        recall = tp / (tp + fn) if (tp + fn) > 0 else 0.0
        fpr = fp / (fp + tn) if (fp + tn) > 0 else 0.0
        print(f"{t:>10.2f} {tp:>4} {fn:>4} {fp:>4} {tn:>4} {recall*100:>7.1f}% {fpr*100:>7.1f}%")

    # Per-injection breakdown
    print()
    print("Per-injection detection (any confidence):")
    print(f"  {'idx':>4} {'time':>8} {'detected?':>10}  injection")
    print("-" * 90)
    for inj_idx, inj in injected_indices.items():
        rec = next((r for r in review_records if r["segment_index"] == inj_idx), None)
        if not rec:
            print(f"  {inj_idx:>4}     -       (not reviewed)  {inj['original_phrase']!r} -> {inj['replacement_phrase']!r}")
            continue
        said_wrong = rec.get("nemotron_correct") is False
        conf = float(rec.get("confidence_wrong") or 0)
        corrected = (rec.get("nemotron_corrected") or "").strip()
        evidence = (rec.get("evidence") or "").strip()
        verdict = "YES" if said_wrong else "no"
        print(f"  {inj_idx:>4}  {inj['start']:>6.1f}s   {verdict + (' (' + str(int(conf*100)) + '%)' if said_wrong else ''):>10}  {inj['original_phrase']!r} -> {inj['replacement_phrase']!r}")
        if said_wrong:
            print(f"        nemotron suggested:  {corrected!r}")
            print(f"        evidence:            {evidence!r}")

    # False-positive sample (reviewer flagged a non-injected segment)
    print()
    flagged_real = [
        r for r in review_records
        if r["segment_index"] not in injected_indices
        and r.get("nemotron_correct") is False
        and (r.get("nemotron_corrected") or "").strip()
    ]
    print(f"False positives (flagged a non-injected segment): {len(flagged_real)}")
    for r in flagged_real[:5]:
        print(f"  idx {r['segment_index']} conf={r.get('confidence_wrong'):.2f}")
        print(f"    candidate: {r['candidate'][:100]!r}")
        print(f"    suggested: {(r.get('nemotron_corrected') or '')[:100]!r}")
        print(f"    evidence:  {(r.get('evidence') or '')[:120]!r}")

    return 0


if __name__ == "__main__":
    sys.exit(main())
