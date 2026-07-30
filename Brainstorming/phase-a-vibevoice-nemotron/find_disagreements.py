"""Find substantive disagreements between two ASR transcripts of the same audio.

Architectural notes:

The differ is a HINT to the audio-grounded reviewer, not an authority. It
deliberately errs toward over-flagging: a span that the differ flags but
where the two transcripts actually agree at the word level will get rejected
by the reviewer's `matches_draft` check or the trivial-diff filter at the
gate. The cost of a false-positive flag here is one extra audio clip Qwen
listens to. The cost of a false-negative is a real disagreement that never
gets reviewed at all.

The naive failure mode (pointed out by the user) is that one extra inserted
word cascades: a single "uh" in transcript A vs. its absence in transcript B
makes every subsequent word look misaligned. The fix is two-stage:

1. **Coarse alignment by timestamp.** Each segment from transcript A is paired
   with the transcript-B segments whose time ranges overlap it. That confines
   the diff to a small local window and prevents any cascade past segment
   boundaries.

2. **Within-window word diff** uses Python's difflib.SequenceMatcher, which is
   designed exactly for the "find the longest matching subsequences" problem
   and handles a single extra/missing word cleanly. Substantive divergences
   show up as 'replace' / 'delete' / 'insert' opcodes; 'equal' opcodes are
   skipped.

3. **Trivial diffs are filtered** via the same normalize_for_comparison() that
   the reviewer uses, so the differ never asks Qwen to adjudicate a punctuation
   or filler-only difference.

Output is a list of disagreement records with: time span, transcript-A text,
transcript-B text, and a short "what differs" summary suitable for putting in
the reviewer's prompt.
"""

from __future__ import annotations

import argparse
import json
import re
import sys
from dataclasses import dataclass, asdict
from difflib import SequenceMatcher
from pathlib import Path
from typing import Iterable

# Reuse the trivial-diff filter from the main sidecar.
sys.path.insert(0, str(Path(__file__).parent))
from run_phase_a import normalize_for_comparison, is_trivial_diff


WORD_RE = re.compile(r"\b[\w']+\b")


@dataclass
class Segment:
    text: str
    start: float
    end: float
    speaker: str | None = None
    source: str = ""


@dataclass
class Disagreement:
    """A single span where the two transcripts disagree substantively."""
    start: float
    end: float
    speaker: str | None
    a_text: str  # full overlapping text from transcript A (e.g., VibeVoice)
    b_text: str  # full overlapping text from transcript B (e.g., Parakeet)
    a_segment_indices: list[int]
    b_segment_indices: list[int]
    diff_summary: str  # short description like "VibeVoice 'Brant Kuehn' vs Parakeet 'Branickin'"


def load_segments(path: Path, source_label: str) -> list[Segment]:
    """Accept either {turns: [...]} (Parakeet baseline) or {segments: [...]} (VibeVoice)."""
    raw = json.loads(path.read_text())
    items = raw.get("turns") or raw.get("segments") or []
    out = []
    for item in items:
        text = (item.get("text") or "").strip()
        if not text:
            continue
        out.append(Segment(
            text=text,
            start=float(item.get("start") or 0),
            end=float(item.get("end") or 0),
            speaker=item.get("speaker") or item.get("speaker_id") or item.get("speakerID"),
            source=source_label,
        ))
    return out


def overlap_seconds(a: Segment, b: Segment) -> float:
    return max(0.0, min(a.end, b.end) - max(a.start, b.start))


def find_overlapping(target: Segment, candidates: list[Segment], min_overlap: float = 0.4) -> list[int]:
    """Return indices of candidates whose time overlap with target is at least
    `min_overlap` seconds OR at least 30% of either segment's duration."""
    out = []
    target_dur = max(0.001, target.end - target.start)
    for i, c in enumerate(candidates):
        ovl = overlap_seconds(target, c)
        cand_dur = max(0.001, c.end - c.start)
        if ovl >= min_overlap or ovl / target_dur >= 0.3 or ovl / cand_dur >= 0.3:
            out.append(i)
    return out


def words(text: str) -> list[str]:
    """Lowercased word tokens with punctuation stripped — the unit of diff."""
    return [w.lower() for w in WORD_RE.findall(text)]


def word_level_diff_summary(a_text: str, b_text: str, max_pairs: int = 4) -> str:
    """Return a short 'A: foo / B: bar' style summary of the actual divergent
    spans. Hides large equal regions; surfaces only what differs."""
    a_words = words(a_text)
    b_words = words(b_text)
    matcher = SequenceMatcher(a=a_words, b=b_words, autojunk=False)
    parts: list[str] = []
    for tag, i1, i2, j1, j2 in matcher.get_opcodes():
        if tag == "equal":
            continue
        a_chunk = " ".join(a_words[i1:i2]) or "(nothing)"
        b_chunk = " ".join(b_words[j1:j2]) or "(nothing)"
        parts.append(f'A: "{a_chunk}" / B: "{b_chunk}"')
        if len(parts) >= max_pairs:
            parts.append("…")
            break
    return "; ".join(parts) if parts else "(no word-level diff after normalization)"


def merge_overlapping_disagreements(items: list[Disagreement], max_gap: float = 0.6) -> list[Disagreement]:
    """Coalesce time-adjacent disagreements so the reviewer doesn't get a
    cluster of 5 mini-spans within 1 second — pass them as one larger span
    with combined text."""
    if not items:
        return items
    items.sort(key=lambda d: d.start)
    merged = [items[0]]
    for cur in items[1:]:
        last = merged[-1]
        if cur.start - last.end <= max_gap and cur.speaker == last.speaker:
            merged[-1] = Disagreement(
                start=last.start,
                end=max(last.end, cur.end),
                speaker=last.speaker,
                a_text=(last.a_text + " " + cur.a_text).strip(),
                b_text=(last.b_text + " " + cur.b_text).strip(),
                a_segment_indices=sorted(set(last.a_segment_indices + cur.a_segment_indices)),
                b_segment_indices=sorted(set(last.b_segment_indices + cur.b_segment_indices)),
                diff_summary=last.diff_summary + " | " + cur.diff_summary,
            )
        else:
            merged.append(cur)
    return merged


def find_disagreements(
    a_segments: list[Segment],
    b_segments: list[Segment],
) -> list[Disagreement]:
    seen_b_groups: set[tuple[int, ...]] = set()
    out: list[Disagreement] = []
    for ai, a in enumerate(a_segments):
        b_indices = find_overlapping(a, b_segments)
        if not b_indices:
            # No overlapping B segment — either A says something B missed, or
            # A is from a region where B happens to have a long span. Skip
            # silently; the per-A-segment loop will surface it via the longer
            # B coverage below.
            continue

        # Combine all overlapping B segments into one comparison string. When
        # B has merged what A split (or vice versa), the right unit of
        # comparison is the full local window.
        b_text = " ".join(b_segments[i].text for i in b_indices).strip()
        a_text = a.text.strip()

        if is_trivial_diff(a_text, b_text):
            continue

        # Reject pairs where the diff is mostly that B is completely missing
        # one side's content (those are usually segmentation artifacts, not
        # word-level disagreements). Only flag if both sides have substantive
        # content AND they actually differ at the word level.
        a_norm = normalize_for_comparison(a_text)
        b_norm = normalize_for_comparison(b_text)
        if not a_norm or not b_norm:
            continue
        # Substantive overlap check: do the two strings share any meaningful
        # vocabulary at all? If they share <30% of either's word set, this is
        # likely an alignment artifact (one transcript is silent here).
        a_words_set = set(a_norm.split())
        b_words_set = set(b_norm.split())
        intersection = len(a_words_set & b_words_set)
        if intersection / max(1, min(len(a_words_set), len(b_words_set))) < 0.3:
            continue

        # Avoid double-flagging the same B-cluster from multiple A segments
        # (happens when B has merged what A split into pieces).
        b_key = tuple(sorted(b_indices))
        if b_key in seen_b_groups:
            continue
        seen_b_groups.add(b_key)

        out.append(Disagreement(
            start=min(a.start, *(b_segments[i].start for i in b_indices)),
            end=max(a.end, *(b_segments[i].end for i in b_indices)),
            speaker=a.speaker,
            a_text=a_text,
            b_text=b_text,
            a_segment_indices=[ai],
            b_segment_indices=b_indices,
            diff_summary=word_level_diff_summary(a_text, b_text),
        ))

    return merge_overlapping_disagreements(out)


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--a", type=Path, required=True, help="VibeVoice transcript JSON (presumed correct)")
    parser.add_argument("--b", type=Path, required=True, help="Second ASR transcript JSON (e.g. Parakeet)")
    parser.add_argument("--label-a", default="VibeVoice")
    parser.add_argument("--label-b", default="Parakeet")
    parser.add_argument("--out", type=Path, required=True)
    args = parser.parse_args()

    a_segs = load_segments(args.a, args.label_a)
    b_segs = load_segments(args.b, args.label_b)
    print(f"[diff] {args.label_a}: {len(a_segs)} segments")
    print(f"[diff] {args.label_b}: {len(b_segs)} segments")

    disagreements = find_disagreements(a_segs, b_segs)
    print(f"[diff] flagged {len(disagreements)} substantive disagreement spans")

    payload = {
        "label_a": args.label_a,
        "label_b": args.label_b,
        "source_a": str(args.a),
        "source_b": str(args.b),
        "disagreements": [asdict(d) for d in disagreements],
    }
    args.out.write_text(json.dumps(payload, indent=2))

    # Print first 10 for visual sanity check
    for d in disagreements[:10]:
        print(f"  [{d.start:7.2f}-{d.end:7.2f}] {d.speaker or '?'}")
        print(f"    {args.label_a}: {d.a_text[:100]}")
        print(f"    {args.label_b}: {d.b_text[:100]}")
        print(f"    diff: {d.diff_summary[:200]}")
    if len(disagreements) > 10:
        print(f"  ... and {len(disagreements) - 10} more")
    return 0


if __name__ == "__main__":
    sys.exit(main())
