"""Apply word-level swaps from a v4 review log onto a baseline transcript.

The v4 judge frequently identifies the *correct* substitution but emits its
correction as a full transcription of the ±5s audio clip, not just the
disputed sub-region. Wholesale replacement therefore over-corrects and inflates
WER massively.

This script does the right thing:
  For each FLIPPED review, take the candidate text (a_text) and the judge's
  proposed correction (judge_corrected, or judge_heard as fallback). Run a
  word-level diff via SequenceMatcher. For every 'replace' opcode, swap the
  candidate's words with the proposed words. For 'equal' opcodes, leave alone.
  For 'insert' opcodes — words that appear in the correction but not in the
  candidate — only accept them if they are genuinely substantive content
  (not filler). For 'delete' opcodes — words in candidate but not in
  correction — keep the candidate's words (don't delete blindly).

Output: a corrected transcript JSON identical to the baseline except for
word-level edits in segments where a flipped review applied.
"""

from __future__ import annotations

import argparse
import json
import re
import sys
from difflib import SequenceMatcher
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
from run_phase_a import normalize_for_comparison, _FILLER_TOKENS


WORD_RE = re.compile(r"\S+")  # Keep punctuation attached to words for natural reconstruction


def tokenize_with_punct(text: str) -> list[str]:
    """Split into whitespace-separated tokens, preserving punctuation."""
    return WORD_RE.findall(text)


def normalize_token(t: str) -> str:
    return re.sub(r"[^\w']", "", t).lower()


def is_filler_token(token: str) -> bool:
    return normalize_token(token) in _FILLER_TOKENS


def word_swap(candidate: str, correction: str) -> str:
    """Apply word-level swaps from `correction` onto `candidate`.

    Strategy:
      - Tokenize both into word-with-punctuation tokens.
      - Run SequenceMatcher on lowercase-stripped versions for alignment.
      - For 'replace' opcodes: swap candidate tokens for correction tokens.
      - For 'equal' opcodes: keep candidate tokens (preserves casing/punctuation).
      - For 'insert' opcodes (correction has extra words): only insert if
        the new words look substantive (not all filler).
      - For 'delete' opcodes (candidate has extra words): keep them. Only
        risk a deletion if the candidate's removed words are obviously
        filler (e.g., a single "uh" or "um").
    """
    cand_tokens = tokenize_with_punct(candidate)
    corr_tokens = tokenize_with_punct(correction)
    if not cand_tokens:
        return correction
    if not corr_tokens:
        return candidate

    cand_norm = [normalize_token(t) for t in cand_tokens]
    corr_norm = [normalize_token(t) for t in corr_tokens]

    matcher = SequenceMatcher(a=cand_norm, b=corr_norm, autojunk=False)
    out: list[str] = []
    for tag, i1, i2, j1, j2 in matcher.get_opcodes():
        if tag == "equal":
            out.extend(cand_tokens[i1:i2])
        elif tag == "replace":
            # Trust the correction here — this is the swap we believe in.
            out.extend(corr_tokens[j1:j2])
        elif tag == "insert":
            insertion = corr_tokens[j1:j2]
            # Only insert non-filler words. If all are fillers, skip.
            if any(not is_filler_token(t) for t in insertion):
                out.extend(insertion)
        elif tag == "delete":
            deletion = cand_tokens[i1:i2]
            # Only delete from candidate if all the deleted words are fillers.
            if not all(is_filler_token(t) for t in deletion):
                out.extend(deletion)
            # else: drop them
    return " ".join(out)


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--baseline", type=Path, required=True,
                        help="Original (un-corrected) baseline transcript JSON.")
    parser.add_argument("--review-log", type=Path, required=True,
                        help="phase_a_v*_review.jsonl with applied=true rows to use.")
    parser.add_argument("--out", type=Path, required=True)
    parser.add_argument("--prefer", choices=("heard", "corrected"), default="corrected",
                        help="Which judge field to use as the correction source.")
    args = parser.parse_args()

    baseline = json.loads(args.baseline.read_text())
    segments = baseline.get("segments") or []
    by_idx_map: dict[int, str] = {}

    review_records = [json.loads(l) for l in args.review_log.read_text().splitlines() if l.strip()]
    for rec in review_records:
        if not rec.get("applied"):
            continue
        candidate = rec.get("a_text", "").strip()
        correction = (rec.get(f"judge_{args.prefer}") or "").strip()
        if not correction:
            # Fall back to the other field
            other = "heard" if args.prefer == "corrected" else "corrected"
            correction = (rec.get(f"judge_{other}") or "").strip()
        if not correction:
            continue
        new_text = word_swap(candidate, correction)
        for ai in rec.get("a_segment_indices", []):
            by_idx_map[ai] = new_text

    out_segments = []
    for i, seg in enumerate(segments):
        new_seg = dict(seg)
        if i in by_idx_map:
            new_seg["original_text"] = seg.get("text")
            new_seg["text"] = by_idx_map[i]
            new_seg["corrected_by"] = "word_swap"
        out_segments.append(new_seg)
    out = dict(baseline)
    out["segments"] = out_segments
    args.out.write_text(json.dumps(out, indent=2))
    print(f"[apply] applied word-level swaps to {len(by_idx_map)} segments")
    return 0


if __name__ == "__main__":
    sys.exit(main())
