"""Phase A v4: multi-candidate judge architecture.

Architecture:
  TWO EARS feed the JUDGE:
    Ear 1: VibeVoice transcript (treated as the default; presumed correct)
    Ear 2: FluidAudio Parakeet transcript (independent second ASR)
  JUDGE (Voxtral Small 24B):
    Receives audio (±5s of the disputed span) plus both candidate texts
    Decides:
      - "keep_a"            → VibeVoice was right (or the diff is trivial)
      - "replace_with_b"    → Parakeet matches the audio better
      - "replace_with_other" → Both candidates are wrong; provide a third correction

The judge is asked to PICK rather than transcribe — earlier experiments showed
that smaller models (Voxtral 3B) hallucinate when asked to transcribe fresh,
and Qwen2.5-Omni anchors on whatever candidate is shown. Picking among labeled
candidates is a different cognitive task that should be more reliable for a
larger reasoning-grade model.

Standard-of-proof gate at the decision layer:
  - Threshold on judge's reported confidence
  - Trivial-diff filter
  - Length-ratio check (rejects segmentation-level merges)
  - Explicit "default = keep_a" framing in the prompt

Reuses parse_review and is_trivial_diff from run_phase_a, and the disagreements
file produced by find_disagreements.py.
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
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
from run_phase_a import is_trivial_diff


JUDGE_PROMPT_TEMPLATE = """Listen carefully to the audio clip. Two automatic speech recognition (ASR) systems have transcribed a specific portion of this clip differently. Your job is to listen to what is actually said in that portion and pick which candidate matches the audio better, or propose your own correction if both are wrong.

CANDIDATE A (from VibeVoice — the default; we keep this unless you find clear evidence to override):
"{a_text}"

CANDIDATE B (from a second ASR system, FluidAudio Parakeet):
"{b_text}"

The disputed sub-region is approximately {dispute_window_seconds:.1f} seconds long. The audio you receive extends ±5 seconds around it for context.

WHAT THE DIFFER FLAGGED AS THE WORD-LEVEL DISAGREEMENT:
{diff_summary}

Decision standards:

1. TRIVIAL differences are NOT substantive. If the only disagreement is punctuation, capitalization, contractions, filler words ("uh", "um"), numeric format ("100%" vs "Hundred percent"), word-order variations that preserve meaning — choose verdict="keep_a".

2. SUBSTANTIVE difference (a wrong word, wrong proper name, missing/added phrase that materially changes meaning) requires:
   - You can clearly identify what was said in the disputed sub-region from the audio
   - The actual speech materially differs from at least one candidate
   - You can state both what's wrong and what was actually said

3. When in doubt, defer to CANDIDATE A. The default is to keep VibeVoice's text. You must clear a high bar to overturn it.

4. Both candidates may be wrong. If you hear something different from both, choose verdict="replace_with_other" and provide your own transcription of just the disputed sub-region.

End your response with EXACTLY one line of JSON on the last line:
{{"heard": "...what you actually hear in the disputed sub-region...", "verdict": "keep_a"|"replace_with_b"|"replace_with_other", "confidence_wrong": 0.00-1.00, "corrected": "...", "evidence": "..."}}

Field meanings:
- heard: your own transcription of just the disputed sub-region (NOT the full ±5s clip).
- verdict: pick one of "keep_a", "replace_with_b", "replace_with_other".
- confidence_wrong: probability (0.0-1.0) that CANDIDATE A is materially wrong AND your replacement is right. Use 0.0 when verdict="keep_a". Reserve >0.75 for cases where you can clearly identify the wrong word and what was actually said.
- corrected: the replacement text (only the disputed sub-region — do NOT include surrounding context). Empty string when verdict="keep_a"; otherwise CANDIDATE B's text (if verdict="replace_with_b") or your own transcription (if verdict="replace_with_other").
- evidence: one short sentence stating what specifically you heard differently or how the audio supports your verdict. Empty when verdict="keep_a"; non-empty otherwise.

Be honest about what you actually hear. Do not just rationalize keeping the candidate; do not invent corrections. Only overturn Candidate A if you can articulate specifically what is wrong.
"""


def extract_audio_clip(src_audio: Path, out_dir: Path, start: float, end: float, pad_seconds: float = 5.0) -> Path:
    clip_start = max(0.0, start - pad_seconds)
    clip_dur = max(0.5, (end - start) + 2 * pad_seconds)
    out_path = out_dir / f"clip_{int(start * 1000):08d}_{int(end * 1000):08d}.wav"
    subprocess.run(
        ["/opt/homebrew/bin/ffmpeg", "-y", "-loglevel", "error",
         "-ss", f"{clip_start:.3f}", "-i", str(src_audio),
         "-t", f"{clip_dur:.3f}", "-ar", "16000", "-ac", "1",
         "-c:a", "pcm_s16le", str(out_path)],
        check=True,
    )
    return out_path


def call_judge(
    gguf: Path,
    mmproj: Path,
    audio_clip: Path,
    prompt: str,
    n_gpu_layers: int = 99,
    max_tokens: int = 768,
    timeout: float = 480.0,
    use_jinja: bool = True,
) -> tuple[str, float]:
    args = [
        "/opt/homebrew/bin/llama-mtmd-cli",
        "-m", str(gguf), "--mmproj", str(mmproj),
        "--audio", str(audio_clip),
        "-p", prompt, "-n", str(max_tokens),
        "--temp", "0.0", "-ngl", str(n_gpu_layers),
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


def parse_judge(raw: str) -> dict:
    if not raw or raw.startswith("<"):
        return {"verdict": "keep_a", "confidence_wrong": 0.0, "corrected": "", "evidence": "", "heard": "", "raw": raw[:600], "_parse_error": "empty/error"}
    text = re.sub(r"<think>.*?</think>", "", raw, flags=re.DOTALL).strip()
    json_matches = list(re.finditer(r"\{[^{}]*\}", text, re.DOTALL))
    parsed: dict = {}
    if json_matches:
        try:
            parsed = json.loads(json_matches[-1].group(0))
        except json.JSONDecodeError:
            pass
    return {
        "verdict": str(parsed.get("verdict") or "keep_a").lower(),
        "confidence_wrong": float(parsed.get("confidence_wrong") or 0),
        "corrected": str(parsed.get("corrected") or "").strip(),
        "evidence": str(parsed.get("evidence") or "").strip(),
        "heard": str(parsed.get("heard") or "").strip(),
        "raw": raw[:800],
        "_parse_error": None if parsed else "no JSON parsed",
    }


def decide_verdict(parsed: dict, a_text: str, b_text: str, threshold: float) -> tuple[bool, str, str]:
    """(apply, rejection_reason, final_text)"""
    verdict = parsed.get("verdict", "keep_a")
    if verdict == "keep_a":
        return False, "judge_says_keep_a", a_text

    confidence = float(parsed.get("confidence_wrong") or 0)
    corrected = parsed.get("corrected", "").strip()

    # If verdict is replace_with_b, the corrected text should be (or be similar to) b_text.
    # If empty, treat verdict semantics: replace_with_b → use b_text.
    if verdict == "replace_with_b" and not corrected:
        corrected = b_text

    if not corrected:
        return False, "empty_corrected", a_text

    if confidence < threshold:
        return False, f"confidence_below_threshold ({confidence:.2f} < {threshold:.2f})", a_text

    evidence = parsed.get("evidence", "").strip()
    if not evidence or len(evidence) < 12:
        return False, f"evidence_missing_or_too_short ({evidence!r})", a_text

    if is_trivial_diff(a_text, corrected):
        return False, "trivial_diff", a_text

    a_words = len(a_text.split())
    c_words = len(corrected.split())
    if a_words > 0:
        ratio = c_words / a_words
        if ratio > 2.5 or ratio < 0.4:
            return False, f"length_mismatch (a={a_words}w vs corrected={c_words}w; ratio {ratio:.2f})", a_text

    return True, "", corrected


def apply_corrections(vibevoice: dict, accepted: list[dict]) -> dict:
    by_idx_map: dict[int, str] = {}
    for record in accepted:
        if record["applied"]:
            for ai in record["a_segment_indices"]:
                by_idx_map[ai] = record["final_text"]
    out_segments = []
    for i, seg in enumerate(vibevoice.get("segments") or []):
        new_seg = dict(seg)
        if i in by_idx_map:
            new_seg["original_text"] = seg.get("text")
            new_seg["text"] = by_idx_map[i]
            new_seg["corrected_by"] = "voxtral-small-24b-judge"
        out_segments.append(new_seg)
    out = dict(vibevoice)
    out["segments"] = out_segments
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

    print(f"[v4] judge reviewing {len(spans)} disagreement spans at threshold={args.threshold:.2f}")

    work_dir = Path(tempfile.mkdtemp(prefix="phase_a_v4_"))
    review_log_fh = args.review_log.open("w")
    accepted_records = []
    flips = 0
    rejections: dict[str, int] = {}
    pipeline_start = time.time()
    total_review_seconds = 0.0

    try:
        for idx, span in enumerate(spans):
            try:
                clip = extract_audio_clip(args.audio, work_dir, span["start"], span["end"], pad_seconds=5.0)
            except subprocess.CalledProcessError as e:
                print(f"[v4] ffmpeg failed at span {idx}: {e}", file=sys.stderr)
                continue

            prompt = JUDGE_PROMPT_TEMPLATE.format(
                a_text=span["a_text"].replace('"', '\\"'),
                b_text=span["b_text"].replace('"', '\\"'),
                dispute_window_seconds=span["end"] - span["start"],
                diff_summary=span.get("diff_summary", "(unavailable)"),
            )
            raw, review_seconds = call_judge(
                gguf=args.gguf, mmproj=args.mmproj, audio_clip=clip, prompt=prompt, use_jinja=args.use_jinja,
            )
            parsed = parse_judge(raw)
            total_review_seconds += review_seconds

            apply, reason, final_text = decide_verdict(parsed, span["a_text"], span["b_text"], args.threshold)
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
                "judge_verdict": parsed.get("verdict"),
                "judge_confidence_wrong": parsed.get("confidence_wrong"),
                "judge_corrected": parsed.get("corrected"),
                "judge_heard": parsed.get("heard"),
                "judge_evidence": parsed.get("evidence"),
                "judge_raw": parsed.get("raw"),
                "applied": apply,
                "rejection_reason": reason if not apply else "",
                "final_text": final_text,
                "a_segment_indices": span.get("a_segment_indices", []),
                "review_seconds": review_seconds,
                "parse_error": parsed.get("_parse_error"),
            }
            accepted_records.append(record)
            review_log_fh.write(json.dumps(record) + "\n")
            review_log_fh.flush()

            try: clip.unlink()
            except FileNotFoundError: pass

            elapsed = time.time() - pipeline_start
            eta = elapsed / (idx + 1) * (len(spans) - idx - 1)
            marker = "[FLIP]" if apply else f"[keep:{reason[:24]}]"
            print(
                f"[v4] {idx+1}/{len(spans)} {marker} verdict={parsed.get('verdict')} "
                f"conf={parsed.get('confidence_wrong'):.2f} ({review_seconds:.1f}s; total {elapsed:.0f}s; eta {eta:.0f}s)",
                flush=True,
            )
    finally:
        review_log_fh.close()

    corrected = apply_corrections(vibevoice, accepted_records)
    args.out.write_text(json.dumps(corrected, indent=2))

    print(
        f"\n[v4] done.\n"
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
