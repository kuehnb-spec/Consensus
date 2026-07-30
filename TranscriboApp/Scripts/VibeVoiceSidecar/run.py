"""VibeVoice ASR sidecar for Consensus (dev-mode integration).

Invoked by VibeVoiceTranscriptionService.swift as a subprocess. Reads an audio file,
runs mlx-audio's VibeVoice model, and writes a structured hypothesis JSON the Swift
side can deserialize.

Progress lines are emitted on stderr as JSON for the Swift side to surface in the
process log. Final result is written to the path given as `--out`.

Usage:
    run.py --model <path> --audio <wav-or-m4a> --out <out.json> [--context "..."] [--max-tokens N] [--audio-duration <seconds>]
"""

from __future__ import annotations

import argparse
import json
import os
import sys
import time
from pathlib import Path

# Become our own process-group leader BEFORE any heavy imports. This lets the
# Swift parent kill the whole tree (us + any ffmpeg/librosa subprocess we
# spawn) by sending a single signal to -pgid. Without this, the Python child
# may persist after Consensus quits, holding ~5 GB of MLX weights resident
# and contributing to the macOS thermal-shutdown chain we saw on April 28.
try:
    os.setpgrp()
except OSError:
    # Already a process-group leader (rare); harmless.
    pass

# Suppress tqdm progress bars that mlx-audio emits during encoding/prefill.
# tqdm uses `\r` for in-place updates, which our Swift line-buffered reader
# can't see, so the bars contribute noise to stderr without giving the user
# any feedback. We replace them with our own JSON-line progress events.
os.environ.setdefault("TQDM_DISABLE", "1")


def emit_progress(message: str, fraction: float | None = None, **extra) -> None:
    """Write a progress line as JSON to stderr."""
    payload = {"message": message}
    if fraction is not None:
        payload["fraction"] = fraction
    payload.update(extra)
    print(json.dumps(payload), file=sys.stderr, flush=True)


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--model", required=True, help="Path to MLX-quantized VibeVoice weights")
    parser.add_argument("--audio", required=True, help="Audio file to transcribe (wav, m4a, etc.)")
    parser.add_argument("--out", required=True, help="Output JSON path")
    parser.add_argument("--context", default=None, help="Optional hotword/context string")
    parser.add_argument("--max-tokens", type=int, default=8192)
    parser.add_argument("--temperature", type=float, default=0.0)
    parser.add_argument(
        "--audio-duration",
        type=float,
        default=0.0,
        help="Audio duration in seconds. Used to estimate token count for progress reporting; passed verbatim from Swift.",
    )
    args = parser.parse_args()

    if not os.path.isdir(args.model):
        emit_progress(
            f"Model directory not found: {args.model}",
            stage="error",
        )
        return 2

    if not os.path.isfile(args.audio):
        emit_progress(
            f"Audio file not found: {args.audio}",
            stage="error",
        )
        return 2

    emit_progress("Importing mlx-audio...", stage="import", fraction=0.01)
    try:
        from mlx_audio.stt.utils import load
    except ImportError as e:
        emit_progress(f"mlx-audio import failed: {e}", stage="error")
        return 3

    emit_progress("Loading model weights...", stage="load", fraction=0.02)
    t0 = time.time()
    model = load(args.model)
    load_seconds = time.time() - t0
    emit_progress(
        f"Model loaded in {load_seconds:.1f}s",
        stage="load_done",
        fraction=0.05,
        load_seconds=load_seconds,
    )

    # Estimate expected token count for progress reporting. Empirically VibeVoice
    # emits roughly 8 tokens per second of audio (a 7m36s call produced ~3000
    # tokens, a 27m46s call produced ~5000-12000 depending on speaker density).
    # Cap at max_tokens so the fraction is always monotone non-decreasing.
    if args.audio_duration > 0:
        expected_tokens = min(args.max_tokens, max(200, int(args.audio_duration * 8)))
    else:
        # No duration hint — fall back to half of max_tokens as the assumed
        # endpoint. This still produces a moving bar; it just won't be calibrated.
        expected_tokens = max(200, args.max_tokens // 2)

    # Reserve headroom so we never report >GENERATE_CAP during streaming. The
    # final 8% covers post-streaming work (parse + JSON write) and "we actually
    # finished" — important so the user sees the bar fill properly at the end.
    GENERATE_FLOOR = 0.05
    GENERATE_CAP = 0.92

    emit_progress(
        "Transcribing audio...",
        stage="generate_start",
        fraction=GENERATE_FLOOR,
        expected_tokens=expected_tokens,
    )

    t0 = time.time()
    stream_kwargs = dict(
        audio=args.audio,
        max_tokens=args.max_tokens,
        temperature=args.temperature,
    )
    if args.context:
        stream_kwargs["context"] = args.context

    # Stream tokens so we can emit progress as we go. The model's stream_transcribe
    # yields a decoded text fragment per token; we accumulate the full text and
    # parse the structured segment list at the end via parse_transcription.
    full_text_parts: list[str] = []
    token_count = 0
    last_emit_time = time.time()
    EMIT_INTERVAL_SECONDS = 0.5

    def _recent_human_text(parts: list[str], max_chars: int = 240) -> str:
        """Return the trailing slice of accumulated text with the structured
        JSON wrapper stripped out so the user sees readable transcript text in
        the progress card, not raw `{"Start":12.3,"End":15.6,"Content":"..."}`.
        """
        joined = "".join(parts)
        # The model wraps each turn in JSON like
        #   {"Start":2.78,"End":5.26,"Speaker":0,"Content":"Hello, this is..."}
        # During streaming we only have a partial tail, so a light heuristic:
        # pull the last "Content":"..." span if we can find one, otherwise show
        # the raw tail. Either way, hard cap at `max_chars` from the right.
        tail = joined[-2000:]  # bounded scan window
        # Find the last occurrence of `"Content":"`
        marker = '"Content":"'
        idx = tail.rfind(marker)
        if idx >= 0:
            tail = tail[idx + len(marker):]
            # Stop at the closing quote of this Content if it's complete
            close = tail.find('"}')
            if close >= 0:
                tail = tail[:close]
        # Strip control chars, collapse whitespace
        cleaned = " ".join(tail.replace("\\n", " ").replace("\\\"", '"').split())
        if len(cleaned) > max_chars:
            cleaned = "…" + cleaned[-(max_chars - 1):]
        return cleaned

    try:
        for chunk in model.stream_transcribe(**stream_kwargs):
            full_text_parts.append(chunk)
            token_count += 1

            now = time.time()
            if now - last_emit_time >= EMIT_INTERVAL_SECONDS:
                # Linearly interpolate between GENERATE_FLOOR and GENERATE_CAP
                # based on tokens emitted vs expected.
                progress_within_generate = min(1.0, token_count / expected_tokens)
                fraction = GENERATE_FLOOR + progress_within_generate * (GENERATE_CAP - GENERATE_FLOOR)

                elapsed = now - t0
                tok_per_sec = token_count / max(0.001, elapsed)
                emit_progress(
                    f"Transcribing... ({token_count} tokens, {tok_per_sec:.0f}/s)",
                    stage="generate",
                    fraction=fraction,
                    tokens=token_count,
                    elapsed_seconds=elapsed,
                    tokens_per_second=tok_per_sec,
                    recent_text=_recent_human_text(full_text_parts),
                )
                last_emit_time = now
    except Exception as e:
        emit_progress(f"Streaming generation failed: {e}", stage="error")
        raise

    gen_seconds = time.time() - t0
    full_text = "".join(full_text_parts).strip()
    hit_token_limit = token_count >= args.max_tokens

    emit_progress(
        f"Parsing {token_count} tokens into segments...",
        stage="parse",
        fraction=GENERATE_CAP + 0.01,
        tokens=token_count,
    )

    # Extract structured segments via the model's own JSON parser. This is what
    # generate() does internally; we just call it post-stream.
    segments = model.parse_transcription(full_text)

    emit_progress(
        f"Generated in {gen_seconds:.1f}s ({token_count} tokens, {len(segments)} segments)",
        stage="generate_done",
        fraction=0.97,
        wall_clock_seconds=gen_seconds,
        tokens=token_count,
    )

    payload = {
        "engine": "VibeVoice",
        "model_path": args.model,
        "context": args.context,
        "load_seconds": load_seconds,
        "wall_clock_seconds": gen_seconds,
        "raw_text": full_text,
        "segments": segments,
        "tokens_generated": token_count,
        "max_tokens": args.max_tokens,
        "hit_token_limit": hit_token_limit,
    }

    Path(args.out).write_text(json.dumps(payload, default=str))
    emit_progress("Wrote output JSON", stage="done", fraction=1.0, segments=len(segments))
    return 0


if __name__ == "__main__":
    sys.exit(main())
