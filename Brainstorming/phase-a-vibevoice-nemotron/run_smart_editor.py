"""Phase A v5: smart editor architecture.

Reframing of the whole problem after several rounds of iteration:

The job is NOT to merge VibeVoice's transcript with a second ASR's transcript.
The job is NOT to pick between candidates per segment. The job is exactly what
a careful human editor would do:

    Read the transcript. Listen to the audio. Mark errors with surgical
    corrections. Do not rewrite. Do not merge.

So this sidecar:
    1. Treats VibeVoice's transcript as the canonical document. Period.
    2. Sends it (with segment indices) plus the audio to a reasoning model
       (Voxtral Small 24B by default).
    3. Asks the model for a structured list of PATCHES — each patch is
       `{segment_index, find, replace, evidence}`. The find string must be
       an exact substring of the segment's existing text.
    4. Filters patches via the existing standard-of-proof gate (trivial-diff,
       length sanity, evidence required).
    5. Applies the surviving patches as in-place find/replace on the
       relevant segment's text. Segment count, speakers, timestamps untouched.

Optional: take the existing disagreement detector's output as a HINT to focus
the model's attention on contested spans, but the model is not told to "pick"
between candidates — only to listen and edit if it hears something different.

Compared to v3 / v4:
    - No transcript merging. Edits are scoped to the segment they target.
    - No "verdict" enum. Output is patches; absence of a patch means "no error."
    - Apply logic is just string find/replace, not segment swap.
    - Failure mode of "judge transcribes the whole ±5s audio" is structurally
      impossible — patches must reference text that exists in the segment.
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
from run_phase_a import is_trivial_diff, normalize_for_comparison


EDITOR_PROMPT_TEMPLATE = """You are a careful editor reviewing an automatic transcript of a recorded conversation. The transcript was produced by a speech recognition system and may contain errors.

Your job: listen to the audio, read the transcript, and output a JSON list of TARGETED EDITS to fix substantive errors you find.

EDITING RULES:

1. Make the SMALLEST possible change. If a single word is wrong, your edit replaces just that word, not the surrounding sentence.

2. Only flag SUBSTANTIVE errors. These are:
   - Wrong proper names (e.g., "Bernard Cohen" when audio says "Brant Kuehn")
   - Wrong content words that change meaning (e.g., "meditation" when audio says "mediation")
   - Missing or added phrases that materially change content
   - Wrong numbers, organizations, places

3. DO NOT FLAG these (leave them alone):
   - Punctuation, capitalization
   - Contractions ("won't" vs "will not")
   - Filler words ("uh", "um", "you know") added or omitted
   - Numeric format ("100%" vs "Hundred percent", "two" vs "2")
   - Word order variations that preserve meaning
   - False starts and disfluencies that don't change meaning

4. When in doubt, leave it alone. Trust the existing transcript unless you have SPECIFIC evidence from the audio that something is materially wrong.

5. The "find" string in each edit MUST be an exact substring of the segment's existing text. The "replace" string is what the audio actually says.

If the transcript has no substantive errors, return an empty edit list. That is a perfectly valid answer and should be the default when you are unsure.

THE TRANSCRIPT (with segment indices in brackets):

{transcript_block}
{hint_block}
End your response with EXACTLY one line of JSON on the last line:
{{"edits": [{{"segment": <int>, "find": "<exact text from segment>", "replace": "<corrected text>", "evidence": "<one short sentence stating what specifically you heard>"}}, ...]}}

If you find no errors: {{"edits": []}}

Remember: the default action is NO EDIT. Only emit an edit when you are clearly hearing something different from what the transcript says, AND you can identify the specific wrong word. Do not invent edits. Do not over-correct. Trust the existing transcript.
"""


def format_transcript_block(segments: list[dict], max_segments: int | None = None) -> str:
    """Render the transcript as numbered lines for the model."""
    items = segments[:max_segments] if max_segments else segments
    lines = []
    for i, seg in enumerate(items):
        text = (seg.get("text") or "").strip()
        if not text:
            continue
        speaker = seg.get("speaker_id") or seg.get("speaker") or "?"
        start = float(seg.get("start") or 0)
        end = float(seg.get("end") or 0)
        lines.append(f"[seg {i:3d} | {speaker} | {start:6.1f}-{end:6.1f}s] {text}")
    return "\n".join(lines)


def format_hint_block(disagreements: list[dict] | None) -> str:
    """If we have a disagreement-detector output, emit a brief hint listing
    timestamps the model might want to listen to closely. NOT presented as
    candidate transcripts to merge — just as a heatmap."""
    if not disagreements:
        return ""
    lines = ["", "OPTIONAL HINT — A second ASR system flagged these timestamps as places where it heard something different from VibeVoice. They are *worth a closer listen*; they are not authoritative. Use them only if you also hear the discrepancy.", ""]
    for d in disagreements[:30]:
        lines.append(f"  ~{d['start']:.1f}-{d['end']:.1f}s: differ noted '{d.get('diff_summary', '')[:120]}'")
    return "\n".join(lines) + "\n\n"


def call_editor(
    gguf: Path,
    mmproj: Path,
    audio_clip: Path,
    prompt: str,
    n_gpu_layers: int = 99,
    max_tokens: int = 2048,
    timeout: float = 1200.0,
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
        "--ctx-size", "16384",
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


def parse_edits(raw: str) -> tuple[list[dict], dict]:
    """Extract the edits list from the model output."""
    info = {"raw": raw[:1000], "parse_error": None}
    if not raw or raw.startswith("<"):
        info["parse_error"] = "empty_or_error"
        return [], info

    text = re.sub(r"<think>.*?</think>", "", raw, flags=re.DOTALL).strip()
    # Strip ```json ... ``` fences if present
    text = re.sub(r"```(?:json)?\s*", "", text)
    text = text.replace("```", "")

    # Find JSON objects by scanning brace-balance, not regex (regex with nested
    # objects causes catastrophic backtracking on bad input).
    candidates: list[str] = []
    i = 0
    while i < len(text):
        if text[i] == "{":
            depth = 0
            start = i
            while i < len(text):
                c = text[i]
                if c == "{":
                    depth += 1
                elif c == "}":
                    depth -= 1
                    if depth == 0:
                        candidates.append(text[start:i + 1])
                        i += 1
                        break
                i += 1
            else:
                break  # Unclosed; stop scanning
        else:
            i += 1

    parsed = None
    for cand in reversed(candidates):
        try:
            obj = json.loads(cand)
            if isinstance(obj, dict) and "edits" in obj:
                parsed = obj
                break
        except json.JSONDecodeError:
            continue
    if parsed is None:
        # As a last resort, try the largest candidate
        for cand in sorted(candidates, key=len, reverse=True):
            try:
                obj = json.loads(cand)
                if isinstance(obj, dict):
                    parsed = obj
                    break
            except json.JSONDecodeError:
                continue
    if not parsed:
        info["parse_error"] = "no_valid_json"
        return [], info

    edits = parsed.get("edits", [])
    if not isinstance(edits, list):
        info["parse_error"] = "edits_not_list"
        return [], info

    return edits, info


def filter_and_apply_edits(
    segments: list[dict],
    edits: list[dict],
) -> tuple[list[dict], list[dict]]:
    """Apply each edit to the relevant segment's text after filtering through
    the standard-of-proof gate. Returns (new_segments, audit_records).

    Each edit is rejected if:
      - segment_index out of range
      - find string not present in segment text
      - find/replace are trivially equivalent (punctuation/case/filler-only)
      - evidence missing or too short
      - replace string is empty
      - replace string is suspiciously longer than find (>3x — probably not surgical)
    """
    new_segments = [dict(s) for s in segments]
    audit = []

    for edit in edits:
        try:
            seg_idx = int(edit.get("segment"))
        except (TypeError, ValueError):
            audit.append({"edit": edit, "applied": False, "rejection_reason": "bad_segment_index"})
            continue
        find = str(edit.get("find") or "").strip()
        replace = str(edit.get("replace") or "").strip()
        evidence = str(edit.get("evidence") or "").strip()

        if seg_idx < 0 or seg_idx >= len(new_segments):
            audit.append({"edit": edit, "applied": False, "rejection_reason": f"segment_out_of_range ({seg_idx})"})
            continue
        if not find:
            audit.append({"edit": edit, "applied": False, "rejection_reason": "empty_find"})
            continue
        if not replace:
            audit.append({"edit": edit, "applied": False, "rejection_reason": "empty_replace"})
            continue
        if not evidence or len(evidence) < 12:
            audit.append({"edit": edit, "applied": False, "rejection_reason": "missing_evidence"})
            continue

        seg_text = new_segments[seg_idx].get("text", "")
        if find not in seg_text:
            # Try case-insensitive contains as a soft match
            lower_text = seg_text.lower()
            lower_find = find.lower()
            if lower_find not in lower_text:
                audit.append({"edit": edit, "applied": False, "rejection_reason": "find_string_not_in_segment", "segment_text": seg_text[:120]})
                continue
            # Adjust find to the actual case
            start = lower_text.index(lower_find)
            find = seg_text[start:start + len(find)]

        if is_trivial_diff(find, replace):
            audit.append({"edit": edit, "applied": False, "rejection_reason": "trivial_diff"})
            continue

        find_words = len(find.split())
        repl_words = len(replace.split())
        if find_words > 0:
            ratio = repl_words / find_words
            if ratio > 3.0 or ratio < 0.33:
                audit.append({"edit": edit, "applied": False, "rejection_reason": f"length_mismatch ({find_words}->{repl_words})"})
                continue

        # Apply
        new_text = seg_text.replace(find, replace, 1)
        new_segments[seg_idx]["original_text"] = new_segments[seg_idx].get("original_text") or seg_text
        new_segments[seg_idx]["text"] = new_text
        audit.append({
            "edit": edit,
            "applied": True,
            "segment_index": seg_idx,
            "before": seg_text,
            "after": new_text,
        })

    return new_segments, audit


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--vibevoice-json", type=Path, required=True)
    parser.add_argument("--audio", type=Path, required=True)
    parser.add_argument("--gguf", type=Path, required=True)
    parser.add_argument("--mmproj", type=Path, required=True)
    parser.add_argument("--out", type=Path, required=True)
    parser.add_argument("--audit-log", type=Path, required=True)
    parser.add_argument("--disagreements", type=Path, default=None,
                        help="Optional disagreement file for the hint block.")
    parser.add_argument("--max-segments", type=int, default=0,
                        help="Truncate transcript to first N segments (smoke testing). 0 = all.")
    parser.add_argument("--use-jinja", action="store_true", default=True)
    args = parser.parse_args()

    vibevoice = json.loads(args.vibevoice_json.read_text())
    segments = list(vibevoice.get("segments") or [])
    if args.max_segments > 0:
        segments = segments[: args.max_segments]
    transcript_block = format_transcript_block(segments, max_segments=args.max_segments or None)

    hint_block = ""
    if args.disagreements:
        try:
            d = json.loads(args.disagreements.read_text())
            hint_block = format_hint_block(d.get("disagreements", []))
        except Exception:
            hint_block = ""

    prompt = EDITOR_PROMPT_TEMPLATE.format(
        transcript_block=transcript_block,
        hint_block=hint_block,
    )

    print(f"[v5] sending {len(segments)} segments + audio to editor", flush=True)
    print(f"[v5] prompt size: {len(prompt)} chars", flush=True)

    t0 = time.time()
    raw, review_seconds = call_editor(
        gguf=args.gguf,
        mmproj=args.mmproj,
        audio_clip=args.audio,
        prompt=prompt,
        use_jinja=args.use_jinja,
    )
    print(f"[v5] editor returned in {review_seconds:.1f}s", flush=True)

    edits, parse_info = parse_edits(raw)
    print(f"[v5] parsed {len(edits)} proposed edits", flush=True)

    new_segments, audit = filter_and_apply_edits(segments, edits)
    applied_count = sum(1 for a in audit if a.get("applied"))
    print(f"[v5] applied {applied_count} of {len(edits)} edits", flush=True)

    # Write outputs
    out_payload = dict(vibevoice)
    out_payload["segments"] = new_segments + list(vibevoice.get("segments") or [])[len(segments):] if args.max_segments else new_segments
    args.out.write_text(json.dumps(out_payload, indent=2))

    audit_log_data = {
        "review_seconds": review_seconds,
        "wall_clock_seconds": time.time() - t0,
        "raw_response": parse_info["raw"],
        "parse_error": parse_info.get("parse_error"),
        "proposed_edits": edits,
        "applied_count": applied_count,
        "audit": audit,
    }
    args.audit_log.write_text(json.dumps(audit_log_data, indent=2))
    print(f"[v5] audit log -> {args.audit_log}")

    # Print decisions for visibility
    for a in audit:
        edit = a.get("edit", {})
        if a.get("applied"):
            print(f"  [APPLIED] seg {edit.get('segment')}: {edit.get('find')!r} -> {edit.get('replace')!r}")
            print(f"            evidence: {edit.get('evidence', '')[:120]}")
        else:
            print(f"  [reject:{a.get('rejection_reason','')[:30]}] seg {edit.get('segment')}: {edit.get('find','')[:60]!r} -> {edit.get('replace','')[:60]!r}")

    return 0


if __name__ == "__main__":
    sys.exit(main())
