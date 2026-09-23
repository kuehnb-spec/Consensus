#!/usr/bin/env python3
"""
Build Proving Ground fixtures from U.S. Supreme Court oral arguments (Oyez).

Why Oyez: the audio is a federal-government recording (public domain), the
words come from the Court's official reporter transcript, and Oyez has
already aligned every turn to the audio with a named speaker. That gives us
speaker-attributed, time-stamped ground truth with zero hand-editing, in a
legal register, with 8-12 distinct speakers per argument and the same
justices recurring across hundreds of recordings (a free cross-recording
voice-identity test). Oyez's curation is CC BY-NC 4.0: we keep this data
local, for evaluation only, with attribution in each fixture.

Known reference quirks (the audit script measures their effect):
  * The official transcript drops most fillers ("um", "uh") — score these
    fixtures with the content-WER track, not verbatim WER.
  * Turns are strictly sequential; real cross-talk is not marked. DER is
    therefore scored with a collar and overlap excluded.
  * Oyez turn timestamps come from forced alignment: good to ~0.5 s.

Usage:
    fetch_oyez.py --out TestCorpus/oyez --clip-minutes 10 \
        --case 2022/21-86 --case 2023/22-451 ...
    fetch_oyez.py --out TestCorpus/oyez --term 2022 --count 6

Each clip produces:
    <id>.wav            16 kHz mono clip
    <id>.fixture.json   {"source":…, "turns":[{speaker,start,end,text}]}
    <id>.rttm           reference speaker turns (for DER)
    <id>.stm            reference words per turn (for meeteval cpWER/tcpWER)
and the output folder gets a manifest.json listing every clip.
"""

from __future__ import annotations

import argparse
import json
import re
import subprocess
import sys
import time
import urllib.request
from pathlib import Path

API = "https://api.oyez.org"
UA = {"User-Agent": "Consensus-ProvingGround/1.0 (local ASR evaluation)"}


def get_json(url: str) -> object:
    for attempt in range(4):
        try:
            req = urllib.request.Request(url, headers=UA)
            with urllib.request.urlopen(req, timeout=60) as resp:
                return json.load(resp)
        except Exception as exc:  # network hiccups are common; back off
            if attempt == 3:
                raise
            time.sleep(2 + attempt * 3)
            print(f"  retry {url}: {exc}", file=sys.stderr)
    raise RuntimeError("unreachable")


def speaker_key(name: str | None) -> str:
    if not name:
        return "UNKNOWN"
    return re.sub(r"[^A-Z0-9]+", "_", name.upper()).strip("_")


def list_term_cases(term: str) -> list[str]:
    cases = get_json(f"{API}/cases?filter=term:{term}&per_page=0")
    # Oyez docket numbers occasionally carry stray whitespace ("23-191 ").
    return [f"{term}/{c['docket_number'].strip()}" for c in cases if (c.get("docket_number") or "").strip()]


def load_argument(case_ref: str) -> dict | None:
    case = get_json(f"{API}/cases/{case_ref}")
    if isinstance(case, list):
        case = case[0] if case else None
    if not case or not case.get("oral_argument_audio"):
        return None
    media_ref = next((m for m in case["oral_argument_audio"] if not m.get("unavailable")), None)
    if not media_ref:
        return None
    media = get_json(media_ref["href"])
    files = [f for f in (media.get("media_file") or []) if f]
    mp3 = next((f["href"] for f in files if f.get("mime") == "audio/mpeg"), None)
    transcript = media.get("transcript")
    if not mp3 or not transcript:
        return None

    blocks = []
    for section in transcript.get("sections", []):
        for turn in section.get("turns", []):
            spk = speaker_key((turn.get("speaker") or {}).get("name"))
            for b in turn.get("text_blocks", []):
                text = " ".join((b.get("text") or "").split())
                # Oyez occasionally ships a block with stop=0 (usually the
                # last one); a block with no duration can't be scored.
                if text and float(b["stop"]) > float(b["start"]):
                    blocks.append({"speaker": spk, "start": float(b["start"]),
                                   "end": float(b["stop"]), "text": text})
    blocks.sort(key=lambda b: b["start"])
    return {"case": case_ref, "name": case.get("name"), "title": media.get("title"),
            "mp3": mp3, "blocks": blocks}


def choose_window(blocks: list[dict], minutes: float) -> tuple[float, float] | None:
    """Pick the clip window with the most speaker changes, snapped to block edges.

    Opening statements are long monologues; the useful diarization test is
    the questioning, so we score candidate windows by speaker changes and
    distinct speakers and start each window on a block boundary.
    """
    span = minutes * 60
    best, best_score = None, -1.0
    for i, b in enumerate(blocks):
        start = b["start"]
        inside = [x for x in blocks[i:] if x["end"] <= start + span]
        if not inside or inside[-1]["end"] - start < span * 0.9:
            continue
        changes = sum(1 for a, c in zip(inside, inside[1:]) if a["speaker"] != c["speaker"])
        distinct = len({x["speaker"] for x in inside})
        score = changes + 5 * distinct
        if score > best_score:
            best, best_score = (start, inside[-1]["end"]), score
    return best


def write_clip(arg: dict, window: tuple[float, float], out: Path, cache: Path) -> dict:
    clip_id = arg["case"].replace("/", "_") + f"_{int(window[0]):05d}"
    mp3_path = cache / (arg["case"].replace("/", "_") + ".mp3")
    if not mp3_path.exists():
        print(f"  downloading {arg['mp3']}")
        subprocess.run(["curl", "-sSfL", "-o", str(mp3_path), arg["mp3"]], check=True)

    t0, t1 = window
    wav = out / f"{clip_id}.wav"
    subprocess.run(["ffmpeg", "-loglevel", "error", "-y", "-ss", f"{t0:.3f}", "-t", f"{t1 - t0:.3f}",
                    "-i", str(mp3_path), "-ac", "1", "-ar", "16000", str(wav)], check=True)

    turns = [{"speaker": b["speaker"], "start": round(b["start"] - t0, 3),
              "end": round(b["end"] - t0, 3), "text": b["text"]}
             for b in arg["blocks"] if b["start"] >= t0 and b["end"] <= t1]
    speakers = sorted({t["speaker"] for t in turns})
    source = {
        "corpus": "oyez-scotus", "case": arg["case"], "case_name": arg["name"],
        "argument": arg["title"], "audio_url": arg["mp3"],
        "clip_start_s": round(t0, 3), "clip_end_s": round(t1, 3),
        "reference_style": "official-reporter (fillers removed, overlap unmarked)",
        "attribution": "Oyez (oyez.org), CC BY-NC 4.0; audio: Supreme Court of the United States",
    }
    (out / f"{clip_id}.fixture.json").write_text(json.dumps(
        {"source": source, "speakers": speakers, "turns": turns}, indent=1), encoding="utf-8")

    with open(out / f"{clip_id}.rttm", "w", encoding="utf-8") as f:
        for t in turns:
            f.write(f"SPEAKER {clip_id} 1 {t['start']:.3f} {t['end'] - t['start']:.3f} "
                    f"<NA> <NA> {t['speaker']} <NA> <NA>\n")
    with open(out / f"{clip_id}.stm", "w", encoding="utf-8") as f:
        for t in turns:
            f.write(f"{clip_id} 1 {t['speaker']} {t['start']:.3f} {t['end']:.3f} {t['text']}\n")

    words = sum(len(t["text"].split()) for t in turns)
    print(f"  {clip_id}: {(t1 - t0) / 60:.1f} min, {len(speakers)} speakers, {len(turns)} turns, {words} words")
    return {"id": clip_id, "duration_s": round(t1 - t0, 1), "speakers": len(speakers),
            "turns": len(turns), "words": words, "case_name": arg["name"]}


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--out", type=Path, required=True)
    ap.add_argument("--case", action="append", default=[], help="term/docket, e.g. 2022/21-86")
    ap.add_argument("--term", action="append", default=[], help="pull cases from this term")
    ap.add_argument("--count", type=int, default=4, help="cases per --term")
    ap.add_argument("--clip-minutes", type=float, default=10.0)
    args = ap.parse_args()

    out = args.out
    cache = out / "_source"
    out.mkdir(parents=True, exist_ok=True)
    cache.mkdir(exist_ok=True)

    refs = list(args.case)
    for term in args.term:
        refs += list_term_cases(term)[: args.count * 3]  # oversample; some lack audio

    manifest_path = out / "manifest.json"
    manifest = json.loads(manifest_path.read_text()) if manifest_path.exists() else {"clips": []}
    have = {c["id"].rsplit("_", 1)[0] for c in manifest["clips"]}
    per_term: dict[str, int] = {}

    for ref in refs:
        term = ref.split("/")[0]
        if ref not in args.case and per_term.get(term, 0) >= args.count:
            continue
        if ref.replace("/", "_") in have:
            print(f"skip {ref} (already in manifest)")
            continue
        print(f"{ref}")
        try:
            arg = load_argument(ref)
        except Exception as exc:
            print(f"  failed: {exc}", file=sys.stderr)
            continue
        if not arg or len(arg["blocks"]) < 20:
            print("  no usable argument audio/transcript")
            continue
        window = choose_window(arg["blocks"], args.clip_minutes)
        if not window:
            print("  argument shorter than clip length")
            continue
        manifest["clips"].append(write_clip(arg, window, out, cache))
        per_term[term] = per_term.get(term, 0) + 1
        manifest_path.write_text(json.dumps(manifest, indent=1))

    total = sum(c["duration_s"] for c in manifest["clips"]) / 60
    print(f"\n{len(manifest['clips'])} clips, {total:.0f} min total -> {out}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
