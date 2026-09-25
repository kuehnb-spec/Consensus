#!/usr/bin/env python3
"""
Experiment: resolve VibeVoice-vs-Nemotron speaker disagreements by voice.

Follows experiment_speaker_witness.py. For each run of consecutive words where
Nemotron's speaker (translated into VibeVoice's labels) disagrees with
VibeVoice's, cut exactly that audio, embed it with CAM++, and compare it with a
voiceprint of each candidate speaker. A voiceprint is up to 20 s of that
speaker's audio taken from segments where VibeVoice, Nemotron and community-1
all agree. The run switches to Nemotron's speaker only when it sounds closer by
more than MARGIN. Grading uses the same text-aligned truth.

    experiment_voice_match.py --corpus TestCorpus/oyez --runs TestCorpus/runs \
        --fluidaudio TestCorpus/tools/fluidaudiocli
"""

from __future__ import annotations

import argparse
import bisect
import json
import subprocess
import tempfile
from collections import defaultdict
from pathlib import Path

from experiment_speaker_witness import load_rttm, one_to_one, overlap_map, speaker_at, text_truth, to_turns

MARGINS = [0.0, 0.05, 0.10, 0.15]
MIN_SPAN = 1.0      # seconds of audio embedded for a disputed run (padded if shorter)
PRINT_SECONDS = 20.0


def cut(src: Path, start: float, dur: float, dst: Path) -> None:
    subprocess.run(["ffmpeg", "-loglevel", "error", "-y", "-ss", f"{max(0, start):.3f}", "-t", f"{dur:.3f}",
                    "-i", str(src), "-ac", "1", "-ar", "16000", str(dst)], check=True)


def concat(parts: list[Path], dst: Path, tmp: Path) -> None:
    lst = tmp / (dst.stem + ".txt")
    lst.write_text("".join(f"file '{p}'\n" for p in parts))
    subprocess.run(["ffmpeg", "-loglevel", "error", "-y", "-f", "concat", "-safe", "0", "-i", str(lst),
                    "-c", "copy", str(dst)], check=True)


def cos(a, b):
    na = sum(x * x for x in a) ** 0.5 or 1
    nb = sum(x * x for x in b) ** 0.5 or 1
    return sum(x * y for x, y in zip(a, b)) / (na * nb)


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--corpus", type=Path, required=True)
    ap.add_argument("--runs", type=Path, required=True)
    ap.add_argument("--fluidaudio", type=Path, required=True)
    args = ap.parse_args()
    runs = args.runs
    tmp = Path(tempfile.mkdtemp(prefix="voicematch-"))
    manifest = json.loads((args.corpus / "manifest.json").read_text())

    clips = {}
    wavs = []
    for clip in (c["id"] for c in manifest["clips"]):
        wav = args.corpus / f"{clip}.wav"
        vv = json.loads((runs / "vibevoice" / f"{clip}.consensus.json").read_text())
        ref = json.loads((args.corpus / f"{clip}.fixture.json").read_text())["turns"]
        vv_segs = sorted((s["start"], s["end"], s["speaker"]) for s in vv["segments"])
        ref_segs = sorted((t["start"], t["end"], t["speaker"]) for t in ref)
        words = [(w["start"], w["end"], w["word"], s["speaker"], si)
                 for si, s in enumerate(vv["segments"]) for w in s.get("words") or []]
        wit = {}
        for name, d in (("nm", "nemotron3-offline"), ("c1", "community1")):
            segs = load_rttm(runs / d / f"{clip}.rttm")
            m = overlap_map(segs, vv_segs)
            starts = [x[0] for x in segs]
            wit[name] = [m.get(speaker_at(segs, starts, (a + b) / 2)) for a, b, *_ in words]
        ref_to_vv = {r: v for v, r in one_to_one(vv_segs, ref_segs).items()}
        truth = text_truth(words, ref, ref_to_vv)
        nm, c1 = wit["nm"], wit["c1"]

        # disputed runs: consecutive words with the same (vibevoice, nemotron) disagreement
        disputes = []
        for i, w in enumerate(words):
            if nm[i] is None or nm[i] == w[3]:
                continue
            if disputes and disputes[-1]["pair"] == (w[3], nm[i]) and w[0] - words[disputes[-1]["idx"][-1]][1] < 0.3:
                disputes[-1]["idx"].append(i)
            else:
                disputes.append({"pair": (w[3], nm[i]), "idx": [i]})
        for k, d in enumerate(disputes):
            a, b = words[d["idx"][0]][0], words[d["idx"][-1]][1]
            if b - a < MIN_SPAN:
                mid = (a + b) / 2
                a, b = mid - MIN_SPAN / 2, mid + MIN_SPAN / 2
            d["wav"] = tmp / f"{clip}_d{k}.wav"
            cut(wav, a, b - a, d["wav"])
            wavs.append(d["wav"])

        # voiceprints from segments where every word's three witnesses agree
        prints = {}
        by_seg = defaultdict(list)
        for i, w in enumerate(words):
            by_seg[w[4]].append(i)
        need = {lab for d in disputes for lab in d["pair"]}
        for lab in need:
            parts, total = [], 0.0
            for si, idx in by_seg.items():
                if words[idx[0]][3] != lab or not all(nm[i] == lab and c1[i] == lab for i in idx):
                    continue
                a, b = words[idx[0]][0], words[idx[-1]][1]
                if b - a < 1.5:
                    continue
                p = tmp / f"{clip}_p{lab}_{si}.wav"
                cut(wav, a, b - a, p)
                parts.append(p)
                total += b - a
                if total >= PRINT_SECONDS:
                    break
            if parts:
                prints[lab] = tmp / f"{clip}_print_{lab}.wav"
                concat(parts, prints[lab], tmp)
                wavs.append(prints[lab])
        clips[clip] = dict(words=words, truth=truth, disputes=disputes, prints=prints)

    lst = tmp / "list.txt"
    lst.write_text("\n".join(str(w) for w in wavs))
    out = tmp / "emb.json"
    subprocess.run([str(args.fluidaudio), "campplus-batch", str(lst), str(out)], check=True)
    emb = json.loads(out.read_text())

    print(f"{sum(len(c['disputes']) for c in clips.values())} disputed runs, {len(emb)} clips embedded")
    for margin in MARGINS:
        name = f"vv-voice-{margin:.2f}"
        (runs / name).mkdir(exist_ok=True)
        fixed = broke = switched = 0
        for clip, c in clips.items():
            spk = [w[3] for w in c["words"]]
            for d in c["disputes"]:
                vv_lab, nm_lab = d["pair"]
                e = emb.get(str(d["wav"]))
                pv, pn = c["prints"].get(vv_lab), c["prints"].get(nm_lab)
                if e is None or pv is None or pn is None:
                    continue
                if cos(e, emb[str(pn)]) - cos(e, emb[str(pv)]) > margin:
                    switched += 1
                    for i in d["idx"]:
                        fixed += c["truth"][i] == nm_lab and spk[i] != nm_lab
                        broke += c["truth"][i] == spk[i]
                        spk[i] = nm_lab
            tagged = [(w[0], w[1], w[2], s) for w, s in zip(c["words"], spk)]
            (runs / name / f"{clip}.turns.json").write_text(json.dumps({"turns": to_turns(tagged)}))
        print(f"margin {margin:.2f}: switched {switched} runs, fixed {fixed} words, broke {broke} words -> {name}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
