#!/usr/bin/env python3
"""
Run NVIDIA Nemotron 3.5 Transcribe (MLX port, mlx-audio >= 0.6.3) over a
Proving Ground corpus, loading the model once.

    run_nemotron35.py --model <mlx checkpoint dir> --corpus TestCorpus/oyez \
        --out TestCorpus/runs [--task asr --task saa] [--limit N]

Writes, per clip and task, into <out>/nemotron35-<task>/:
    <id>.turns.json   {"turns":[{speaker,start,end,text}], "untimed": true, ...}
    <id>.txt          the model's raw output

The port emits no timestamps, so turns carry sequential placeholder times
(turn index, 1 s each) only to keep their order for cpWER; DER from these runs
is meaningless. `asr` output is one turn with speaker "A" (WER only); `saa`
keeps the model's <spk:N> tags as speakers (WER and cpWER).

On a 32 GB Mac the 18 GB model fits only while nothing else holds the GPU, so
it is loaded only while Ollama is idle (see Engine). --window 150
transcribes ~2.5-minute windows cut at quiet points and joins the text. Speaker
IDs restart in every window, so windowed `saa` runs are not fit for cpWER.
"""

from __future__ import annotations

import argparse
import gc
import json
import re
import subprocess
import time
import wave
from pathlib import Path

import mlx.core as mx
from mlx_audio.stt import load
from mlx_audio.stt.utils import load_audio

SPK = re.compile(r"<spk:(\d+)>")
SR = 16000


def to_turns(text: str, task: str) -> list[dict]:
    if task != "saa":
        return [{"speaker": "A", "start": 0.0, "end": 1.0, "text": text.strip()}]
    turns, parts = [], SPK.split(text)
    lead = parts[0].strip()
    if lead:  # text before the first tag
        turns.append({"speaker": "spk?", "text": lead})
    for spk, chunk in zip(parts[1::2], parts[2::2]):
        chunk = chunk.strip()
        if not chunk:
            continue
        if turns and turns[-1]["speaker"] == f"spk{spk}":
            turns[-1]["text"] += " " + chunk
        else:
            turns.append({"speaker": f"spk{spk}", "text": chunk})
    for i, t in enumerate(turns):
        t["start"], t["end"] = float(i), float(i + 1)
    return turns


def cut_points(audio: mx.array, window: float) -> list[tuple[int, int]]:
    """Windows of about `window` seconds, each cut at the quietest 0.25 s frame
    within 20 s of the target boundary, so cuts land between words."""
    frame = SR // 4
    n = audio.size // frame
    energy = mx.sqrt(mx.mean(mx.square(audio[: n * frame].reshape(n, frame)), axis=1)).tolist()
    cuts, pos = [0], 0
    while audio.size - pos > window * SR * 1.25:
        target = (pos + int(window * SR)) // frame
        lo, hi = max(target - 80, pos // frame + 1), min(target + 80, n)
        quiet = min(range(lo, hi), key=lambda i: energy[i])
        pos = quiet * frame + frame // 2
        cuts.append(pos)
    cuts.append(audio.size)
    return list(zip(cuts, cuts[1:]))


def ollama_busy() -> bool:
    try:
        out = subprocess.run(["ollama", "ps"], capture_output=True, text=True, timeout=20).stdout
    except (OSError, subprocess.TimeoutExpired):
        return False
    return len(out.strip().splitlines()) > 1


class Engine:
    """Holds the model only while the GPU is free.

    On the Studio (32 GB, 25 GB Metal working set) the 18 GB model fits only
    when Ollama is empty, and DealCrawler's hourly classifier and the local
    agents load 6-8 GB Ollama models through the night. Rather than starve them,
    the model is loaded only while Ollama is idle and released whenever it is
    not; a Metal out-of-memory mid-clip releases it and retries the clip later.
    """

    def __init__(self, path: str, deadline: float):
        self.path, self.deadline, self.model = path, deadline, None

    def release(self) -> None:
        if self.model is not None:
            self.model = None
            gc.collect()
            mx.clear_cache()

    def wait_for_gpu(self, label: str) -> None:
        waited = 0
        while ollama_busy():
            self.release()
            if time.time() > self.deadline:
                raise TimeoutError("deadline reached while waiting for the GPU")
            if waited % 600 == 0:
                print(f"{label}: Ollama has a model on the GPU, waiting", flush=True)
            time.sleep(30)
            waited += 30
        if self.model is None:
            self.model = load(self.path, strict=True)

    def generate(self, audio, task: str, max_tokens: int, label: str):
        """Raises MemoryError if the audio itself is too long to fit (two
        out-of-memory failures with Ollama idle)."""
        idle_failures = 0
        while True:
            self.wait_for_gpu(label)
            mx.clear_cache()
            try:
                return self.model.generate(audio, task=task, max_tokens=max_tokens)
            except RuntimeError as e:
                if "Insufficient Memory" not in str(e):
                    raise
                busy = ollama_busy()
                print(f"{label}: out of GPU memory (Ollama busy: {busy})", flush=True)
                self.release()
                if not busy:
                    idle_failures += 1
                    if idle_failures == 2:
                        raise MemoryError(label) from e
                time.sleep(120)


def duration(wav: Path) -> float:
    with wave.open(str(wav)) as w:
        return w.getnframes() / w.getframerate()


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--model", required=True)
    ap.add_argument("--corpus", type=Path, required=True)
    ap.add_argument("--out", type=Path, required=True)
    ap.add_argument("--task", action="append", choices=["asr", "saa"])
    ap.add_argument("--max-tokens", type=int, default=8192)
    ap.add_argument("--limit", type=int)
    ap.add_argument("--window", type=float, default=0,
                    help="split audio into ~N-second windows (0 = whole clip); speaker IDs restart per window")
    ap.add_argument("--suffix", default="", help="appended to the run directory name")
    ap.add_argument("--deadline-hours", type=float, default=10, help="give up waiting for the GPU after this long")
    args = ap.parse_args()
    tasks = args.task or ["asr", "saa"]

    manifest = json.loads((args.corpus / "manifest.json").read_text())
    clips = [c["id"] for c in manifest["clips"]][: args.limit]
    engine = Engine(args.model, time.time() + args.deadline_hours * 3600)

    for task in tasks:
        out = args.out / f"nemotron35-{task}{args.suffix}"
        out.mkdir(parents=True, exist_ok=True)
        for clip in clips:
            dest = out / f"{clip}.turns.json"
            if dest.exists():
                continue
            wav = args.corpus / f"{clip}.wav"
            audio = load_audio(str(wav), sr=SR)
            # Whole clip (or --window) first; if the audio itself does not fit,
            # fall back to shorter windows and record them.
            for window in [args.window] + [w for w in (300, 150) if not args.window or w < args.window]:
                windows = cut_points(audio, window) if window else [(0, audio.size)]
                start = time.time()
                texts, tokens = [], 0
                try:
                    for a, b in windows:
                        r = engine.generate(audio[a:b], task, args.max_tokens, f"{task} {clip}")
                        texts.append(r.text.strip())
                        tokens += getattr(r, "generation_tokens", 0) or 0
                    break
                except MemoryError:
                    print(f"{task} {clip}: does not fit at window {window or 'whole'}, splitting", flush=True)
            else:
                raise RuntimeError(f"{task} {clip} does not fit even in 150 s windows")
            secs = time.time() - start
            text = "\n".join(texts)
            (out / f"{clip}.txt").write_text(text, encoding="utf-8")
            dest.write_text(json.dumps({
                "engine": f"nemotron-3.5-transcribe-mlx4bit/{task}",
                "untimed": True,
                "windows": [[round(a / SR, 2), round(b / SR, 2)] for a, b in windows],
                "seconds": round(secs, 1),
                "audio_seconds": round(duration(wav), 1),
                "generation_tokens": tokens,
                "turns": to_turns(text, task),
            }, indent=1), encoding="utf-8")
            print(f"{task} {clip} {secs:.0f}s ({duration(wav) / secs:.1f}x real time)", flush=True)
    engine.release()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
