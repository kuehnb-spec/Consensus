"""Phase A v7: candidate patch verifier.

This experiment separates the editing job into three narrower roles:

1. Candidate generation: a second ASR transcript proposes small word
   replacements where it differs from VibeVoice.
2. Audio verification: a multimodal model receives one exact candidate patch
   plus the local audio window and decides only keep/apply.
3. Deterministic apply gate: exact in-segment character replacement only.

The verifier is intentionally not allowed to author new text. It can only say
whether the proposed replacement is audibly better than the current phrase.
"""

from __future__ import annotations

import argparse
import json
import re
import subprocess
import sys
import tempfile
import time
from dataclasses import dataclass
from difflib import SequenceMatcher
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
from run_local_relisten_editor import (
    TOKEN_RE,
    apply_patches,
    canonicalize_replacement,
    tokenize_with_spans,
    unsafe_or_trivial_patch,
)


PROMPT = """You are verifying one exact transcript patch against the audio.

Current transcript segment:
"{segment_text}"

Proposed patch:
replace "{find}" with "{replace}"

Listen to the audio. Decide only whether this exact proposed patch is audibly correct at the relevant moment.

Rules:
- Default to keep_current unless the audio clearly says the proposed replacement.
- Do not suggest a different edit.
- Do not apply punctuation, capitalization, title formatting, filler, or discourse-marker changes.
- If the two phrases sound equally plausible, keep_current.

Reply with exactly one JSON object:
{{"decision":"keep_current"|"apply_patch","heard":"...","confidence":0.0,"reason":"..."}}
"""


MASKED_PROMPT = """You are filling one blank in a transcript using the audio.

Transcript with blank:
"{masked_segment}"

Allowed fills:
1. "{find}"
2. "{replace}"

Listen to the audio and choose the fill that is actually spoken. Use the surrounding words only as anchors. Reply with exactly one JSON object:
{{"fill":"one allowed fill exactly","confidence":0.0,"reason":"..."}}
"""


@dataclass
class SegmentOffset:
    index: int
    start_char: int
    end_char: int
    audio_start: float
    audio_end: float
    text: str


def normalize_items(raw: dict) -> list[dict]:
    items = raw.get("segments") or raw.get("turns") or raw.get("transcription") or []
    out = []
    for item in items:
        text = (item.get("text") or item.get("Content") or "").strip()
        if not text:
            continue
        out.append({
            "start": float(item.get("start") or item.get("start_time") or item.get("Start") or 0),
            "end": float(item.get("end") or item.get("end_time") or item.get("End") or 0),
            "speaker_id": item.get("speaker_id") or item.get("speaker") or item.get("Speaker"),
            "text": text,
        })
    return out


def concatenate_segments(segments: list[dict]) -> tuple[str, list[SegmentOffset]]:
    parts: list[str] = []
    offsets: list[SegmentOffset] = []
    pos = 0
    for idx, seg in enumerate(segments):
        if parts:
            parts.append(" ")
            pos += 1
        text = seg["text"]
        start = pos
        parts.append(text)
        pos += len(text)
        offsets.append(SegmentOffset(
            index=idx,
            start_char=start,
            end_char=pos,
            audio_start=float(seg["start"]),
            audio_end=float(seg["end"]),
            text=text,
        ))
    return "".join(parts), offsets


def segment_for_span(offsets: list[SegmentOffset], start: int, end: int) -> SegmentOffset | None:
    for seg in offsets:
        if seg.start_char <= start and end <= seg.end_char:
            return seg
    return None


def generate_candidates(
    canonical_text: str,
    offsets: list[SegmentOffset],
    opinion_text: str,
    max_words: int,
    protected_terms: set[str],
) -> list[dict]:
    canonical_tokens = tokenize_with_spans(canonical_text)
    opinion_tokens = tokenize_with_spans(opinion_text)
    matcher = SequenceMatcher(
        a=[t["norm"] for t in canonical_tokens],
        b=[t["norm"] for t in opinion_tokens],
        autojunk=False,
    )

    candidates: list[dict] = []
    for tag, i1, i2, j1, j2 in matcher.get_opcodes():
        if tag != "replace":
            continue
        find_tokens = canonical_tokens[i1:i2]
        replace_tokens = opinion_tokens[j1:j2]
        if not find_tokens or not replace_tokens:
            continue
        if len(find_tokens) > max_words or len(replace_tokens) > max_words:
            continue
        find_start = find_tokens[0]["start"]
        find_end = find_tokens[-1]["end"]
        seg = segment_for_span(offsets, find_start, find_end)
        if seg is None:
            continue
        find = canonical_text[find_start:find_end]
        replace = canonicalize_replacement(find, " ".join(t["text"] for t in replace_tokens))
        find_norm = " ".join(t["norm"] for t in tokenize_with_spans(find))
        replace_norm = " ".join(t["norm"] for t in tokenize_with_spans(replace))
        if find_norm in protected_terms and replace_norm not in protected_terms:
            continue
        reject = unsafe_or_trivial_patch(find, replace, len(tokenize_with_spans(seg.text)))
        if reject:
            continue
        candidates.append({
            "segment_index": seg.index,
            "segment_text": seg.text,
            "segment_start_char": seg.start_char,
            "find_start": find_start - seg.start_char,
            "find_end": find_end - seg.start_char,
            "find": find,
            "replace": replace,
            "audio_start": seg.audio_start,
            "audio_end": seg.audio_end,
        })
    return candidates


def extract_clip(src_audio: Path, out_dir: Path, start: float, end: float, pad: float) -> Path:
    clip_start = max(0.0, start - pad)
    duration = max(0.2, end - clip_start + pad)
    out = out_dir / f"verify_{int(start * 1000):08d}_{int(end * 1000):08d}.wav"
    subprocess.run(
        [
            "/opt/homebrew/bin/ffmpeg",
            "-y",
            "-loglevel",
            "error",
            "-ss",
            f"{clip_start:.3f}",
            "-i",
            str(src_audio),
            "-t",
            f"{duration:.3f}",
            "-ar",
            "16000",
            "-ac",
            "1",
            "-c:a",
            "pcm_s16le",
            str(out),
        ],
        check=True,
    )
    return out


def extract_json(raw: str) -> dict:
    candidates: list[str] = []
    i = 0
    while i < len(raw):
        if raw[i] != "{":
            i += 1
            continue
        depth = 0
        start = i
        while i < len(raw):
            if raw[i] == "{":
                depth += 1
            elif raw[i] == "}":
                depth -= 1
                if depth == 0:
                    candidates.append(raw[start:i + 1])
                    i += 1
                    break
            i += 1
        else:
            break
    for cand in reversed(candidates):
        try:
            obj = json.loads(cand)
        except json.JSONDecodeError:
            continue
        if isinstance(obj, dict) and ("decision" in obj or "fill" in obj):
            return obj
    return {"decision": "keep_current", "confidence": 0.0, "reason": "no_valid_json", "raw": raw[-800:]}


def mask_segment_text(segment_text: str, find_start: int, find_end: int) -> str:
    return segment_text[:find_start].rstrip() + " ____ " + segment_text[find_end:].lstrip()


def call_verifier(
    gguf: Path,
    mmproj: Path,
    audio_clip: Path,
    prompt: str,
    timeout: float,
) -> tuple[dict, float, str]:
    args = [
        "/opt/homebrew/bin/llama-mtmd-cli",
        "-m",
        str(gguf),
        "--mmproj",
        str(mmproj),
        "--audio",
        str(audio_clip),
        "-p",
        prompt,
        "-n",
        "256",
        "--temp",
        "0.0",
        "-ngl",
        "99",
        "--ctx-size",
        "4096",
        "--jinja",
    ]
    t0 = time.time()
    try:
        proc = subprocess.run(args, capture_output=True, check=False, timeout=timeout)
    except subprocess.TimeoutExpired:
        return {"decision": "keep_current", "confidence": 0.0, "reason": "timeout"}, time.time() - t0, ""
    elapsed = time.time() - t0
    stdout = proc.stdout.decode("utf-8", errors="replace") if proc.stdout else ""
    stderr = proc.stderr.decode("utf-8", errors="replace") if proc.stderr else ""
    raw = stdout + "\n" + stderr
    if proc.returncode != 0:
        return {"decision": "keep_current", "confidence": 0.0, "reason": f"error_code_{proc.returncode}", "raw": raw[-800:]}, elapsed, raw
    return extract_json(raw), elapsed, raw


def call_masked_verifier(
    gguf: Path,
    mmproj: Path,
    audio_clip: Path,
    prompt: str,
    timeout: float,
) -> tuple[dict, float, str]:
    parsed, elapsed, raw = call_verifier(gguf, mmproj, audio_clip, prompt, timeout)
    if "fill" in parsed:
        return parsed, elapsed, raw
    return parsed, elapsed, raw


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--vibevoice-json", type=Path, required=True)
    parser.add_argument("--opinion-json", type=Path, required=True)
    parser.add_argument("--audio", type=Path, required=True)
    parser.add_argument("--gguf", type=Path, required=True)
    parser.add_argument("--mmproj", type=Path, required=True)
    parser.add_argument("--out", type=Path, required=True)
    parser.add_argument("--audit-log", type=Path, required=True)
    parser.add_argument("--max-words", type=int, default=5)
    parser.add_argument("--confidence-threshold", type=float, default=0.85)
    parser.add_argument("--protected-terms", default="",
                        help="Comma-separated hotwords/domain terms that should not be replaced away from.")
    parser.add_argument("--pad", type=float, default=1.2)
    parser.add_argument("--limit", type=int, default=0)
    parser.add_argument("--timeout", type=float, default=420.0)
    parser.add_argument("--masked-cloze", action="store_true",
                        help="Mask the disputed phrase and ask the verifier to choose the fill instead of judging an embedded patch.")
    args = parser.parse_args()

    canonical_raw = json.loads(args.vibevoice_json.read_text())
    canonical_segments = normalize_items(canonical_raw)
    canonical_text, offsets = concatenate_segments(canonical_segments)
    opinion_text = " ".join(item["text"] for item in normalize_items(json.loads(args.opinion_json.read_text())))
    protected_terms = {
        " ".join(t["norm"] for t in tokenize_with_spans(term))
        for term in args.protected_terms.split(",")
        if term.strip()
    }
    candidates = generate_candidates(canonical_text, offsets, opinion_text, args.max_words, protected_terms)
    if args.limit > 0:
        candidates = candidates[: args.limit]

    label = "v8-masked" if args.masked_cloze else "v7"
    print(f"[{label}] generated {len(candidates)} candidate patches")
    work_dir = Path(tempfile.mkdtemp(prefix="phase_a_v7_verify_"))
    audit: list[dict] = []
    accepted_by_segment: dict[int, list[dict]] = {}
    total_seconds = 0.0

    for idx, cand in enumerate(candidates, start=1):
        clip = extract_clip(args.audio, work_dir, cand["audio_start"], cand["audio_end"], args.pad)
        if args.masked_cloze:
            prompt = MASKED_PROMPT.format(
                masked_segment=mask_segment_text(cand["segment_text"], cand["find_start"], cand["find_end"]).replace('"', '\\"'),
                find=cand["find"].replace('"', '\\"'),
                replace=cand["replace"].replace('"', '\\"'),
            )
            parsed, elapsed, raw = call_masked_verifier(args.gguf, args.mmproj, clip, prompt, args.timeout)
        else:
            prompt = PROMPT.format(
                segment_text=cand["segment_text"].replace('"', '\\"'),
                find=cand["find"].replace('"', '\\"'),
                replace=cand["replace"].replace('"', '\\"'),
            )
            parsed, elapsed, raw = call_verifier(args.gguf, args.mmproj, clip, prompt, args.timeout)
        total_seconds += elapsed
        confidence = float(parsed.get("confidence") or 0.0)
        if args.masked_cloze:
            fill = str(parsed.get("fill") or "").strip()
            if fill == cand["replace"]:
                decision = "apply_patch"
            elif fill == cand["find"]:
                decision = "keep_current"
            else:
                decision = "keep_current"
                parsed["reason"] = f"fill_not_allowed_or_not_exact: {fill!r}; " + str(parsed.get("reason") or "")
        else:
            decision = str(parsed.get("decision") or "keep_current").lower()
        applied = decision == "apply_patch" and confidence >= args.confidence_threshold
        if applied:
            accepted_by_segment.setdefault(cand["segment_index"], []).append({
                "find_start": cand["find_start"],
                "find_end": cand["find_end"],
                "find": cand["find"],
                "replace": cand["replace"],
            })
        audit.append({
            "candidate_index": idx - 1,
            "candidate": cand,
            "decision": decision,
            "confidence": confidence,
            "reason": parsed.get("reason"),
            "heard": parsed.get("heard"),
            "fill": parsed.get("fill"),
            "applied": applied,
            "elapsed_seconds": elapsed,
            "raw_tail": raw[-1000:],
        })
        print(f"[{label}] {idx:02d}/{len(candidates):02d} seg {cand['segment_index']} {cand['find']!r}->{cand['replace']!r}: {decision} {confidence:.2f}")

    out_segments = [dict(seg) for seg in canonical_raw.get("segments", canonical_segments)]
    for seg_idx, patches in accepted_by_segment.items():
        text = out_segments[seg_idx].get("text") or ""
        out_segments[seg_idx]["original_text"] = out_segments[seg_idx].get("original_text") or text
        out_segments[seg_idx]["text"] = apply_patches(text, patches)
        out_segments[seg_idx]["corrected_by"] = "voxtral-patch-verifier-v7"

    out_payload = dict(canonical_raw)
    out_payload["segments"] = out_segments
    args.out.write_text(json.dumps(out_payload, indent=2))
    args.audit_log.write_text(json.dumps({
        "candidate_count": len(candidates),
        "applied_count": sum(1 for item in audit if item["applied"]),
        "total_seconds": total_seconds,
        "audit": audit,
    }, indent=2))
    print(f"[{label}] applied {sum(1 for item in audit if item['applied'])} patch(es)")
    print(f"[{label}] wrote {args.out}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
