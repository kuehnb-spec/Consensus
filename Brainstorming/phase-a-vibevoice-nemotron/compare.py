"""Head-to-head comparison of Phase A reviewer models.

Reads multiple `phase_a_*.json` corrected transcripts and their `phase_a_*_review.jsonl`
audit logs, scores each against the gold-standard ground truth, and prints a
comparison table. Also produces a short calibration analysis: how often
high-confidence flips actually improved the transcript versus regressed it.

Usage:
    python compare.py \\
        --groundtruth ../../TestAudio/141\\ W\\ 5th\\ St\\ 3\\ -\\ Manually\\ Revised\\ Transcript.groundtruth.json \\
        --baseline ../vibevoice-test/vibevoice_with_context.json \\
        --candidate phase_a_voxtral.json:Voxtral \\
        --candidate phase_a_qwen.json:Qwen2.5-Omni
"""

from __future__ import annotations

import argparse
import json
import re
import sys
from pathlib import Path


WORD_RE = re.compile(r"[a-z0-9']+", re.IGNORECASE)


def normalize(text: str) -> list[str]:
    return WORD_RE.findall(text.lower())


def levenshtein_word(ref: list[str], hyp: list[str]) -> tuple[int, int, int, int]:
    n, m = len(ref), len(hyp)
    if n == 0:
        return 0, 0, m, 0
    prev = list(range(m + 1))
    op_prev = [(0, 0, i) for i in range(m + 1)]
    for i in range(1, n + 1):
        cur = [i] + [0] * m
        op_cur = [(0, i, 0)] + [(0, 0, 0)] * m
        for j in range(1, m + 1):
            if ref[i - 1] == hyp[j - 1]:
                cur[j] = prev[j - 1]
                op_cur[j] = op_prev[j - 1]
            else:
                sub = prev[j - 1] + 1
                dele = prev[j] + 1
                ins = cur[j - 1] + 1
                best = min(sub, dele, ins)
                cur[j] = best
                if best == sub:
                    s, d, ii = op_prev[j - 1]
                    op_cur[j] = (s + 1, d, ii)
                elif best == dele:
                    s, d, ii = op_prev[j]
                    op_cur[j] = (s, d + 1, ii)
                else:
                    s, d, ii = op_cur[j - 1]
                    op_cur[j] = (s, d, ii + 1)
        prev = cur
        op_prev = op_cur
    S, D, I = op_prev[m]
    return S, D, I, n


def wer(ref_text: str, hyp_text: str) -> dict:
    ref = normalize(ref_text)
    hyp = normalize(hyp_text)
    S, D, I, N = levenshtein_word(ref, hyp)
    return {
        "wer": (S + D + I) / N if N else float("nan"),
        "S": S,
        "D": D,
        "I": I,
        "N": N,
        "hyp_words": len(hyp),
    }


def transcript_text(payload: dict) -> str:
    """Pull a flat string from a payload's segments list."""
    segments = payload.get("segments") or payload.get("turns") or []
    return " ".join((s.get("text") or s.get("Content") or "").strip() for s in segments if (s.get("text") or s.get("Content") or "").strip())


def gt_text(payload: dict) -> str:
    return " ".join((t.get("text") or "").strip() for t in payload.get("turns", []))


def calibration_table(review_log_path: Path, ground_truth_segments: list[dict]) -> dict:
    """Per-segment: did Nemotron-the-model's flip actually agree with ground truth?

    For each FLIP (applied_correction=true) in the review log, find the
    overlapping ground-truth segment and check if the proposed correction
    looked more like the GT than the candidate did.
    """
    if not review_log_path.exists():
        return {"flips": 0, "improvements": 0, "regressions": 0, "neutral": 0}

    flips = 0
    improvements = 0
    regressions = 0
    neutral = 0

    for line in review_log_path.read_text().splitlines():
        if not line.strip():
            continue
        rec = json.loads(line)
        if not rec.get("applied_correction"):
            continue
        flips += 1

        # Find best-overlapping ground-truth turn
        seg_start, seg_end = rec["start"], rec["end"]
        best = None
        best_overlap = 0.0
        for gt in ground_truth_segments:
            ovl = max(0.0, min(seg_end, gt["end"]) - max(seg_start, gt["start"]))
            if ovl > best_overlap:
                best_overlap = ovl
                best = gt
        if best is None:
            neutral += 1
            continue

        gt_words = set(normalize(best["text"]))
        cand_words = set(normalize(rec["candidate"]))
        new_words = set(normalize(rec["final"]))

        cand_overlap = len(cand_words & gt_words) / max(1, len(gt_words))
        new_overlap = len(new_words & gt_words) / max(1, len(gt_words))

        if new_overlap > cand_overlap + 0.05:
            improvements += 1
        elif cand_overlap > new_overlap + 0.05:
            regressions += 1
        else:
            neutral += 1

    return {
        "flips": flips,
        "improvements": improvements,
        "regressions": regressions,
        "neutral": neutral,
        "precision": improvements / max(1, flips),
    }


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--groundtruth", type=Path, required=True)
    parser.add_argument("--baseline", type=Path, required=True,
                        help="VibeVoice-only transcript to use as the no-review baseline")
    parser.add_argument("--candidate", action="append", default=[],
                        help="Reviewed transcript JSON path:label (repeatable)")
    args = parser.parse_args()

    gt = json.loads(args.groundtruth.read_text())
    gt_text_str = gt_text(gt)

    rows = []

    # Baseline (VibeVoice alone)
    baseline = json.loads(args.baseline.read_text())
    baseline_text = transcript_text(baseline)
    baseline_metrics = wer(gt_text_str, baseline_text)
    rows.append({
        "label": "VibeVoice (baseline)",
        "wer": baseline_metrics["wer"],
        "S": baseline_metrics["S"],
        "D": baseline_metrics["D"],
        "I": baseline_metrics["I"],
        "flips": "—",
        "precision": "—",
        "wall_seconds": baseline.get("wall_clock_seconds_total", baseline.get("wall_clock_seconds", 0)),
    })

    for spec in args.candidate:
        if ":" in spec:
            path_str, label = spec.rsplit(":", 1)
        else:
            path_str, label = spec, Path(spec).stem
        path = Path(path_str)
        if not path.exists():
            print(f"[compare] missing: {path}", file=sys.stderr)
            continue
        payload = json.loads(path.read_text())
        cand_text = transcript_text(payload)
        m = wer(gt_text_str, cand_text)
        review_log = path.with_name(path.stem.replace("phase_a_", "phase_a_") + "_review.jsonl")
        # Convention: phase_a_voxtral.json -> phase_a_voxtral_review.jsonl
        # Try a couple of naming conventions
        candidates = [
            path.with_suffix("").with_suffix(".jsonl"),
            path.with_name(path.stem + "_review.jsonl"),
            path.parent / f"{path.stem}_review.jsonl",
        ]
        review_log = next((c for c in candidates if c.exists()), candidates[0])
        cal = calibration_table(review_log, gt["turns"])
        rows.append({
            "label": label,
            "wer": m["wer"],
            "S": m["S"],
            "D": m["D"],
            "I": m["I"],
            "flips": cal["flips"],
            "improvements": cal.get("improvements", 0),
            "regressions": cal.get("regressions", 0),
            "neutral": cal.get("neutral", 0),
            "precision": cal.get("precision", 0.0),
            "wall_seconds": payload.get("wall_clock_seconds_total", 0),
        })

    # Print table
    print()
    print(f"Ground truth: {len(gt['turns'])} turns, {sum(len(normalize(t['text'])) for t in gt['turns'])} words")
    print()
    print(f"{'Engine':<32} {'WER':>8} {'S':>5} {'D':>5} {'I':>5} {'Flips':>6} {'Prec':>6} {'Wall(s)':>8}")
    print("-" * 90)
    for row in rows:
        wer_str = f"{row['wer']*100:.2f}%" if isinstance(row['wer'], float) else str(row['wer'])
        prec_str = f"{row['precision']*100:.0f}%" if isinstance(row['precision'], float) else row['precision']
        flips_str = str(row.get('flips', '—'))
        wall = row.get('wall_seconds', 0)
        wall_str = f"{wall:.0f}" if isinstance(wall, (int, float)) else str(wall)
        print(f"{row['label']:<32} {wer_str:>8} {row['S']:>5} {row['D']:>5} {row['I']:>5} {flips_str:>6} {prec_str:>6} {wall_str:>8}")
    print()

    # Per-model calibration breakdown
    for row in rows[1:]:
        if not isinstance(row.get('flips'), int) or row['flips'] == 0:
            continue
        print(f"  {row['label']} flip breakdown:")
        print(f"    improvements (move toward GT): {row['improvements']}")
        print(f"    regressions  (move away from GT): {row['regressions']}")
        print(f"    neutral      (no clear change): {row['neutral']}")
        if row['regressions'] > row['improvements']:
            print(f"    !! REGRESSIONS EXCEED IMPROVEMENTS — model harms more than it helps")
        print()

    return 0


if __name__ == "__main__":
    sys.exit(main())
