#!/usr/bin/env python3
"""
Experiment: does a second (and third) diarizer, used as a discrepancy
witness, improve speaker attribution over VibeVoice alone?

For every VibeVoice word we look up the speaker each witness diarizer heard
at that moment, translated into VibeVoice's labels by time overlap (no
reference involved — this is what the app could do at runtime). Words where
a witness disagrees are "flagged". The reference is used only to grade, and
each word's true speaker comes from aligning its TEXT to the reference words
(not from reference timestamps: Oyez turn timing drifts by a second or more
on some clips, and time-based truth moved correct words to wrong speakers):

  flag recall     share of VibeVoice's wrong-speaker words that got flagged
  flag precision  share of flagged words where VibeVoice really was wrong
  flag rate       share of all words flagged (the review burden)

Then each resolver rewrites the flagged words' speakers and writes a run
that score_corpus.py can grade for cpWER:

  oracle          at a flag, pick whichever witness matches the reference
                  (the ceiling: perfect resolution of the flags we raised)
  majority        VibeVoice + Nemotron + community-1 vote; 2 of 3 wins
  turn-majority   the same vote, applied only when a witness contests most
                  of a VibeVoice segment (single-word flags are ignored)
  voice-match     at a Nemotron flag, compare the voiceprint of the audio
                  there (community-1's WeSpeaker embedding for that stretch)
                  with each candidate speaker's voiceprint, built from
                  stretches where all three diarizers agree; switch only on
                  a clear margin

    experiment_speaker_witness.py --corpus TestCorpus/oyez --runs TestCorpus/runs
"""

from __future__ import annotations

import argparse
import bisect
import json
from collections import Counter, defaultdict
from pathlib import Path

import jiwer
from pg_text import content


def load_rttm(path: Path):
    segs = []
    for line in path.read_text().splitlines():
        p = line.split()
        if len(p) >= 8 and p[0] == "SPEAKER":
            s = float(p[3])
            segs.append((s, s + float(p[4]), p[7]))
    return sorted(segs)


def speaker_at(segs, starts, t):
    """Speaker whose segment covers t; else the nearest segment's speaker."""
    i = bisect.bisect_right(starts, t)
    best, dist = None, 1e9
    for s, e, spk in segs[max(0, i - 30):i + 2]:
        d = 0.0 if s <= t <= e else min(abs(t - s), abs(t - e))
        if d < dist:
            best, dist = spk, d
    return best


def overlap_map(src, dst):
    """Map each src label to the dst label it overlaps most (many-to-one)."""
    ov = defaultdict(Counter)
    for s1, e1, a in src:
        for s2, e2, b in dst:
            o = min(e1, e2) - max(s1, s2)
            if o > 0:
                ov[a][b] += o
    return {a: c.most_common(1)[0][0] for a, c in ov.items()}


def one_to_one(src, dst):
    """Greedy one-to-one mapping by overlap (for grading, like cpWER)."""
    pairs = defaultdict(float)
    for s1, e1, a in src:
        for s2, e2, b in dst:
            o = min(e1, e2) - max(s1, s2)
            if o > 0:
                pairs[(a, b)] += o
    used_a, used_b, m = set(), set(), {}
    for (a, b), _ in sorted(pairs.items(), key=lambda kv: -kv[1]):
        if a not in used_a and b not in used_b:
            m[a] = b
            used_a.add(a)
            used_b.add(b)
    return m


def text_truth(words, ref_turns, ref_to_vv):
    """True VibeVoice label for each word, via word alignment to the reference."""
    hyp_tok, hyp_owner = [], []
    for i, w in enumerate(words):
        for t in content(w[2]).split():
            hyp_tok.append(t)
            hyp_owner.append(i)
    ref_tok, ref_spk = [], []
    for t in ref_turns:
        for tok in content(t["text"]).split():
            ref_tok.append(tok)
            ref_spk.append(t["speaker"])
    truth = [None] * len(words)
    al = jiwer.process_words(" ".join(ref_tok), " ".join(hyp_tok)).alignments[0]
    for c in al:
        if c.type in ("equal", "substitute"):
            n = min(c.ref_end_idx - c.ref_start_idx, c.hyp_end_idx - c.hyp_start_idx)
            for k in range(n):
                truth[hyp_owner[c.hyp_start_idx + k]] = ref_to_vv.get(ref_spk[c.ref_start_idx + k], "UNMATCHED")
    # inserted words (no reference counterpart) inherit a neighbour's truth
    last = None
    for i in range(len(truth)):
        truth[i] = truth[i] or last
        last = truth[i]
    return [t or "UNMATCHED" for t in truth]


MARGIN = 0.10


def unit(v):
    n = sum(x * x for x in v) ** 0.5 or 1.0
    return [x / n for x in v]


def cos(a, b):
    return sum(x * y for x, y in zip(a, b))


def to_turns(words):
    turns = []
    for ws, we, text, spk in words:
        if turns and turns[-1]["speaker"] == spk and ws - turns[-1]["end"] <= 1.0:
            turns[-1]["end"] = we
            turns[-1]["text"] += " " + text
        else:
            turns.append({"speaker": spk, "start": ws, "end": we, "text": text})
    return turns


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--corpus", type=Path, required=True)
    ap.add_argument("--runs", type=Path, required=True)
    args = ap.parse_args()
    runs = args.runs
    witnesses = {"nemotron3": runs / "nemotron3-offline", "community1": runs / "community1"}
    resolvers = ["oracle", "majority", "turn-majority", "voice-match"]
    for r in resolvers:
        (runs / f"vv-witness-{r}").mkdir(parents=True, exist_ok=True)

    manifest = json.loads((args.corpus / "manifest.json").read_text())
    tot = Counter()
    for clip in (c["id"] for c in manifest["clips"]):
        vv = json.loads((runs / "vibevoice" / f"{clip}.consensus.json").read_text())
        ref = json.loads((args.corpus / f"{clip}.fixture.json").read_text())["turns"]
        ref_segs = sorted((t["start"], t["end"], t["speaker"]) for t in ref)
        vv_segs = sorted((s["start"], s["end"], s["speaker"]) for s in vv["segments"])
        words = []  # (start, end, text, vv_speaker, segment_index)
        for si, s in enumerate(vv["segments"]):
            for w in s.get("words") or []:
                words.append((w["start"], w["end"], w["word"], s["speaker"], si))

        # runtime-side: translate each witness into VibeVoice's label space
        wit = {}
        for name, d in witnesses.items():
            segs = load_rttm(d / f"{clip}.rttm")
            m = overlap_map(segs, vv_segs)
            starts = [x[0] for x in segs]
            wit[name] = [m.get(speaker_at(segs, starts, (a + b) / 2)) for a, b, *_ in words]

        # grading-side: which VibeVoice label is each reference speaker?
        ref_to_vv = {r: v for v, r in one_to_one(vv_segs, ref_segs).items()}
        truth = text_truth(words, ref, ref_to_vv)

        nm, c1 = wit["nemotron3"], wit["community1"]
        seg_flags = defaultdict(list)
        for i, (a, b, text, spk, si) in enumerate(words):
            wrong = spk != truth[i]
            flag_nm = nm[i] is not None and nm[i] != spk
            flag_any = flag_nm or (c1[i] is not None and c1[i] != spk)
            seg_flags[si].append(flag_nm)
            tot["words"] += 1
            tot["wrong"] += wrong
            tot["flag_nm"] += flag_nm
            tot["flag_nm_hit"] += flag_nm and wrong
            tot["flag_any"] += flag_any
            tot["flag_any_hit"] += flag_any and wrong

        # voiceprints: community-1 embeddings of segments whose words all agree
        c1doc = json.loads((witnesses["community1"] / f"{clip}.raw.json").read_text())
        c1segs = [(x["startTimeSeconds"], x["endTimeSeconds"], unit(x["embedding"])) for x in c1doc["segments"]]
        sums = defaultdict(lambda: None)
        for s0, e0, emb in c1segs:
            idx = [i for i, w in enumerate(words) if s0 <= (w[0] + w[1]) / 2 <= e0]
            labs = {words[i][3] for i in idx}
            if len(idx) >= 5 and len(labs) == 1 and all(nm[i] == words[i][3] for i in idx):
                lab = labs.pop()
                sums[lab] = emb if sums[lab] is None else [x + y for x, y in zip(sums[lab], emb)]
        prints = {k: unit(v) for k, v in sums.items() if v is not None}
        c1starts = [x[0] for x in c1segs]

        def voice_pick(i, spk):
            if nm[i] is None or nm[i] == spk or spk not in prints or nm[i] not in prints:
                return spk
            j = bisect.bisect_right(c1starts, (words[i][0] + words[i][1]) / 2) - 1
            if j < 0 or not (c1segs[j][0] <= words[i][1] and words[i][0] <= c1segs[j][1]):
                return spk
            emb = c1segs[j][2]
            return nm[i] if cos(emb, prints[nm[i]]) - cos(emb, prints[spk]) > MARGIN else spk

        out = {r: [] for r in resolvers}
        for i, (a, b, text, spk, si) in enumerate(words):
            votes = Counter(x for x in (spk, nm[i], c1[i]) if x is not None)
            top, n = votes.most_common(1)[0]
            majority = top if n >= 2 else spk
            contested = sum(seg_flags[si]) / max(1, len(seg_flags[si])) > 0.5
            oracle = spk
            if spk != truth[i] and truth[i] in (nm[i], c1[i]):
                oracle = truth[i]
            picks = {"oracle": oracle, "majority": majority,
                     "turn-majority": majority if contested else spk,
                     "voice-match": voice_pick(i, spk)}
            for r in resolvers:
                out[r].append((a, b, text, picks[r]))
                tot[f"changed_{r}"] += picks[r] != spk
                tot[f"fixed_{r}"] += spk != truth[i] and picks[r] == truth[i]
                tot[f"broke_{r}"] += spk == truth[i] and picks[r] != truth[i]
        for r in resolvers:
            (runs / f"vv-witness-{r}" / f"{clip}.turns.json").write_text(
                json.dumps({"turns": to_turns(out[r])}, indent=1), encoding="utf-8")

    w = tot["words"]
    print(f"words {w}; VibeVoice wrong-speaker words {tot['wrong']} ({100 * tot['wrong'] / w:.2f}%)")
    for key, label in (("nm", "Nemotron alone"), ("any", "Nemotron or community-1")):
        f, h = tot[f"flag_{key}"], tot[f"flag_{key}_hit"]
        print(f"flags from {label}: rate {100 * f / w:.1f}% of words, "
              f"recall {100 * h / max(1, tot['wrong']):.1f}%, precision {100 * h / max(1, f):.1f}%")
    for r in resolvers:
        print(f"resolver {r:14s} changed {tot[f'changed_{r}']:5d}  fixed {tot[f'fixed_{r}']:5d}  broke {tot[f'broke_{r}']:5d}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
