#!/usr/bin/env python3
"""
Simulate alternative merge strategies against a ground-truth transcript without
rebuilding the Swift pipeline. Loads Engine A's and Engine B's word streams from
a project.json (deepReviewPrimary + deepReviewComparison passes), applies
different merge rules in pure Python, scores each against ground truth.

The goal is to identify which merge policy beats the current Swift merge
(33.15% WER on this test) on cpWER + DER, then port that policy back to Swift.

Strategies evaluated:

  A. engine_a_only
     Pass Engine A's transcript through unchanged. Equivalent to Standard pass —
     used as a "no merge" baseline.

  B. engine_b_text_a_speakers
     Use Engine B's word stream for TEXT, look up speaker for each word from
     Engine A's segment timeline. Gives us Engine B's (supposedly better)
     text accuracy + Engine A's good speaker labels.

  C. a_text_fill_gaps_with_b
     Start with Engine A's text. For any gap (>1.5s) between Engine A words,
     fill with Engine B words that fall in the gap. Avoids the shuffling
     problem because we don't interleave — we only INSERT in gaps.

  D. a_text_replace_low_conf_with_b
     Start with Engine A's text. For each A-word below confidence 0.5, find the
     closest-in-time B-word (within 0.6s) and substitute if B's confidence is
     higher. One-for-one substitution — no word ordering change.

  E. current_merge (for reference)
     Scored via the existing deepReviewConsensus pass already in the project.
"""

from __future__ import annotations

import argparse
import json
import sys
from dataclasses import dataclass
from pathlib import Path

SCRIPT_DIR = Path(__file__).resolve().parent
sys.path.insert(0, str(SCRIPT_DIR))

from score import Turn, score as score_turns, plain_wer, cp_wer, compute_der, \
    count_mid_sentence_flips, load_hypothesis, write_markdown_report


@dataclass
class WordEntry:
    word: str
    start: float
    end: float
    probability: float
    speaker: str  # engine A's speaker label


def extract_word_streams(project_path: Path) -> tuple[list[WordEntry], list[WordEntry], dict[str, str], list[Turn], list[Turn]]:
    """Return (engine_a_words, engine_b_words, speaker_mapping, engine_a_turns, engine_b_turns).

    Engine A = deepReviewPrimary pass (but we note this pass was MANUALLY EDITED
    so the unedited baseline for Engine A is actually the `standard` pass. We'll
    use `standard` here.)

    Engine B = deepReviewComparison pass (Whisper Large v3, no diarization).
    """
    doc = json.loads(project_path.read_text(encoding="utf-8"))
    mapping_names = doc.get("speakerMapping", {}).get("names", {})

    def get_pass(kind: str) -> dict:
        for p in doc["passes"]:
            if p.get("kind") == kind:
                return p
        raise ValueError(f"no pass {kind}")

    a_pass = get_pass("standard")
    b_pass = get_pass("deepReviewComparison")

    def extract_words(segs: list[dict]) -> list[WordEntry]:
        result = []
        for s in segs:
            speaker = mapping_names.get(s.get("speakerID", "UNKNOWN"),
                                        s.get("speakerID", "UNKNOWN")).upper()
            words = s.get("words") or []
            if not words:
                # Approximate: split segment text and linearly distribute times
                tokens = s.get("text", "").split()
                dur = max(0.01, s.get("end", 0) - s.get("start", 0))
                per = dur / max(1, len(tokens))
                for i, tok in enumerate(tokens):
                    result.append(WordEntry(
                        word=tok,
                        start=float(s.get("start", 0) + i * per),
                        end=float(s.get("start", 0) + (i + 1) * per),
                        probability=0.5,
                        speaker=speaker,
                    ))
            else:
                for w in words:
                    result.append(WordEntry(
                        word=w["word"],
                        start=float(w["start"]),
                        end=float(w["end"]),
                        probability=float(w.get("probability", 0.5)),
                        speaker=speaker,
                    ))
        return result

    a_words = extract_words(a_pass["result"]["segments"])
    b_words = extract_words(b_pass["result"]["segments"])

    def segs_to_turns(segs: list[dict]) -> list[Turn]:
        out = []
        for s in segs:
            speaker = mapping_names.get(s.get("speakerID", "UNKNOWN"),
                                        s.get("speakerID", "UNKNOWN")).upper()
            out.append(Turn(speaker=speaker,
                            start=float(s.get("start", 0)),
                            end=float(s.get("end", 0)),
                            text=s.get("text", "").strip()))
        return out

    return a_words, b_words, mapping_names, segs_to_turns(a_pass["result"]["segments"]), \
           segs_to_turns(b_pass["result"]["segments"])


# -----------------------------------------------------------------------------
# Speaker timeline lookup
# -----------------------------------------------------------------------------

def build_speaker_timeline(words: list[WordEntry]) -> list[tuple[float, float, str]]:
    """From A's word stream, build (start, end, speaker) speaker regions by
    merging consecutive same-speaker words."""
    if not words:
        return []
    regions = []
    cur_start = words[0].start
    cur_end = words[0].end
    cur_speaker = words[0].speaker
    for w in words[1:]:
        if w.speaker == cur_speaker and w.start - cur_end < 1.0:
            cur_end = w.end
        else:
            regions.append((cur_start, cur_end, cur_speaker))
            cur_start, cur_end, cur_speaker = w.start, w.end, w.speaker
    regions.append((cur_start, cur_end, cur_speaker))
    return regions


def speaker_at(time: float, regions: list[tuple[float, float, str]]) -> str:
    for s, e, sp in regions:
        if s <= time <= e:
            return sp
    # Fall back to nearest region
    best = None
    best_dist = float("inf")
    for s, e, sp in regions:
        d = min(abs(time - s), abs(time - e))
        if d < best_dist:
            best_dist = d
            best = sp
    return best or "UNKNOWN"


# -----------------------------------------------------------------------------
# Turn grouping from a word stream
# -----------------------------------------------------------------------------

def words_to_turns(words: list[WordEntry], gap_threshold: float = 1.5) -> list[Turn]:
    """Group consecutive same-speaker words into turns, splitting on long pauses."""
    if not words:
        return []
    turns: list[Turn] = []
    cur = [words[0]]
    for w in words[1:]:
        last = cur[-1]
        if w.speaker == last.speaker and w.start - last.end < gap_threshold:
            cur.append(w)
        else:
            text = " ".join(x.word for x in cur)
            turns.append(Turn(speaker=cur[0].speaker,
                              start=cur[0].start,
                              end=cur[-1].end,
                              text=text))
            cur = [w]
    if cur:
        text = " ".join(x.word for x in cur)
        turns.append(Turn(speaker=cur[0].speaker,
                          start=cur[0].start,
                          end=cur[-1].end,
                          text=text))
    return turns


# -----------------------------------------------------------------------------
# Strategies
# -----------------------------------------------------------------------------

def strategy_a_only(a_words: list[WordEntry], b_words: list[WordEntry]) -> list[WordEntry]:
    """Pass through Engine A unchanged."""
    return list(a_words)


def strategy_b_text_a_speakers(a_words: list[WordEntry], b_words: list[WordEntry]) -> list[WordEntry]:
    """Use Engine B's text; look up each word's speaker from A's timeline."""
    regions = build_speaker_timeline(a_words)
    out = []
    for w in b_words:
        mid = (w.start + w.end) / 2
        spk = speaker_at(mid, regions)
        out.append(WordEntry(word=w.word, start=w.start, end=w.end,
                             probability=w.probability, speaker=spk))
    return out


def strategy_a_text_fill_gaps_with_b(a_words: list[WordEntry], b_words: list[WordEntry],
                                      gap_threshold: float = 1.5) -> list[WordEntry]:
    """Use A's words. For any gap > gap_threshold, splice in B's words that fall in the gap."""
    if not a_words:
        return list(b_words)
    merged: list[WordEntry] = [a_words[0]]
    for i in range(1, len(a_words)):
        prev = a_words[i - 1]
        cur = a_words[i]
        gap = cur.start - prev.end
        if gap > gap_threshold:
            # Find B words in (prev.end, cur.start)
            for bw in b_words:
                if bw.start >= prev.end and bw.end <= cur.start:
                    merged.append(WordEntry(word=bw.word, start=bw.start, end=bw.end,
                                            probability=bw.probability,
                                            speaker=prev.speaker))  # keep prev's speaker
        merged.append(cur)
    return merged


def strategy_a_text_replace_low_conf(a_words: list[WordEntry], b_words: list[WordEntry],
                                     conf_threshold: float = 0.5,
                                     b_boost: float = 0.2,
                                     time_tolerance: float = 0.6) -> list[WordEntry]:
    """For each low-confidence A word, if there's a close-in-time B word with
    substantially higher confidence, substitute it (keeping A's speaker)."""
    out = []
    for aw in a_words:
        if aw.probability >= conf_threshold:
            out.append(aw)
            continue
        # Find best B match within time tolerance
        best = None
        best_score = aw.probability + b_boost  # must exceed this to substitute
        for bw in b_words:
            if abs(bw.start - aw.start) > time_tolerance and abs(bw.end - aw.end) > time_tolerance:
                continue
            if bw.probability > best_score:
                best = bw
                best_score = bw.probability
        if best:
            out.append(WordEntry(word=best.word, start=aw.start, end=aw.end,
                                 probability=best.probability, speaker=aw.speaker))
        else:
            out.append(aw)
    return out


def strategy_aligned_b_text_a_speakers(a_words: list[WordEntry], b_words: list[WordEntry],
                                        time_tolerance: float = 1.0) -> list[WordEntry]:
    """Greedy word alignment: match each B-word to the nearest A-word within
    time tolerance. Use B's text. Assign speaker from the matched A-word. If no
    A-word matches, fall back to timeline lookup.

    This should give us B's (better) text accuracy AND A's (tighter) speaker
    precision, avoiding the DER degradation of pure timeline lookup.
    """
    regions = build_speaker_timeline(a_words)
    # For efficient match lookup: sort A-words by start time
    a_sorted = sorted(a_words, key=lambda w: w.start)

    out = []
    a_cursor = 0
    used_a_indices: set[int] = set()
    for bw in b_words:
        # Find closest A-word within tolerance
        # Advance cursor past A-words that end before B's start - tolerance
        while a_cursor < len(a_sorted) and a_sorted[a_cursor].end < bw.start - time_tolerance:
            a_cursor += 1

        best_idx = None
        best_dist = float("inf")
        probe = a_cursor
        while probe < len(a_sorted) and a_sorted[probe].start <= bw.end + time_tolerance:
            if probe in used_a_indices:
                probe += 1
                continue
            a_mid = (a_sorted[probe].start + a_sorted[probe].end) / 2
            b_mid = (bw.start + bw.end) / 2
            dist = abs(a_mid - b_mid)
            # Penalize text mismatch slightly — prefer aligning matching words
            if _normalize(a_sorted[probe].word) != _normalize(bw.word):
                dist += 0.2
            if dist < best_dist:
                best_dist = dist
                best_idx = probe
            probe += 1

        if best_idx is not None:
            speaker = a_sorted[best_idx].speaker
            used_a_indices.add(best_idx)
        else:
            mid = (bw.start + bw.end) / 2
            speaker = speaker_at(mid, regions)

        out.append(WordEntry(word=bw.word, start=bw.start, end=bw.end,
                             probability=bw.probability, speaker=speaker))
    return out


def _normalize(w: str) -> str:
    return w.lower().strip(" \t\n.,?!:;")


STRATEGIES = {
    "a_only": strategy_a_only,
    "b_text_a_speakers": strategy_b_text_a_speakers,
    "aligned_b_text_a_speakers": strategy_aligned_b_text_a_speakers,
    "a_fill_gaps_with_b": strategy_a_text_fill_gaps_with_b,
    "a_replace_low_conf_with_b": strategy_a_text_replace_low_conf,
}


# -----------------------------------------------------------------------------
# Main
# -----------------------------------------------------------------------------

def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("project", type=Path)
    parser.add_argument("ground_truth", type=Path)
    parser.add_argument("--output-dir", type=Path, default=Path("/tmp/merge-sim"))
    args = parser.parse_args()

    args.output_dir.mkdir(parents=True, exist_ok=True)

    a_words, b_words, _mapping, a_turns, b_turns = extract_word_streams(args.project)
    print(f"Loaded {len(a_words)} A-words (standard pass), {len(b_words)} B-words (Whisper)")

    ref_turns, _ = load_hypothesis(args.ground_truth, None)

    results = []
    for name, fn in STRATEGIES.items():
        merged = fn(a_words, b_words)
        turns = words_to_turns(merged)
        report = score_turns(turns, ref_turns, hyp_label=name, gt_label=args.ground_truth.name)
        results.append((name, report))
        out_md = args.output_dir / f"{name}.report.md"
        write_markdown_report(report, out_md)

    # Print leaderboard
    print()
    print(f"{'strategy':<35} {'plain WER':>10} {'cpWER':>10} {'DER':>10} {'flips':>8} {'turns':>6}")
    print("-" * 85)
    for name, r in sorted(results, key=lambda x: x[1].cp_wer):
        print(f"{name:<35} {r.plain_wer*100:>9.2f}% {r.cp_wer*100:>9.2f}% {r.der*100:>9.2f}% "
              f"{r.mid_sentence_flips:>8} {r.hyp_turn_count:>6}")

    # Include the Swift consensus for reference
    cons_turns, cons_label = load_hypothesis(args.project, "deepReviewConsensus")
    cons_report = score_turns(cons_turns, ref_turns, hyp_label="swift_consensus (baseline)",
                              gt_label=args.ground_truth.name)
    print(f"{'swift_consensus (reference)':<35} {cons_report.plain_wer*100:>9.2f}% "
          f"{cons_report.cp_wer*100:>9.2f}% {cons_report.der*100:>9.2f}% "
          f"{cons_report.mid_sentence_flips:>8} {cons_report.hyp_turn_count:>6}")
    write_markdown_report(cons_report, args.output_dir / "swift_consensus.report.md")

    return 0


if __name__ == "__main__":
    sys.exit(main())
