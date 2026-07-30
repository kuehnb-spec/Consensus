"""Phase A: VibeVoice + Nemotron 3 Nano Omni multimodal review (standard-of-proof).

**Architectural principle**: VibeVoice's transcription is PRESUMED CORRECT.
Nemotron's job is not to reconcile, not to vote, not to compromise — only to
*overturn* a VibeVoice segment when the audio gives clear, specific evidence
that VibeVoice got something materially wrong. This pipeline is asymmetric by
design. When VibeVoice and Nemotron disagree on something trivial (punctuation,
case, fillers, "100%" vs "Hundred percent"), VibeVoice wins automatically.
When they disagree substantively, Nemotron must clear a confidence threshold
*and* provide specific audible evidence before the correction is applied.

This contrasts with the prior Deep Review architecture, which tried to
reconcile two transcripts symmetrically and produced a jumble. Here, VibeVoice
is the floor; Nemotron only raises the ceiling.

Pipeline:
    For each VibeVoice segment:
        1. Extract a small audio clip [start - pad, end + pad] (16kHz mono WAV).
        2. POST to a running llama-server (Nemotron Q4 GGUF + mmproj) with the
           audio clip and a "presume correct" review prompt.
        3. Parse the model's JSON verdict (correct, confidence_wrong, corrected,
           evidence) plus its full reasoning trace.
        4. Apply the correction ONLY if all of:
             - Nemotron says correct=false
             - confidence_wrong >= threshold (default 0.75 — "clear and
               convincing", not the looser 0.65 I floated earlier)
             - The proposed correction differs from the candidate in a
               SUBSTANTIVE way (not just punctuation/case/filler)
             - Nemotron supplied non-empty `evidence`

    The review log captures every decision plus the rejection reason when a
    correction was filtered out, so you can audit calibration after the run.

Usage:
    python run_phase_a.py \\
        --vibevoice-json ../vibevoice-test/vibevoice_with_context.json \\
        --audio ../vibevoice-test/141_W_54th_3.wav \\
        --gguf ./gguf/NVIDIA-Nemotron-3-Nano-Omni-30B-A3B-Reasoning-UD-Q4_K_XL.gguf \\
        --mmproj ./gguf/mmproj-F16.gguf \\
        --out phase_a_corrected.json \\
        --review-log phase_a_review.jsonl \\
        --threshold 0.75

Either run a llama-server alongside (recommended for >5 segments) and pass
`--server-url http://127.0.0.1:8080`, or let this script auto-launch one.
"""

from __future__ import annotations

import argparse
import json
import os
import re
import signal
import socket
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.request
from base64 import b64encode
from pathlib import Path


# ---------------------------------------------------------------------------
# Prompt
# ---------------------------------------------------------------------------

REVIEW_PROMPT = """Listen carefully to the audio. Then transcribe what you actually hear, word for word.

A draft transcription was produced by another system. Compare your transcription to the draft below and report whether they match.

DRAFT: "{candidate}"

Steps:
1. First, write down what you actually hear in the audio (your own transcription).
2. Compare your transcription to the DRAFT.
3. If they say the same thing (allowing for trivial differences like punctuation, capitalization, contractions, filler words, or numeric format), the draft is acceptable.
4. If they say something materially different — a different word, wrong proper name, missing or extra content that changes meaning — the draft has an error.

End your response with EXACTLY one line of JSON on the last line:
{{"heard": "...what you heard...", "matches_draft": true|false, "confidence_wrong": 0.00-1.00, "corrected": "...", "evidence": "..."}}

Fields:
- heard: your own transcription of what was said in the audio.
- matches_draft: true if your transcription says the same thing as the draft (ignoring trivial style differences); false if there's a substantive difference.
- confidence_wrong: when matches_draft=false, your probability (0.0-1.0) that the draft is materially wrong. When matches_draft=true, set to 0.0.
- corrected: when matches_draft=false, the corrected transcription (usually equal to "heard"). Empty string when matches_draft=true.
- evidence: when matches_draft=false, a short sentence stating what specifically differs. Empty string when matches_draft=true.

Be honest about what you actually hear. Do not just agree with the draft — independently transcribe first, then compare.
"""


# ---------------------------------------------------------------------------
# Server lifecycle
# ---------------------------------------------------------------------------


def find_free_port() -> int:
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as s:
        s.bind(("127.0.0.1", 0))
        return s.getsockname()[1]


def wait_for_server(url: str, timeout: float = 600) -> bool:
    deadline = time.time() + timeout
    health_url = url.rstrip("/") + "/health"
    while time.time() < deadline:
        try:
            with urllib.request.urlopen(health_url, timeout=2) as resp:
                if resp.status == 200:
                    return True
        except (urllib.error.URLError, ConnectionError, socket.timeout):
            time.sleep(2)
    return False


def start_server(
    gguf: Path,
    mmproj: Path,
    port: int,
    n_gpu_layers: int = 99,
    ctx_size: int = 8192,
) -> subprocess.Popen:
    args = [
        "/opt/homebrew/bin/llama-server",
        "-m", str(gguf),
        "--mmproj", str(mmproj),
        "--port", str(port),
        "--host", "127.0.0.1",
        "-ngl", str(n_gpu_layers),
        "--ctx-size", str(ctx_size),
        "--no-warmup",
    ]
    print(f"[phase_a] starting llama-server on port {port}: {' '.join(args)}", flush=True)
    return subprocess.Popen(
        args,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
        preexec_fn=os.setpgrp,
    )


# ---------------------------------------------------------------------------
# Audio extraction
# ---------------------------------------------------------------------------


def extract_audio_clip(
    src_audio: Path,
    out_dir: Path,
    start: float,
    end: float,
    pad: float = 0.25,
) -> Path:
    """Extract a 16kHz mono WAV clip [start - pad, end + pad]."""
    clip_start = max(0.0, start - pad)
    clip_dur = max(0.05, (end - start) + 2 * pad)
    out_path = out_dir / f"clip_{int(start * 1000):08d}_{int(end * 1000):08d}.wav"
    subprocess.run(
        [
            "/opt/homebrew/bin/ffmpeg",
            "-y", "-loglevel", "error",
            "-ss", f"{clip_start:.3f}",
            "-i", str(src_audio),
            "-t", f"{clip_dur:.3f}",
            "-ar", "16000", "-ac", "1",
            "-c:a", "pcm_s16le",
            str(out_path),
        ],
        check=True,
    )
    return out_path


# ---------------------------------------------------------------------------
# CLI call (per-segment llama-mtmd-cli — proven path; server mode for
# multimodal audio is still experimental in llama.cpp and Qwen2.5-Omni's
# audio path needs --audio at the CLI to work reliably)
# ---------------------------------------------------------------------------


def call_reviewer_cli(
    gguf: Path,
    mmproj: Path,
    audio_clip: Path,
    candidate_text: str,
    n_gpu_layers: int = 99,
    max_tokens: int = 512,
    timeout: float = 240.0,
    use_jinja: bool = False,
) -> tuple[str, float]:
    """Invoke `llama-mtmd-cli` per segment. Returns (model_response_text, wall_seconds).

    Slower than a resident llama-server because each call reloads the model,
    but for 50-segment Phase A on a 2-7 GB Q4 GGUF the reload is ~1-3 s and
    per-segment inference is ~2-5 s, so total cost is well under 10 minutes.

    `use_jinja=True` enables the model's bundled chat template — required for
    Qwen2.5-Omni (which otherwise outputs only "[Music]") but not for Voxtral.
    """
    prompt = REVIEW_PROMPT.format(
        candidate=candidate_text.replace('"', '\\"')
    )
    args = [
        "/opt/homebrew/bin/llama-mtmd-cli",
        "-m", str(gguf),
        "--mmproj", str(mmproj),
        "--audio", str(audio_clip),
        "-p", prompt,
        "-n", str(max_tokens),
        "--temp", "0.0",
        "-ngl", str(n_gpu_layers),
    ]
    if use_jinja:
        args.append("--jinja")
    t0 = time.time()
    try:
        proc = subprocess.run(
            args,
            capture_output=True,
            check=False,
            timeout=timeout,
        )
    except subprocess.TimeoutExpired:
        return "<timeout>", time.time() - t0
    elapsed = time.time() - t0
    # llama-mtmd-cli sometimes writes non-UTF-8 bytes to stderr (e.g. terminal
    # progress glyphs); decode permissively so we don't crash mid-run.
    stdout_text = proc.stdout.decode("utf-8", errors="replace") if proc.stdout else ""
    stderr_text = proc.stderr.decode("utf-8", errors="replace") if proc.stderr else ""
    if proc.returncode != 0:
        return f"<error code={proc.returncode}: {stderr_text[-500:]}>", elapsed
    return stdout_text.strip(), elapsed


# ---------------------------------------------------------------------------
# Response parsing
# ---------------------------------------------------------------------------


def parse_review(raw: str) -> dict:
    """Pull the LAST {...} JSON object out of Nemotron's response.

    Nemotron is a reasoning model, so the response may include `<think>...</think>`
    or chain-of-thought before the JSON. We take the last JSON object on the
    assumption that it's the verdict, falling back to a 'keep candidate' verdict
    if parsing fails (consistent with the standard-of-proof default).
    """
    if not raw or raw.startswith("<"):
        return _keep_default(reason=f"empty or error response: {raw[:120]}", raw=raw)

    # Strip <think>...</think> tags if present
    reasoning = ""
    think_match = re.search(r"<think>(.*?)</think>", raw, re.DOTALL)
    if think_match:
        reasoning = think_match.group(1).strip()
        raw = re.sub(r"<think>.*?</think>", "", raw, flags=re.DOTALL).strip()

    # Find ALL {...} JSON objects, take the last one
    json_matches = list(re.finditer(r"\{[^{}]*\}", raw, re.DOTALL))
    if not json_matches:
        return _keep_default(reason="no JSON in response", raw=raw, reasoning=reasoning)

    last = json_matches[-1].group(0)
    try:
        parsed = json.loads(last)
    except json.JSONDecodeError as e:
        return _keep_default(reason=f"JSON decode error: {e}", raw=raw, reasoning=reasoning)

    # Coerce + validate. Accept either old "correct" or new "matches_draft" field.
    if "matches_draft" in parsed:
        correct = bool(parsed.get("matches_draft", True))
    else:
        correct = bool(parsed.get("correct", True))
    confidence = float(parsed.get("confidence_wrong", 0.0))
    corrected = str(parsed.get("corrected", "")).strip()
    evidence = str(parsed.get("evidence", "")).strip()
    heard = str(parsed.get("heard", "")).strip()

    if correct:
        return {
            "correct": True,
            "confidence_wrong": 0.0,
            "corrected": "",
            "evidence": evidence,
            "heard": heard,
            "reasoning": reasoning,
            "raw": raw[:500],
        }
    else:
        return {
            "correct": False,
            "confidence_wrong": max(0.0, min(1.0, confidence)),
            "corrected": corrected,
            "evidence": evidence,
            "heard": heard,
            "reasoning": reasoning,
            "raw": raw[:500],
        }


def _keep_default(*, reason: str, raw: str = "", reasoning: str = "") -> dict:
    return {
        "correct": True,
        "confidence_wrong": 0.0,
        "corrected": "",
        "evidence": "",
        "heard": "",
        "reasoning": reasoning,
        "raw": raw[:500],
        "_parse_error": reason,
    }


# ---------------------------------------------------------------------------
# Trivial-diff filter (the heart of the standard-of-proof principle)
# ---------------------------------------------------------------------------


# Filler tokens that get stripped before comparison. Adding/removing these is
# never substantive — VibeVoice's choice wins. Kept narrow on purpose; common
# words like "well", "so", "right", "you", "know" carry meaning often enough
# that stripping them risks masking real diffs.
_FILLER_TOKENS = {
    "uh", "um", "uhh", "umm", "er", "ah", "mm", "hmm", "mhm", "mmhmm",
}

_FILLER_PHRASES = [
    "you know", "i mean", "kind of", "sort of",
]

# Irregular contractions handled before the generic "n't" rule so "won't"
# expands to "will not" rather than "wo not".
_IRREGULAR_CONTRACTIONS = [
    (r"\bwon't\b", "will not"),
    (r"\bcan't\b", "cannot"),
    (r"\bshan't\b", "shall not"),
    (r"\bain't\b", "is not"),
    (r"\bgonna\b", "going to"),
    (r"\bwanna\b", "want to"),
    (r"\bgotta\b", "got to"),
]


def normalize_for_comparison(text: str) -> str:
    """Aggressive normalization for trivial-diff detection.

    Lowercases, strips punctuation, removes filler words, normalizes contractions
    and number/percent formats. If two strings are equal under this normalization,
    the diff is trivial and the correction MUST be rejected regardless of
    Nemotron's confidence.
    """
    s = text.lower()
    # Strip filler phrases (apply BEFORE punctuation strip so "you know," matches)
    for phrase in _FILLER_PHRASES:
        s = re.sub(rf"\b{re.escape(phrase)}\b", " ", s)
    # Irregular contractions FIRST (longest match wins)
    for pattern, repl in _IRREGULAR_CONTRACTIONS:
        s = re.sub(pattern, repl, s)
    # Generic contraction expansions
    s = s.replace("n't", " not")
    s = s.replace("'ll", " will")
    s = s.replace("'re", " are")
    s = s.replace("'ve", " have")
    s = s.replace("'m", " am")
    s = s.replace("'d", " would")
    s = s.replace("'s", " is")
    # Treat bare "its" / "thats" / "wheres" etc. the same as the apostrophe form
    # by stripping any remaining apostrophes (already-expanded forms got space-
    # padded above, so this only catches stragglers).
    s = s.replace("'", "")
    # Percent → "percent" so "100%" matches "100 percent"
    s = s.replace("%", " percent ")
    # Strip remaining punctuation
    s = re.sub(r"[^\w\s]", " ", s)
    # Number-word ↔ digit normalization. Apply BOTH directions so "two" matches
    # "2" and vice versa.
    number_words = {
        "zero": "0", "one": "1", "two": "2", "three": "3", "four": "4",
        "five": "5", "six": "6", "seven": "7", "eight": "8", "nine": "9",
        "ten": "10", "eleven": "11", "twelve": "12", "thirteen": "13",
        "fourteen": "14", "fifteen": "15", "sixteen": "16", "seventeen": "17",
        "eighteen": "18", "nineteen": "19", "twenty": "20", "thirty": "30",
        "forty": "40", "fifty": "50", "sixty": "60", "seventy": "70",
        "eighty": "80", "ninety": "90",
        "hundred": "100", "thousand": "1000", "million": "1000000",
    }
    tokens = s.split()
    tokens = [number_words.get(t, t) for t in tokens]
    # "its" vs "it is" — collapse the bare form to match the expanded form too.
    # After contractions ran, "it's" became "it is"; "its" stays "its". Map both
    # to a canonical form.
    pronoun_collapse = {"its": "it is", "thats": "that is", "theres": "there is", "wheres": "where is"}
    out: list[str] = []
    for t in tokens:
        if t in pronoun_collapse:
            out.extend(pronoun_collapse[t].split())
        else:
            out.append(t)
    tokens = out
    # Strip remaining filler tokens (narrow set — see comment on _FILLER_TOKENS)
    tokens = [t for t in tokens if t and t not in _FILLER_TOKENS]
    return " ".join(tokens)


def is_trivial_diff(candidate: str, corrected: str) -> bool:
    """Return True when the diff is just punctuation / case / fillers / format.

    The correction is REJECTED when this returns True. This implements the
    asymmetric standard-of-proof rule: VibeVoice wins on trivial differences
    no matter what Nemotron says.
    """
    return normalize_for_comparison(candidate) == normalize_for_comparison(corrected)


# ---------------------------------------------------------------------------
# Decision
# ---------------------------------------------------------------------------


def decide(
    candidate: str,
    parsed: dict,
    threshold: float,
) -> tuple[bool, str]:
    """Return (apply_correction, rejection_reason). When apply_correction is
    False, rejection_reason is filled with the principled reason (so we can
    audit the run later)."""
    if parsed.get("correct", True):
        return False, "nemotron_says_correct"

    confidence = float(parsed.get("confidence_wrong", 0.0))
    if confidence < threshold:
        return False, f"confidence_below_threshold ({confidence:.2f} < {threshold:.2f})"

    corrected = (parsed.get("corrected") or "").strip()
    if not corrected:
        return False, "empty_corrected_string"

    evidence = (parsed.get("evidence") or "").strip()
    if not evidence:
        return False, "missing_evidence"

    if len(evidence) < 12:
        return False, f"evidence_too_short ({evidence!r})"

    if is_trivial_diff(candidate, corrected):
        return False, "trivial_diff (punctuation/case/filler/format only)"

    return True, ""


# ---------------------------------------------------------------------------
# IO helpers
# ---------------------------------------------------------------------------


def normalize_vibevoice(raw: dict) -> list[dict]:
    """Convert VibeVoice's `{segments: [...]}` payload to a flat list of segments."""
    segments = raw.get("segments") or []
    out = []
    for seg in segments:
        text = (seg.get("text") or "").strip()
        if not text:
            continue
        out.append({
            "speaker_id": seg.get("speaker_id"),
            "start": float(seg.get("start") or 0),
            "end": float(seg.get("end") or 0),
            "text": text,
        })
    return out


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--vibevoice-json", type=Path, required=True)
    parser.add_argument("--audio", type=Path, required=True)
    parser.add_argument("--gguf", type=Path, required=True)
    parser.add_argument("--mmproj", type=Path, required=True)
    parser.add_argument("--out", type=Path, required=True)
    parser.add_argument("--review-log", type=Path, required=True)
    parser.add_argument(
        "--threshold",
        type=float,
        default=0.75,
        help="Minimum Nemotron confidence_wrong required to apply a correction. "
             "0.75 ≈ \"clear and convincing.\" Lower values are more permissive.",
    )
    parser.add_argument("--limit", type=int, default=0,
                        help="Only review the first N segments (smoke testing). 0 = all.")
    parser.add_argument("--min-words", type=int, default=2,
                        help="Skip segments shorter than this word count.")
    parser.add_argument("--use-jinja", action="store_true",
                        help="Pass --jinja to llama-mtmd-cli (required for Qwen2.5-Omni).")
    args = parser.parse_args()

    for required_path in (args.vibevoice_json, args.audio, args.gguf, args.mmproj):
        if not required_path.exists():
            print(f"[phase_a] missing required file: {required_path}", file=sys.stderr)
            return 2

    raw = json.loads(args.vibevoice_json.read_text())
    segments = normalize_vibevoice(raw)
    if args.limit > 0:
        segments = segments[: args.limit]

    print(
        f"[phase_a] reviewing {len(segments)} segments at threshold={args.threshold:.2f} "
        f"(VibeVoice presumed correct)",
        flush=True,
    )

    work_dir = Path(tempfile.mkdtemp(prefix="phase_a_clips_"))
    review_log_fh = args.review_log.open("w")

    corrected_segments: list[dict] = []
    flips = 0
    rejections_by_reason: dict[str, int] = {}
    parse_errors = 0
    total_review_seconds = 0.0
    pipeline_start = time.time()

    try:
        for idx, seg in enumerate(segments):
            word_count = len(seg["text"].split())
            if word_count < args.min_words:
                corrected_segments.append(seg)
                continue

            try:
                clip = extract_audio_clip(args.audio, work_dir, seg["start"], seg["end"])
            except subprocess.CalledProcessError as e:
                print(f"[phase_a] ffmpeg failed at segment {idx}: {e}", file=sys.stderr)
                corrected_segments.append(seg)
                continue

            raw_resp, review_seconds = call_reviewer_cli(
                gguf=args.gguf,
                mmproj=args.mmproj,
                audio_clip=clip,
                candidate_text=seg["text"],
                use_jinja=args.use_jinja,
            )
            parsed = parse_review(raw_resp)
            total_review_seconds += review_seconds
            if "_parse_error" in parsed:
                parse_errors += 1

            apply_correction, rejection_reason = decide(
                candidate=seg["text"],
                parsed=parsed,
                threshold=args.threshold,
            )

            final_text = parsed["corrected"] if apply_correction else seg["text"]
            if apply_correction:
                flips += 1
            else:
                rejections_by_reason[rejection_reason] = rejections_by_reason.get(rejection_reason, 0) + 1

            record = {
                "segment_index": idx,
                "start": seg["start"],
                "end": seg["end"],
                "speaker_id": seg.get("speaker_id"),
                "candidate": seg["text"],
                "nemotron_correct": parsed.get("correct"),
                "confidence_wrong": parsed.get("confidence_wrong"),
                "nemotron_corrected": parsed.get("corrected"),
                "nemotron_heard": parsed.get("heard"),
                "evidence": parsed.get("evidence"),
                "reasoning": parsed.get("reasoning"),
                "raw_response": parsed.get("raw"),
                "applied_correction": apply_correction,
                "rejection_reason": rejection_reason if not apply_correction else "",
                "final": final_text,
                "review_seconds": review_seconds,
                "parse_error": parsed.get("_parse_error"),
            }
            review_log_fh.write(json.dumps(record) + "\n")
            review_log_fh.flush()

            try:
                clip.unlink()
            except FileNotFoundError:
                pass

            elapsed = time.time() - pipeline_start
            eta = (elapsed / (idx + 1)) * (len(segments) - idx - 1)
            marker = "[FLIP]" if apply_correction else f"[keep:{rejection_reason[:14]}]"
            print(
                f"[phase_a] {idx+1}/{len(segments)} {marker} "
                f"conf_wrong={parsed.get('confidence_wrong', 0.0):.2f} "
                f"({review_seconds:.1f}s / total {elapsed:.0f}s, eta {eta:.0f}s)",
                flush=True,
            )

            corrected_segments.append({
                "speaker_id": seg.get("speaker_id"),
                "start": seg["start"],
                "end": seg["end"],
                "text": final_text,
            })
    finally:
        review_log_fh.close()

    out_payload = {
        "engine": "VibeVoice + Nemotron 3 Nano Omni review (standard-of-proof)",
        "principle": "VibeVoice presumed correct; Nemotron only overturns with confidence>=threshold AND non-trivial diff AND evidence",
        "context": raw.get("context"),
        "vibevoice_segments": len(raw.get("segments") or []),
        "reviewed_segments": len(segments),
        "applied_corrections": flips,
        "rejections_by_reason": rejections_by_reason,
        "parse_errors": parse_errors,
        "threshold": args.threshold,
        "review_seconds_total": total_review_seconds,
        "wall_clock_seconds_total": time.time() - pipeline_start,
        "segments": corrected_segments,
    }
    args.out.write_text(json.dumps(out_payload, indent=2))
    print(
        f"\n[phase_a] done.\n"
        f"  applied corrections: {flips}/{len(segments)}\n"
        f"  rejections: {rejections_by_reason}\n"
        f"  parse errors: {parse_errors}\n"
        f"  total review time: {total_review_seconds:.0f}s\n"
        f"  wall clock: {time.time() - pipeline_start:.0f}s",
        flush=True,
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
