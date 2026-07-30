#!/usr/bin/env python3
"""
Score a pipeline output against a ground-truth transcript.

Computes:
  * WER      — plain word error rate on joined text (both streams concatenated)
  * cpWER    — concatenated permutation-invariant WER: pick the speaker mapping
               that minimizes per-speaker WER, then report average
  * DER      — diarization error rate in the NIST md-eval sense:
               (miss + false_alarm + speaker_error) / total_speech_time
  * turns/words/speakers counts
  * Mid-sentence speaker flips — sentences in the hypothesis where attribution
    crosses a speaker boundary (indicator of smoother failure)
  * Per-turn error breakdown: for each ground-truth turn, closest matching
    hypothesis turn and its WER + speaker correctness

Usage:
    ./score.py <hypothesis-json> <ground-truth-json> [--report <markdown-path>]

Hypothesis JSON accepted:
  * Consensus project.json — identifies active pass by activePassID
  * Extracted pass JSON (turns with speaker + start + end + text)
  * Also a `--pass-kind` flag picks a specific pass if the project file has many
"""

from __future__ import annotations

import argparse
import json
import re
import sys
from dataclasses import dataclass, field
from itertools import permutations
from pathlib import Path

try:
    import jiwer
except ImportError:
    print("error: jiwer not installed — run `pip3 install --user jiwer`", file=sys.stderr)
    sys.exit(1)


# Words we ignore when computing WER (small pronunciation variants that the ASR
# or the hand-corrector may not agree on but don't change meaning).
WER_TRANSFORMS = jiwer.Compose([
    jiwer.ToLowerCase(),
    jiwer.RemovePunctuation(),
    jiwer.RemoveMultipleSpaces(),
    jiwer.Strip(),
    jiwer.ReduceToListOfListOfWords(),
])


@dataclass
class Turn:
    speaker: str
    start: float
    end: float
    text: str


@dataclass
class ScoreReport:
    hypothesis_label: str
    ground_truth_label: str

    gt_turn_count: int = 0
    gt_word_count: int = 0
    gt_speakers: list[str] = field(default_factory=list)
    gt_duration: float = 0.0

    hyp_turn_count: int = 0
    hyp_word_count: int = 0
    hyp_speakers: list[str] = field(default_factory=list)
    hyp_duration: float = 0.0

    plain_wer: float = 0.0
    cp_wer: float = 0.0
    der: float = 0.0
    der_miss: float = 0.0
    der_fa: float = 0.0
    der_speaker_error: float = 0.0

    speaker_mapping: dict[str, str] = field(default_factory=dict)
    mid_sentence_flips: int = 0
    per_turn_errors: list[dict] = field(default_factory=list)
    residual_errors_markdown: str = ""


# -----------------------------------------------------------------------------
# Hypothesis loading
# -----------------------------------------------------------------------------

def load_hypothesis(path: Path, pass_kind: str | None) -> tuple[list[Turn], str]:
    doc = json.loads(path.read_text(encoding="utf-8"))

    # Consensus project.json shape: has `passes` and `activePassID`.
    if "passes" in doc:
        passes = doc["passes"]
        target = None
        if pass_kind:
            target = next((p for p in passes if p.get("kind") == pass_kind), None)
            if target is None:
                raise ValueError(f"no pass of kind {pass_kind!r} in project.json")
        else:
            active_id = doc.get("activePassID")
            target = next((p for p in passes if p.get("id") == active_id), None)
            if target is None:
                raise ValueError("could not find active pass in project.json")

        mapping = doc.get("speakerMapping", {}).get("names", {})
        turns: list[Turn] = []
        for seg in target.get("result", {}).get("segments", []):
            speaker_id = seg.get("speakerID", "UNKNOWN")
            display = mapping.get(speaker_id, speaker_id).upper()
            turns.append(Turn(
                speaker=display,
                start=float(seg.get("start", 0.0)),
                end=float(seg.get("end", 0.0)),
                text=seg.get("text", "").strip(),
            ))
        label = f"{path.name} [{target.get('kind', 'unknown')}]"
        return turns, label

    # Ground-truth/extracted JSON shape: has `turns` directly.
    if "turns" in doc:
        turns = [Turn(speaker=t["speaker"].upper(), start=float(t["start"]),
                      end=float(t["end"]), text=t["text"]) for t in doc["turns"]]
        label = path.name
        return turns, label

    raise ValueError(f"unrecognized JSON shape in {path}")


# -----------------------------------------------------------------------------
# WER helpers
# -----------------------------------------------------------------------------

def concat_text_for_speaker(turns: list[Turn], speaker: str) -> str:
    return " ".join(t.text for t in turns if t.speaker == speaker)


def plain_wer(hyp_turns: list[Turn], ref_turns: list[Turn]) -> float:
    hyp_text = " ".join(t.text for t in hyp_turns)
    ref_text = " ".join(t.text for t in ref_turns)
    if not ref_text.strip():
        return 0.0
    return jiwer.wer(ref_text, hyp_text, reference_transform=WER_TRANSFORMS,
                     hypothesis_transform=WER_TRANSFORMS)


def cp_wer(hyp_turns: list[Turn], ref_turns: list[Turn]) -> tuple[float, dict[str, str]]:
    """
    Concatenated permutation-invariant WER. Try every mapping of hypothesis
    speakers → ground-truth speakers; pick the one with lowest average WER;
    return that WER + mapping.
    """
    ref_speakers = sorted({t.speaker for t in ref_turns})
    hyp_speakers = sorted({t.speaker for t in hyp_turns})
    if not ref_speakers or not hyp_speakers:
        return 1.0, {}

    best_wer = float("inf")
    best_mapping: dict[str, str] = {}

    if len(hyp_speakers) >= len(ref_speakers):
        bigger, smaller = hyp_speakers, ref_speakers
        forward = True  # permute bigger → smaller
    else:
        bigger, smaller = ref_speakers, hyp_speakers
        forward = False

    for perm in permutations(bigger, len(smaller)):
        if forward:
            mapping = {perm[i]: smaller[i] for i in range(len(smaller))}  # hyp→ref
        else:
            mapping = {smaller[i]: perm[i] for i in range(len(smaller))}  # hyp→ref

        per_speaker_wers: list[float] = []
        for ref_sp in ref_speakers:
            mapped_hyp_speakers = [hyp_sp for hyp_sp, ref in mapping.items() if ref == ref_sp]
            hyp_text = " ".join(concat_text_for_speaker(hyp_turns, hsp) for hsp in mapped_hyp_speakers)
            ref_text = concat_text_for_speaker(ref_turns, ref_sp)
            if not ref_text.strip():
                continue
            w = jiwer.wer(ref_text, hyp_text,
                          reference_transform=WER_TRANSFORMS,
                          hypothesis_transform=WER_TRANSFORMS)
            per_speaker_wers.append(w)
        avg = sum(per_speaker_wers) / max(1, len(per_speaker_wers))
        if avg < best_wer:
            best_wer = avg
            best_mapping = mapping
    return best_wer, best_mapping


# -----------------------------------------------------------------------------
# DER (diarization error rate) — time-based
# -----------------------------------------------------------------------------

def compute_der(hyp_turns: list[Turn], ref_turns: list[Turn],
                mapping: dict[str, str],
                frame_size: float = 0.025) -> tuple[float, float, float, float]:
    """
    Frame-based DER. Break the audio into small frames; for each frame, the
    reference has one assigned speaker (or silence); the hypothesis has one
    too (after applying the hyp→ref speaker mapping). Errors accumulate as
    miss (ref has speech, hyp doesn't), false_alarm (hyp has speech, ref doesn't),
    or speaker_error (both have speech but different speakers).

    Returns (DER, miss_rate, fa_rate, speaker_error_rate).
    """
    if not ref_turns:
        return 0.0, 0.0, 0.0, 0.0

    duration = max(
        max(t.end for t in ref_turns),
        max(t.end for t in hyp_turns) if hyp_turns else 0.0,
    )
    num_frames = int(duration / frame_size) + 1
    ref_frames = [None] * num_frames
    hyp_frames = [None] * num_frames

    for t in ref_turns:
        s = max(0, int(t.start / frame_size))
        e = min(num_frames, int(t.end / frame_size) + 1)
        for i in range(s, e):
            ref_frames[i] = t.speaker

    for t in hyp_turns:
        s = max(0, int(t.start / frame_size))
        e = min(num_frames, int(t.end / frame_size) + 1)
        mapped = mapping.get(t.speaker, t.speaker)
        for i in range(s, e):
            hyp_frames[i] = mapped

    total_speech_frames = sum(1 for f in ref_frames if f is not None)
    if total_speech_frames == 0:
        return 0.0, 0.0, 0.0, 0.0

    miss = fa = spk_err = 0
    for r, h in zip(ref_frames, hyp_frames):
        if r is not None and h is None:
            miss += 1
        elif r is None and h is not None:
            fa += 1
        elif r is not None and h is not None and r != h:
            spk_err += 1

    miss_rate = miss / total_speech_frames
    fa_rate = fa / total_speech_frames
    spk_err_rate = spk_err / total_speech_frames
    return miss_rate + fa_rate + spk_err_rate, miss_rate, fa_rate, spk_err_rate


# -----------------------------------------------------------------------------
# Mid-sentence speaker flip detection
# -----------------------------------------------------------------------------

def count_mid_sentence_flips(hyp_turns: list[Turn]) -> tuple[int, list[str]]:
    """
    A mid-sentence flip is: hypothesis turn i ends without sentence-ending
    punctuation (no .!?) AND turn i+1 starts with a lowercase letter or a
    continuation-indicative word — suggesting one speaker's sentence was split
    across two speaker labels.
    """
    flips = 0
    examples: list[str] = []
    for i in range(len(hyp_turns) - 1):
        a_text = hyp_turns[i].text.strip()
        b_text = hyp_turns[i + 1].text.strip()
        if not a_text or not b_text:
            continue
        a_end = a_text[-1]
        if a_end in ".!?":
            continue
        # Next turn starts with lowercase, or a continuation word, or no capital
        first_char = b_text[0]
        lowered = b_text.split()[0].lower().strip(",.?!:;")
        continuation = lowered in {"and", "but", "so", "or", "yet", "because",
                                    "when", "if", "then", "that", "which",
                                    "was", "were", "is", "are", "have", "has"}
        if first_char.islower() or continuation:
            flips += 1
            if len(examples) < 5:
                examples.append(f"... {a_text[-40:]}\" ... \"{b_text[:60]} ...")
    return flips, examples


# -----------------------------------------------------------------------------
# Per-turn error analysis
# -----------------------------------------------------------------------------

def per_turn_error_report(hyp_turns: list[Turn], ref_turns: list[Turn],
                          mapping: dict[str, str]) -> list[dict]:
    """For each ground-truth turn, find the hyp turns overlapping it, compute
    WER between the joined hyp text and the ref turn text, note whether the
    speaker matches after mapping."""
    rows: list[dict] = []
    for ref in ref_turns:
        # Find hyp turns whose interval overlaps this ref turn
        overlapping = []
        for hyp in hyp_turns:
            overlap = max(0, min(hyp.end, ref.end) - max(hyp.start, ref.start))
            if overlap > 0:
                overlapping.append((hyp, overlap))
        if not overlapping:
            rows.append({
                "ref_turn": {"speaker": ref.speaker, "start": ref.start,
                             "end": ref.end, "text": ref.text},
                "hyp_text": "",
                "hyp_speakers": [],
                "wer": 1.0,
                "speaker_correct": False,
                "notes": "no hypothesis content in this time range",
            })
            continue
        overlapping.sort(key=lambda x: x[0].start)
        hyp_text = " ".join(h.text for h, _ in overlapping)
        hyp_speakers = list({mapping.get(h.speaker, h.speaker) for h, _ in overlapping})
        try:
            wer = jiwer.wer(ref.text, hyp_text,
                            reference_transform=WER_TRANSFORMS,
                            hypothesis_transform=WER_TRANSFORMS)
        except ValueError:
            wer = 1.0
        speaker_correct = len(hyp_speakers) == 1 and hyp_speakers[0] == ref.speaker
        rows.append({
            "ref_turn": {"speaker": ref.speaker, "start": ref.start,
                         "end": ref.end, "text": ref.text},
            "hyp_text": hyp_text,
            "hyp_speakers": hyp_speakers,
            "wer": round(wer, 3),
            "speaker_correct": speaker_correct,
            "notes": "",
        })
    return rows


# -----------------------------------------------------------------------------
# Report writer
# -----------------------------------------------------------------------------

def write_markdown_report(report: ScoreReport, path: Path, config: dict | None = None) -> None:
    lines: list[str] = []
    lines.append(f"# Benchmark Report")
    lines.append("")
    lines.append(f"- Hypothesis: `{report.hypothesis_label}`")
    lines.append(f"- Ground truth: `{report.ground_truth_label}`")
    if config:
        lines.append(f"- Parameters: `{json.dumps(config)}`")
    lines.append("")
    lines.append("## Summary scores")
    lines.append("")
    lines.append("| Metric | Value |")
    lines.append("|---|---|")
    lines.append(f"| Plain WER (no speaker) | {report.plain_wer*100:.2f}% |")
    lines.append(f"| **cpWER** | **{report.cp_wer*100:.2f}%** |")
    lines.append(f"| **DER** | **{report.der*100:.2f}%** |")
    lines.append(f"| &nbsp;&nbsp;DER miss rate | {report.der_miss*100:.2f}% |")
    lines.append(f"| &nbsp;&nbsp;DER false-alarm rate | {report.der_fa*100:.2f}% |")
    lines.append(f"| &nbsp;&nbsp;DER speaker-error rate | {report.der_speaker_error*100:.2f}% |")
    lines.append(f"| Mid-sentence flips in hypothesis | {report.mid_sentence_flips} |")
    lines.append("")
    lines.append("## Counts")
    lines.append("")
    lines.append("| | Ground truth | Hypothesis |")
    lines.append("|---|---|---|")
    lines.append(f"| Turns | {report.gt_turn_count} | {report.hyp_turn_count} |")
    lines.append(f"| Words | {report.gt_word_count} | {report.hyp_word_count} |")
    lines.append(f"| Speakers | {len(report.gt_speakers)} ({', '.join(report.gt_speakers)}) | {len(report.hyp_speakers)} ({', '.join(report.hyp_speakers)}) |")
    lines.append(f"| Covered duration | {report.gt_duration:.1f}s | {report.hyp_duration:.1f}s |")
    lines.append("")
    lines.append(f"Best speaker mapping (hyp → ref): `{report.speaker_mapping}`")
    lines.append("")
    lines.append("## Per-turn errors (ground-truth-aligned)")
    lines.append("")
    lines.append("Each row shows one ground-truth turn, the hypothesis text that overlapped it,")
    lines.append("and whether the speaker label was correct after applying the best mapping.")
    lines.append("WER is computed between the ref turn text and the concatenation of hyp turns")
    lines.append("whose time overlapped it. Sorted by descending WER.")
    lines.append("")
    worst = sorted(report.per_turn_errors, key=lambda r: -r["wer"])
    shown = 0
    for row in worst:
        if row["wer"] < 0.05 and row["speaker_correct"]:
            continue
        shown += 1
        if shown > 30:
            break
        ref = row["ref_turn"]
        spk_ok = "✓" if row["speaker_correct"] else "✗"
        lines.append(f"### {spk_ok} [{ref['speaker']}] {ref['start']:.1f}-{ref['end']:.1f}s — WER {row['wer']*100:.0f}%")
        lines.append("")
        lines.append(f"**Expected**: {ref['text']}")
        lines.append("")
        hyp_txt = row["hyp_text"] or "*(no hypothesis content)*"
        hyp_speakers_str = ", ".join(row["hyp_speakers"]) if row["hyp_speakers"] else "—"
        lines.append(f"**Got** ({hyp_speakers_str}): {hyp_txt}")
        if row["notes"]:
            lines.append("")
            lines.append(f"*Notes*: {row['notes']}")
        lines.append("")
    if shown == 0:
        lines.append("*All turns matched at WER < 5% and correct speaker — nothing to flag!*")

    path.write_text("\n".join(lines), encoding="utf-8")


# -----------------------------------------------------------------------------
# Main
# -----------------------------------------------------------------------------

def score(hyp_turns: list[Turn], ref_turns: list[Turn],
          hyp_label: str, gt_label: str) -> ScoreReport:
    r = ScoreReport(hypothesis_label=hyp_label, ground_truth_label=gt_label)

    r.gt_turn_count = len(ref_turns)
    r.gt_word_count = sum(len(t.text.split()) for t in ref_turns)
    r.gt_speakers = sorted({t.speaker for t in ref_turns})
    r.gt_duration = max((t.end for t in ref_turns), default=0.0)

    r.hyp_turn_count = len(hyp_turns)
    r.hyp_word_count = sum(len(t.text.split()) for t in hyp_turns)
    r.hyp_speakers = sorted({t.speaker for t in hyp_turns})
    r.hyp_duration = max((t.end for t in hyp_turns), default=0.0)

    r.plain_wer = plain_wer(hyp_turns, ref_turns)
    r.cp_wer, r.speaker_mapping = cp_wer(hyp_turns, ref_turns)
    r.der, r.der_miss, r.der_fa, r.der_speaker_error = compute_der(
        hyp_turns, ref_turns, r.speaker_mapping
    )
    flips, _examples = count_mid_sentence_flips(hyp_turns)
    r.mid_sentence_flips = flips
    r.per_turn_errors = per_turn_error_report(hyp_turns, ref_turns, r.speaker_mapping)
    return r


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("hypothesis", type=Path, help="hypothesis JSON (project.json or extracted)")
    parser.add_argument("ground_truth", type=Path, help="ground-truth JSON from import_ground_truth.py")
    parser.add_argument("--pass-kind", default=None,
                        help="select a specific pass by kind (e.g. deepReviewConsensus)")
    parser.add_argument("--report", type=Path, default=None,
                        help="output markdown report path (default: <hypothesis>.report.md)")
    args = parser.parse_args()

    hyp_turns, hyp_label = load_hypothesis(args.hypothesis, args.pass_kind)
    ref_turns, gt_label = load_hypothesis(args.ground_truth, None)

    report = score(hyp_turns, ref_turns, hyp_label, gt_label)

    report_path = args.report or args.hypothesis.with_suffix(".report.md")
    write_markdown_report(report, report_path)

    print(f"--- scores for {hyp_label} vs {gt_label} ---")
    print(f"  Plain WER:  {report.plain_wer*100:.2f}%")
    print(f"  cpWER:      {report.cp_wer*100:.2f}%")
    print(f"  DER:        {report.der*100:.2f}%  (miss={report.der_miss*100:.2f}%, fa={report.der_fa*100:.2f}%, spk_err={report.der_speaker_error*100:.2f}%)")
    print(f"  mid-sentence flips:   {report.mid_sentence_flips}")
    print(f"  hyp turns={report.hyp_turn_count}, gt turns={report.gt_turn_count}")
    print(f"  speaker mapping: {report.speaker_mapping}")
    print(f"Wrote report: {report_path}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
