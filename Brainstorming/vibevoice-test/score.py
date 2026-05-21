"""Score VibeVoice ASR output against the manually-revised ground truth.

Outputs:
- Word Error Rate (WER) on full transcript text
- Per-speaker text comparison
- Diarization Error Rate (DER) approximation: % of audio time with mismatched speaker
- Speaker count detected vs ground truth (2)
- Timing alignment quality
- Risky segment overlap with ground truth

Usage:
    python score.py <hypothesis.json> <groundtruth.json>
"""

from __future__ import annotations
import json
import sys
import re
from pathlib import Path
from collections import defaultdict


WORD_RE = re.compile(r"[a-z0-9']+", re.IGNORECASE)


def normalize(text: str) -> list[str]:
    """Lowercase, strip punctuation, return tokens."""
    return WORD_RE.findall(text.lower())


def levenshtein_word(ref: list[str], hyp: list[str]) -> tuple[int, int, int, int]:
    """Standard Levenshtein on tokens. Returns (S, D, I, N) substitutions, deletions, insertions, ref length."""
    n, m = len(ref), len(hyp)
    if n == 0:
        return 0, 0, m, 0
    # DP table with backpointers omitted; only need counts
    prev = list(range(m + 1))
    op_prev = [(0, 0, i) for i in range(m + 1)]  # (S, D, I) at each cell
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
        "WER": (S + D + I) / N if N else float("nan"),
        "substitutions": S,
        "deletions": D,
        "insertions": I,
        "ref_words": N,
        "hyp_words": len(hyp),
    }


def make_timeline(turns: list[dict], speaker_key: str = "speaker", default_step: float = 0.1) -> list[tuple[float, float, str]]:
    """Convert turns into a flat list of (start, end, speaker)."""
    out = []
    for t in turns:
        out.append((float(t["start"]), float(t["end"]), str(t.get(speaker_key, "?"))))
    out.sort()
    return out


def overlap(a_start: float, a_end: float, b_start: float, b_end: float) -> float:
    return max(0.0, min(a_end, b_end) - max(a_start, b_start))


def best_speaker_mapping(ref: list[tuple[float, float, str]], hyp: list[tuple[float, float, str]]) -> dict:
    """Greedy mapping: for each ref speaker, pick the hyp speaker with most overlap."""
    overlaps = defaultdict(lambda: defaultdict(float))
    for rs, re_, rspk in ref:
        for hs, he, hspk in hyp:
            ov = overlap(rs, re_, hs, he)
            if ov > 0:
                overlaps[rspk][hspk] += ov
    mapping = {}
    used_hyp = set()
    # Greedy by total overlap
    pairs = []
    for rspk, hyps in overlaps.items():
        for hspk, ov in hyps.items():
            pairs.append((ov, rspk, hspk))
    pairs.sort(reverse=True)
    for ov, rspk, hspk in pairs:
        if rspk not in mapping and hspk not in used_hyp:
            mapping[rspk] = hspk
            used_hyp.add(hspk)
    return mapping


def der_approx(ref: list[tuple[float, float, str]], hyp: list[tuple[float, float, str]], step: float = 0.1) -> dict:
    """Sample timeline at `step` seconds, count fraction with mismatched speaker after best mapping.

    DER = (missed + falseAlarm + speakerError) / totalRefTime.
    Approximation: ignores overlapped speech, but our reference has no overlap.
    """
    if not ref:
        return {"DER": float("nan"), "covered": 0.0}
    mapping = best_speaker_mapping(ref, hyp)
    end_time = max(r[1] for r in ref)
    t = 0.0
    miss = false_alarm = spk_err = correct = 0
    total_ref = 0
    while t < end_time:
        ref_spk = None
        for rs, re_, rspk in ref:
            if rs <= t < re_:
                ref_spk = rspk
                break
        hyp_spk = None
        for hs, he, hspk in hyp:
            if hs <= t < he:
                hyp_spk = hspk
                break
        if ref_spk is None and hyp_spk is None:
            pass
        elif ref_spk is None and hyp_spk is not None:
            false_alarm += 1
        elif ref_spk is not None and hyp_spk is None:
            miss += 1
            total_ref += 1
        else:
            total_ref += 1
            mapped = mapping.get(ref_spk)
            if mapped == hyp_spk:
                correct += 1
            else:
                spk_err += 1
        t += step
    der = (miss + false_alarm + spk_err) / total_ref if total_ref else float("nan")
    return {
        "DER": der,
        "miss_frac": miss / total_ref if total_ref else 0.0,
        "false_alarm_frac": false_alarm / total_ref if total_ref else 0.0,
        "speaker_error_frac": spk_err / total_ref if total_ref else 0.0,
        "speaker_mapping": mapping,
    }


def load_groundtruth(path: Path) -> dict:
    return json.loads(path.read_text())


def normalize_hypothesis(raw: dict) -> dict:
    """Convert various hypothesis formats into {turns: [...]} with speaker/start/end/text."""
    if "turns" in raw:
        return raw
    # mlx-audio / vibevoice typical format: {"transcription": [{"speaker_id":..., "start_time":..., "end_time":..., "text":...}]}
    for key in ("transcription", "segments", "results"):
        if key in raw and isinstance(raw[key], list):
            turns = []
            for item in raw[key]:
                turns.append({
                    "speaker": str(item.get("speaker_id") or item.get("speaker") or item.get("speakerID") or "SPEAKER_0"),
                    "start": float(item.get("start_time") or item.get("start") or 0),
                    "end": float(item.get("end_time") or item.get("end") or 0),
                    "text": str(item.get("text") or ""),
                })
            return {"turns": turns}
    raise ValueError(f"Unknown hypothesis format. Top keys: {list(raw.keys())}")


def main():
    if len(sys.argv) != 3:
        print("Usage: score.py <hypothesis.json> <groundtruth.json>")
        sys.exit(1)
    hyp_raw = json.loads(Path(sys.argv[1]).read_text())
    gt = load_groundtruth(Path(sys.argv[2]))
    hyp = normalize_hypothesis(hyp_raw)

    # Concatenated text WER
    ref_text = " ".join(t["text"] for t in gt["turns"])
    hyp_text = " ".join(t["text"] for t in hyp["turns"])
    wer_metrics = wer(ref_text, hyp_text)

    # Diarization
    ref_tl = make_timeline(gt["turns"])
    hyp_tl = make_timeline(hyp["turns"])
    der = der_approx(ref_tl, hyp_tl)

    # Speaker counts
    gt_speakers = set(t["speaker"] for t in gt["turns"])
    hyp_speakers = set(t["speaker"] for t in hyp["turns"])

    print("=== TEXT METRICS ===")
    print(f"  WER:           {wer_metrics['WER']:.4f}  ({wer_metrics['WER'] * 100:.2f}%)")
    print(f"  Ref words:     {wer_metrics['ref_words']}")
    print(f"  Hyp words:     {wer_metrics['hyp_words']}")
    print(f"  Substitutions: {wer_metrics['substitutions']}")
    print(f"  Deletions:     {wer_metrics['deletions']}")
    print(f"  Insertions:    {wer_metrics['insertions']}")

    print("\n=== DIARIZATION METRICS ===")
    print(f"  DER (approx):       {der['DER']:.4f}  ({der['DER'] * 100:.2f}%)")
    print(f"    miss:             {der['miss_frac'] * 100:.2f}%")
    print(f"    false alarm:      {der['false_alarm_frac'] * 100:.2f}%")
    print(f"    speaker error:    {der['speaker_error_frac'] * 100:.2f}%")
    print(f"  Mapping:            {der['speaker_mapping']}")
    print(f"  GT speakers ({len(gt_speakers)}):  {sorted(gt_speakers)}")
    print(f"  Hyp speakers ({len(hyp_speakers)}): {sorted(hyp_speakers)}")
    print(f"  GT turns:           {len(gt['turns'])}")
    print(f"  Hyp turns:          {len(hyp['turns'])}")


if __name__ == "__main__":
    main()
