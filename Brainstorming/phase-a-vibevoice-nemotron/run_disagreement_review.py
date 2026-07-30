"""Phase A v3: disagreement-driven Qwen Q8 review.

Pipeline:
    VibeVoice transcript (presumed correct)
        + Parakeet transcript (independent second ASR)
        -> find_disagreements.py
        -> per-span audio clip with ±5s padding
        -> Qwen Q8 (--jinja) reviews each span with both candidates + full
           transcript context + audio
        -> standard-of-proof gate (matches VibeVoice's text by default;
           overturns only when Qwen commits with high confidence AND a
           non-trivial diff AND specific evidence)
        -> emits a corrected transcript + audit log

Compared to Phase A v2: the model only sees the spans where two ASR systems
disagree, with much wider audio context (±5s) and the full conversation
transcript. The differ is treated as a HINT to focus Qwen's attention, not
as authoritative — Qwen can also decide both candidates are wrong and
propose its own transcription, or decide there is no substantive error and
keep VibeVoice's text.
"""

from __future__ import annotations

import argparse
import json
import os
import re
import subprocess
import sys
import tempfile
import time
from base64 import b64encode
from pathlib import Path

# Reuse the standard-of-proof primitives from the v2 sidecar.
sys.path.insert(0, str(Path(__file__).parent))
from run_phase_a import (
    parse_review,
    is_trivial_diff,
    decide,
)


# ---------------------------------------------------------------------------
# Prompt — focused on adjudicating between two candidates with audio +
# transcript context.
# ---------------------------------------------------------------------------

REVIEW_PROMPT_TEMPLATE = """Listen carefully to the audio and transcribe exactly what is said, word for word. Do NOT include any commentary, just the transcription itself.

The audio clip extends ±5 seconds around a specific span we want transcribed. Your job is to transcribe the FULL audio clip.

A target sub-region of approximately {dispute_window_seconds:.1f} seconds is what we are particularly interested in. Try to mark which words fall within that target sub-region by surrounding them with `<<` and `>>`. For example: "Hello there. <<This is the disputed span.>> What comes next."

If you cannot mark the boundaries precisely, just transcribe the full clip. We will figure out the alignment.

Begin your transcription on the next line. End with EXACTLY one line of JSON:

(your transcription here, with `<<` and `>>` marking the disputed span if you can)

{{"heard_disputed_span": "...just the words inside <<>>...", "heard_full_clip": "...the whole transcription you wrote above..."}}

Decision standards (these don't apply to your task — just transcribe — but listed for context):

1. TRIVIAL differences are NOT substantive. Examples: punctuation, capitalization, contractions, filler words, numeric format ("100%" vs "Hundred percent"), word-order variations that preserve meaning, present vs past tense if the meaning is unchanged. If the only difference is trivial, choose verdict="keep_a".

2. SUBSTANTIVE differences require ALL of:
   - You can clearly hear what was actually said
   - The actual speech materially differs from one or both candidates (different word, wrong proper name, missing/added phrase that changes meaning)
   - You can state both what's wrong AND what you heard instead

3. When in doubt, defer to CANDIDATE A (VibeVoice). It's treated as the default truth and should only be overturned with strong evidence.

4. Use surrounding context. If the conversation is about legal mediation, "mediation" is more plausible than "meditation"; if about state-by-state legal counsel, "Virginia" is more plausible than "Florida".

Just transcribe what you hear. Mark the disputed sub-region with `<<` and `>>` if you can.
"""


# ---------------------------------------------------------------------------
# Audio extraction — wider context (±5s) around the disputed span.
# ---------------------------------------------------------------------------


def extract_audio_clip(
    src_audio: Path,
    out_dir: Path,
    start: float,
    end: float,
    pad_seconds: float = 5.0,
) -> Path:
    clip_start = max(0.0, start - pad_seconds)
    clip_dur = max(0.5, (end - start) + 2 * pad_seconds)
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
# Context window from the surrounding VibeVoice transcript.
# ---------------------------------------------------------------------------


def build_context_window(
    vibevoice_segments: list[dict],
    span_start: float,
    span_end: float,
    pad_seconds: float = 30.0,
    max_chars: int = 1800,
) -> str:
    """Return the local conversation transcript spanning ±30s around the
    disagreement, with the disputed turn highlighted. Truncated to keep the
    prompt size manageable."""
    window_start = span_start - pad_seconds
    window_end = span_end + pad_seconds
    lines: list[str] = []
    for seg in vibevoice_segments:
        s = float(seg.get("start") or 0)
        e = float(seg.get("end") or 0)
        if e < window_start or s > window_end:
            continue
        text = (seg.get("text") or "").strip()
        if not text:
            continue
        speaker = seg.get("speaker_id") or seg.get("speaker") or "?"
        marker = " <<< DISPUTED >>>" if (s >= span_start - 0.1 and e <= span_end + 0.1) else ""
        lines.append(f"  [{s:6.1f}s] {speaker}: {text}{marker}")
    joined = "\n".join(lines)
    if len(joined) > max_chars:
        joined = joined[: max_chars - 3] + "..."
    return joined or "(no surrounding context available)"


# ---------------------------------------------------------------------------
# CLI invocation (mirrors v2; --use-jinja is forced for Qwen).
# ---------------------------------------------------------------------------


def call_reviewer_cli(
    gguf: Path,
    mmproj: Path,
    audio_clip: Path,
    prompt: str,
    n_gpu_layers: int = 99,
    max_tokens: int = 768,
    timeout: float = 300.0,
    use_jinja: bool = True,
) -> tuple[str, float]:
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
        proc = subprocess.run(args, capture_output=True, check=False, timeout=timeout)
    except subprocess.TimeoutExpired:
        return "<timeout>", time.time() - t0
    elapsed = time.time() - t0
    stdout_text = proc.stdout.decode("utf-8", errors="replace") if proc.stdout else ""
    stderr_text = proc.stderr.decode("utf-8", errors="replace") if proc.stderr else ""
    if proc.returncode != 0:
        return f"<error code={proc.returncode}: {stderr_text[-500:]}>", elapsed
    return stdout_text.strip(), elapsed


# ---------------------------------------------------------------------------
# Decision-layer adapter for the new verdict schema.
# ---------------------------------------------------------------------------


def decide_verdict(parsed: dict, a_text: str, threshold: float) -> tuple[bool, str, str]:
    """Return (apply_correction, rejection_reason, final_text).

    Adapts the v2 standard-of-proof gate to the new {"verdict": "keep_a"|...}
    schema. Keeps the rule that VibeVoice (a_text) is the default unless
    Qwen clears all the gates: high confidence, non-empty corrected, non-empty
    evidence, and a non-trivial diff.
    """
    verdict = (parsed.get("verdict") or "").strip().lower()
    # Accept either "keep_a" or "matches_draft=true" idioms; the latter is
    # what the v2 soft prompt produces when reused here.
    if verdict in ("keep_a", "match", "matches_draft", "") and not parsed.get("corrected", "").strip():
        return False, "qwen_says_keep_a", a_text
    if verdict == "keep_a":
        return False, "qwen_says_keep_a", a_text

    confidence = float(parsed.get("confidence_wrong") or 0)
    corrected = (parsed.get("corrected") or "").strip()
    evidence = (parsed.get("evidence") or "").strip()

    if confidence < threshold:
        return False, f"confidence_below_threshold ({confidence:.2f} < {threshold:.2f})", a_text
    if not corrected:
        return False, "empty_corrected", a_text
    if not evidence or len(evidence) < 12:
        return False, f"evidence_missing_or_too_short ({evidence!r})", a_text
    if is_trivial_diff(a_text, corrected):
        return False, "trivial_diff (punctuation/case/filler/format only)", a_text

    # Length-ratio sanity check. A genuine word-level correction has a
    # similar word count to the candidate. A wildly-larger corrected text
    # almost always means the differ flagged a segmentation-level
    # disagreement (one ASR merged what the other split) and Qwen pulled
    # in surrounding content. Accepting it would duplicate that content
    # downstream when the corrected text is overlaid on the candidate's
    # single segment.
    a_words = len(a_text.split())
    c_words = len(corrected.split())
    if a_words > 0:
        ratio = c_words / a_words
        if ratio > 2.5 or ratio < 0.4:
            return False, f"length_mismatch (a={a_words}w vs corrected={c_words}w; ratio {ratio:.2f})", a_text

    return True, "", corrected


def parse_disagreement_review(raw: str) -> dict:
    """Extract Qwen's fresh transcription. Looks for either:
    - JSON object with heard_disputed_span / heard_full_clip
    - <<...>> markers in plain text
    - As fallback, the whole stripped text.

    Returns a dict with: heard_disputed_span (str), heard_full_clip (str),
    raw (truncated), _parse_error if any.
    """
    if not raw or raw.startswith("<error") or raw.startswith("<timeout"):
        return {
            "heard_disputed_span": "",
            "heard_full_clip": "",
            "raw": raw[:600],
            "_parse_error": f"empty or error: {raw[:100]}",
        }

    # Strip any <think> blocks (some Qwen variants emit them)
    text = re.sub(r"<think>.*?</think>", "", raw, flags=re.DOTALL).strip()

    # Try the JSON pattern first
    json_matches = list(re.finditer(r"\{[^{}]*\}", text, re.DOTALL))
    parsed_json: dict = {}
    if json_matches:
        try:
            parsed_json = json.loads(json_matches[-1].group(0))
        except json.JSONDecodeError:
            parsed_json = {}

    heard_disputed = str(parsed_json.get("heard_disputed_span") or "").strip()
    heard_full = str(parsed_json.get("heard_full_clip") or "").strip()

    # Extract <<...>> from the plain text body if JSON didn't have the span
    if not heard_disputed:
        marker_match = re.search(r"<<\s*(.*?)\s*>>", text, re.DOTALL)
        if marker_match:
            heard_disputed = marker_match.group(1).strip()

    # If we still don't have full-clip transcription, take the body before the JSON
    if not heard_full:
        body = text
        if json_matches:
            body = text[: json_matches[-1].start()].strip()
        # Strip <<>> markers to get clean text
        heard_full = re.sub(r"<<\s*|\s*>>", "", body).strip()

    if not heard_disputed and heard_full:
        # Fallback: use the full clip as the disputed-span guess
        heard_disputed = heard_full

    return {
        "heard_disputed_span": heard_disputed,
        "heard_full_clip": heard_full,
        "raw": raw[:600],
        "_parse_error": None if heard_disputed else "could not extract heard text",
    }


def decide_from_fresh_transcription(
    qwen_heard_span: str,
    a_text: str,
) -> tuple[bool, str, str, float]:
    """Compare Qwen's fresh audio transcription to VibeVoice's candidate.

    Returns (apply_correction, rejection_reason, final_text, implied_confidence).

    Rules (the standard-of-proof gate, but mechanical):
      1. If we couldn't parse Qwen's transcription → keep VibeVoice.
      2. If the diff is trivial (punctuation/case/filler/format) → keep VibeVoice.
      3. If Qwen's transcription is wildly different in length (more than 2.5x
         or less than 0.4x) → likely transcribed too much/little context;
         reject as a span-boundary alignment artifact.
      4. Otherwise → Qwen has substantively transcribed something different
         from VibeVoice. Apply the correction with implied confidence based
         on word-level overlap.
    """
    qwen_text = (qwen_heard_span or "").strip()
    if not qwen_text:
        return False, "qwen_empty_transcription", a_text, 0.0

    if is_trivial_diff(a_text, qwen_text):
        return False, "trivial_diff", a_text, 0.0

    a_words = len(a_text.split())
    q_words = len(qwen_text.split())
    if a_words > 0:
        ratio = q_words / a_words
        if ratio > 2.5 or ratio < 0.4:
            return False, f"length_mismatch (a={a_words}w vs qwen={q_words}w; ratio {ratio:.2f})", a_text, 0.0

    # Implied confidence: how different are the normalized strings?
    a_norm = set(re.findall(r"\w+", a_text.lower()))
    q_norm = set(re.findall(r"\w+", qwen_text.lower()))
    if not a_norm or not q_norm:
        return False, "empty_normalized", a_text, 0.0
    overlap = len(a_norm & q_norm) / max(1, len(a_norm | q_norm))
    # confidence_wrong = 1 - overlap; high overlap = low confidence in being wrong
    implied_confidence = 1.0 - overlap

    if implied_confidence < 0.25:
        # Strings are very similar after normalization — probably just punctuation
        # or minor word reordering. Don't risk a regression.
        return False, f"confidence_too_low ({implied_confidence:.2f})", a_text, implied_confidence

    return True, "", qwen_text, implied_confidence


# ---------------------------------------------------------------------------
# Apply Qwen's accepted corrections back onto the VibeVoice transcript.
# ---------------------------------------------------------------------------


def apply_corrections(
    vibevoice: dict,
    accepted: list[dict],
) -> dict:
    """Build a new transcript JSON identical to vibevoice but with text
    rewritten on the segments where Qwen's correction was applied. Preserves
    timestamps and speaker IDs."""
    by_idx_map: dict[int, str] = {}
    for record in accepted:
        for ai in record["a_segment_indices"]:
            by_idx_map[ai] = record["final_text"]

    out_segments = []
    for i, seg in enumerate(vibevoice.get("segments") or []):
        new_seg = dict(seg)
        if i in by_idx_map:
            new_seg["original_text"] = seg.get("text")
            new_seg["text"] = by_idx_map[i]
            new_seg["corrected_by"] = "qwen-omni-q8"
        out_segments.append(new_seg)

    out = dict(vibevoice)
    out["segments"] = out_segments
    out["disagreement_review"] = {
        "applied_corrections": len([r for r in accepted if r["applied"]]),
        "reviewed_disagreements": len(accepted),
    }
    return out


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--vibevoice-json", type=Path, required=True)
    parser.add_argument("--disagreements", type=Path, required=True)
    parser.add_argument("--audio", type=Path, required=True)
    parser.add_argument("--gguf", type=Path, required=True)
    parser.add_argument("--mmproj", type=Path, required=True)
    parser.add_argument("--out", type=Path, required=True)
    parser.add_argument("--review-log", type=Path, required=True)
    parser.add_argument("--threshold", type=float, default=0.75)
    parser.add_argument("--limit", type=int, default=0)
    parser.add_argument("--use-jinja", action="store_true", default=True)
    args = parser.parse_args()

    vibevoice = json.loads(args.vibevoice_json.read_text())
    disagreements = json.loads(args.disagreements.read_text())
    spans = disagreements["disagreements"]
    if args.limit > 0:
        spans = spans[: args.limit]

    print(f"[v3] reviewing {len(spans)} disagreement spans at threshold={args.threshold:.2f}")

    work_dir = Path(tempfile.mkdtemp(prefix="phase_a_v3_"))
    review_log_fh = args.review_log.open("w")

    accepted_records = []
    flips = 0
    rejections: dict[str, int] = {}
    pipeline_start = time.time()
    total_review_seconds = 0.0

    try:
        for idx, span in enumerate(spans):
            try:
                clip = extract_audio_clip(
                    args.audio, work_dir,
                    span["start"], span["end"],
                    pad_seconds=5.0,
                )
            except subprocess.CalledProcessError as e:
                print(f"[v3] ffmpeg failed at span {idx}: {e}", file=sys.stderr)
                continue

            prompt = REVIEW_PROMPT_TEMPLATE.format(
                dispute_window_seconds=span["end"] - span["start"],
            )

            raw, review_seconds = call_reviewer_cli(
                gguf=args.gguf,
                mmproj=args.mmproj,
                audio_clip=clip,
                prompt=prompt,
                use_jinja=args.use_jinja,
            )
            parsed = parse_disagreement_review(raw)
            total_review_seconds += review_seconds

            apply, reason, final_text, implied_conf = decide_from_fresh_transcription(
                parsed.get("heard_disputed_span", ""),
                span["a_text"],
            )
            if apply:
                flips += 1
            else:
                rejections[reason] = rejections.get(reason, 0) + 1

            record = {
                "span_index": idx,
                "start": span["start"],
                "end": span["end"],
                "speaker": span.get("speaker"),
                "a_text": span["a_text"],
                "b_text": span["b_text"],
                "diff_summary": span.get("diff_summary"),
                "qwen_heard_disputed_span": parsed.get("heard_disputed_span"),
                "qwen_heard_full_clip": parsed.get("heard_full_clip"),
                "qwen_raw": parsed.get("raw"),
                "implied_confidence_wrong": implied_conf,
                "applied": apply,
                "rejection_reason": reason if not apply else "",
                "final_text": final_text,
                "a_segment_indices": span.get("a_segment_indices", []),
                "b_segment_indices": span.get("b_segment_indices", []),
                "review_seconds": review_seconds,
                "parse_error": parsed.get("_parse_error"),
            }
            accepted_records.append(record)
            review_log_fh.write(json.dumps(record) + "\n")
            review_log_fh.flush()

            try:
                clip.unlink()
            except FileNotFoundError:
                pass

            elapsed = time.time() - pipeline_start
            eta = elapsed / (idx + 1) * (len(spans) - idx - 1)
            marker = "[FLIP]" if apply else f"[keep:{reason[:24]}]"
            print(
                f"[v3] {idx+1}/{len(spans)} {marker} "
                f"impl_conf={implied_conf:.2f} "
                f"({review_seconds:.1f}s; total {elapsed:.0f}s; eta {eta:.0f}s)",
                flush=True,
            )
    finally:
        review_log_fh.close()

    # Build the corrected transcript by overlaying accepted corrections onto
    # VibeVoice's segment list.
    corrected_payload = apply_corrections(vibevoice, accepted_records)
    args.out.write_text(json.dumps(corrected_payload, indent=2))

    print(
        f"\n[v3] done.\n"
        f"  spans reviewed:        {len(spans)}\n"
        f"  applied corrections:   {flips}\n"
        f"  rejection breakdown:   {rejections}\n"
        f"  total review time:     {total_review_seconds:.0f}s\n"
        f"  wall clock:            {time.time() - pipeline_start:.0f}s",
        flush=True,
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
