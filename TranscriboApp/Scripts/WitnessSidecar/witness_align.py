#!/usr/bin/env python3
"""
Word-witness alignment for `consensus transcribe --witness ID`.

The primary engine (VibeVoice) writes the transcript; a second engine (the
witness) transcribes the same audio independently. Where the two disagree is
where the primary's errors concentrate (Proving Ground, 2026-10-29: Parakeet
as witness covers 59% of VibeVoice's word errors at a ~6% flag rate). This
step aligns the two word streams and returns those disagreements as disputes.

It is the runtime port of Scripts/proving-ground/experiment_word_witness.py
`disputes()`: both streams are normalised exactly the way the scorer does
(Whisper's English normaliser, then pg_text.collapse_repeats), so filler,
casing, punctuation, spelling-variant and number-format differences are not
disputes. Alignment is word-level minimum edit distance; every primary word the
witness substitutes or drops is disputed, and both neighbours of a word the
witness inserts.

Pure standard library apart from the vendored normaliser (needs `regex`, which
the Consensus venv already has). Reads one JSON object on stdin, writes one on
stdout; never logs transcript text.

stdin:  {"witness_id": "parakeet",
         "primary": [["So,", "is", ...], ...],          # words per segment
         "witness": [{"word": "So", "start": 0.16, "end": 0.4}, ...]}
stdout: {"disputes": [...], "stats": {...}}
"""

from __future__ import annotations

import json
import os
import sys
from difflib import SequenceMatcher

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from whisper_english import EnglishTextNormalizer  # noqa: E402

_NORMALIZER = EnglishTextNormalizer()
NORMALIZATION = "whisper-english+collapse-repeats"


# --- Normalisation (identical to Scripts/proving-ground/pg_text.py) ----------

def collapse_repeats(tokens: list[str], max_n: int = 3) -> list[str]:
    out: list[str] = []
    for tok in tokens:
        out.append(tok)
        for n in range(max_n, 0, -1):
            if len(out) >= 2 * n and out[-n:] == out[-2 * n:-n]:
                del out[-n:]
                break
    return out


def content(text: str) -> list[str]:
    return collapse_repeats(_NORMALIZER(text).split())


def normalize_with_origin(words: list[str]) -> tuple[list[str], list[int]]:
    """Normalised tokens of a word run, plus the index of the original word
    each token came from. Fast path: per-word normalisation concatenates to
    the same tokens as normalising the run. Otherwise (numbers spanning words,
    repeats across words) the origin of token t is the shortest prefix whose
    normalisation already has more than t tokens."""
    if not words:
        return [], []
    whole = content(" ".join(words))
    per_word = [_NORMALIZER(w).split() for w in words]
    flat = [t for toks in per_word for t in toks]
    if flat == whole:
        return whole, [i for i, toks in enumerate(per_word) for _ in toks]
    origin: list[int] = []
    best = 0
    for k in range(1, len(words) + 1):
        best = max(best, min(len(content(" ".join(words[:k]))), len(whole)))
        while len(origin) < best:
            origin.append(k - 1)
    while len(origin) < len(whole):
        origin.append(len(words) - 1)
    return whole, origin


# --- Alignment -----------------------------------------------------------------

def _levenshtein_ops(a: list[str], b: list[str], a0: int, b0: int):
    """Minimum-edit opcodes between two short runs (offsets a0/b0 applied)."""
    n, m = len(a), len(b)
    if n == 0 and m == 0:
        return []
    if n == 0:
        return [("insert", a0, a0, b0, b0 + m)]
    if m == 0:
        return [("delete", a0, a0 + n, b0, b0)]
    d = [[0] * (m + 1) for _ in range(n + 1)]
    for i in range(n + 1):
        d[i][0] = i
    for j in range(m + 1):
        d[0][j] = j
    for i in range(1, n + 1):
        ai = a[i - 1]
        row, prev = d[i], d[i - 1]
        for j in range(1, m + 1):
            cost = 0 if ai == b[j - 1] else 1
            row[j] = min(prev[j - 1] + cost, prev[j] + 1, row[j - 1] + 1)
    ops = []
    i, j = n, m
    while i > 0 or j > 0:
        if i > 0 and j > 0 and d[i][j] == d[i - 1][j - 1] + (0 if a[i - 1] == b[j - 1] else 1):
            ops.append(("equal" if a[i - 1] == b[j - 1] else "replace", i - 1, i, j - 1, j))
            i, j = i - 1, j - 1
        elif i > 0 and d[i][j] == d[i - 1][j] + 1:
            ops.append(("delete", i - 1, i, j, j))
            i -= 1
        else:
            ops.append(("insert", i, i, j - 1, j))
            j -= 1
    ops.reverse()
    return [(t, a0 + i1, a0 + i2, b0 + j1, b0 + j2) for t, i1, i2, j1, j2 in ops]


def align(a: list[str], b: list[str]):
    """Word-level edit opcodes for whole transcripts. Long exact matches
    (>= 3 words) from difflib anchor the alignment; the gaps between anchors
    are aligned by exact minimum edit distance, so cost stays near-linear on
    hour-long recordings while matching the scorer's alignment inside gaps."""
    sm = SequenceMatcher(None, a, b, autojunk=False)
    anchors = [blk for blk in sm.get_matching_blocks() if blk.size >= 3 or blk.size == 0]
    ops, ia, ib = [], 0, 0
    for blk in anchors:
        ops += _levenshtein_ops(a[ia:blk.a], b[ib:blk.b], ia, ib)
        for k in range(blk.size):
            ops.append(("equal", blk.a + k, blk.a + k + 1, blk.b + k, blk.b + k + 1))
        ia, ib = blk.a + blk.size, blk.b + blk.size
    return ops


# --- Disputes --------------------------------------------------------------------

def find_disputes(primary_segments: list[list[str]], witness_words: list[dict], witness_id: str) -> dict:
    # Primary: normalise per segment, remember (segment, word) for every token.
    p_tokens: list[str] = []
    p_origin: list[tuple[int, int]] = []
    for s, words in enumerate(primary_segments):
        toks, origin = normalize_with_origin(words)
        p_tokens += toks
        p_origin += [(s, o) for o in origin]

    # Witness: normalise in runs broken at pauses (> 0.8 s) or every 40 words.
    w_tokens: list[str] = []
    w_origin: list[int] = []
    run: list[int] = []

    def flush():
        toks, origin = normalize_with_origin([witness_words[i]["word"] for i in run])
        w_tokens.extend(toks)
        w_origin.extend(run[o] for o in origin)
        run.clear()

    for i, w in enumerate(witness_words):
        if run and (len(run) >= 40 or float(w.get("start", 0)) - float(witness_words[run[-1]].get("end", 0)) > 0.8):
            flush()
        run.append(i)
    flush()

    ops = align(p_tokens, w_tokens)
    n = len(p_tokens)

    # Flagged primary tokens, exactly as experiment_word_witness.disputes().
    flagged: set[int] = set()
    for t, i1, i2, j1, j2 in ops:
        if t in ("replace", "delete"):
            flagged.update(range(i1, i2))
        elif t == "insert":
            flagged.update(k for k in (i1 - 1, i1) if 0 <= k < n)

    # Witness position where each primary token's alignment starts and ends.
    w_before = [0] * n
    w_after = [0] * n
    lead_inserts = 0
    tail_insert_end = None
    for t, i1, i2, j1, j2 in ops:
        if t == "insert":
            if i1 == 0:
                lead_inserts = j2
            if i1 == n:
                tail_insert_end = j2
            continue
        if t in ("equal", "replace"):
            for k in range(i2 - i1):
                w_before[i1 + k] = j1 + k
                w_after[i1 + k] = j1 + k + 1
        else:  # delete: zero-width in the witness
            for k in range(i1, i2):
                w_before[k] = j1
                w_after[k] = j1

    # Group flagged tokens into runs that stay inside one primary segment.
    disputes = []
    ordered = sorted(flagged)
    k = 0
    while k < len(ordered):
        start = end = ordered[k]
        while k + 1 < len(ordered) and ordered[k + 1] == end + 1 and p_origin[ordered[k + 1]][0] == p_origin[start][0]:
            k += 1
            end = ordered[k]
        k += 1
        seg = p_origin[start][0]
        word_start, word_end = p_origin[start][1], p_origin[end][1] + 1
        jw0 = lead_inserts if start == 0 and lead_inserts else w_before[start]
        jw1 = tail_insert_end if end == n - 1 and tail_insert_end else w_after[end]
        jw1 = max(jw1, jw0)
        w_idx = sorted({w_origin[j] for j in range(jw0, jw1)})
        span_ops = {t for t, i1, i2, j1, j2 in ops
                    if t != "equal" and ((i1 <= end and i2 > start) or (t == "insert" and start <= i1 <= end + 1))}
        kind = ("substitution" if span_ops == {"replace"} else
                "omission" if span_ops == {"delete"} else
                "insertion" if span_ops == {"insert"} else "mixed")
        dispute = {
            "segment": seg,
            "word_start": word_start,
            "word_end": word_end,
            "primary": " ".join(primary_segments[seg][word_start:word_end]),
            "witness": " ".join(witness_words[i]["word"] for i in w_idx),
            "witness_id": witness_id,
            "kind": kind,
            "witness_start": round(float(witness_words[w_idx[0]]["start"]), 2) if w_idx else None,
            "witness_end": round(float(witness_words[w_idx[-1]]["end"]), 2) if w_idx else None,
        }
        disputes.append(dispute)

    return {
        "disputes": disputes,
        "stats": {
            "normalization": NORMALIZATION,
            "primary_tokens": n,
            "witness_tokens": len(w_tokens),
            "disputed_tokens": len(flagged),
        },
        "_flagged_tokens": sorted(flagged),
    }


def main() -> int:
    payload = json.load(sys.stdin)
    result = find_disputes(payload["primary"], payload.get("witness") or [], payload.get("witness_id", "witness"))
    if not payload.get("debug"):
        result.pop("_flagged_tokens", None)
    json.dump(result, sys.stdout)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
