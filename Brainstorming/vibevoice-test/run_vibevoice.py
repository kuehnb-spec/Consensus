"""Run VibeVoice ASR (MLX) on an audio file and emit hypothesis JSON for scoring."""

from __future__ import annotations
import json
import sys
import time
from dataclasses import asdict, is_dataclass
from pathlib import Path


def main():
    if len(sys.argv) < 4:
        print("Usage: run_vibevoice.py <model_path_or_repo> <audio.wav> <out.json> [context]")
        sys.exit(1)
    model_path = sys.argv[1]
    audio_path = sys.argv[2]
    out_path = Path(sys.argv[3])
    context = sys.argv[4] if len(sys.argv) > 4 else None

    print(f"[run] model:    {model_path}")
    print(f"[run] audio:    {audio_path}")
    print(f"[run] context:  {context!r}")

    from mlx_audio.stt.utils import load

    print("[run] loading model...", flush=True)
    t0 = time.time()
    model = load(model_path)
    t_load = time.time() - t0
    print(f"[run] loaded in {t_load:.1f}s -- type={type(model).__name__}", flush=True)

    print("[run] generating transcription...", flush=True)
    t0 = time.time()
    kwargs = dict(audio=audio_path, max_tokens=8192, temperature=0.0, verbose=True)
    if context:
        kwargs["context"] = context
    result = model.generate(**kwargs)
    t_gen = time.time() - t0
    print(f"[run] generated in {t_gen:.1f}s ({t_gen / 60:.2f} min)", flush=True)

    out = {
        "wall_clock_seconds": t_gen,
        "model": str(model_path),
        "context": context,
        "load_seconds": t_load,
    }
    if is_dataclass(result):
        out.update(asdict(result))
    elif isinstance(result, dict):
        out.update(result)
    elif isinstance(result, str):
        out["text"] = result
    else:
        for attr in ("text", "segments", "language", "total_time", "generation_tps", "prompt_tps", "total_tokens"):
            v = getattr(result, attr, None)
            if v is not None:
                out[attr] = v

    out_path.write_text(json.dumps(out, indent=2, default=str))
    print(f"[run] wrote {out_path}")
    preview = json.dumps(out, indent=2, default=str)
    print(preview[:3000])
    print(f"\n[run] segments: {len(out.get('segments') or [])}")
    if out.get("segments"):
        for s in out["segments"][:3]:
            print(f"  {s}")


if __name__ == "__main__":
    main()
