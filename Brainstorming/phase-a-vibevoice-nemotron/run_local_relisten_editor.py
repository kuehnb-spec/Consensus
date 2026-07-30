"""Phase A v6: local re-listen editor.

This experiment keeps the v5 "surgical patch" shape, but replaces the
free-form multimodal editor with a more constrained tool loop:

1. A second ASR/disagreement pass supplies candidate segment indices. It is a
   heatmap only; it never supplies authoritative replacement text.
2. VibeVoice re-transcribes only the candidate segment's local audio window,
   using the same hotword/context hints as the primary pass.
3. The script diffs the current segment text against the local re-listen text
   and applies only small word-replacement patches. No insert/delete-only
   changes, no whole-segment swaps, and no patches that are trivial after the
   standard Phase A normalization.

The aim is to make the "editor" act like a person with tools: look at a
flagged sentence, listen to that sentence again, and make the smallest possible
word correction only when the local audio evidence produces a different word.
"""

from __future__ import annotations

import argparse
import json
import re
import subprocess
import sys
import tempfile
import time
from dataclasses import asdict, is_dataclass
from difflib import SequenceMatcher
from pathlib import Path
from typing import Iterable

sys.path.insert(0, str(Path(__file__).parent))
from run_phase_a import is_trivial_diff


TOKEN_RE = re.compile(r"[A-Za-z0-9]+(?:'[A-Za-z0-9]+)?%?")


def token_norm(token: str) -> str:
    s = token.lower().strip()
    if s.endswith("%"):
        s = s[:-1]
    return s.replace("'", "")


def local_equivalence_norm(text: str) -> str:
    tokens = [token_norm(t["text"]) for t in tokenize_with_spans(text)]
    aliases = {
        "cause": "because",
        "cuz": "because",
        "cos": "because",
        "ms": "miss",
        "mrs": "misses",
    }
    return " ".join(aliases.get(t, t) for t in tokens if t)


def unsafe_or_trivial_patch(find: str, replace: str, original_token_count: int) -> str | None:
    if is_trivial_diff(find, replace):
        return "trivial_diff"
    if local_equivalence_norm(find) == local_equivalence_norm(replace):
        return "local_equivalence_diff"

    find_tokens = tokenize_with_spans(find)
    replace_tokens = tokenize_with_spans(replace)
    find_norms = [t["norm"] for t in find_tokens]
    if find_norms and all(t in {"uh", "um", "uhh", "umm", "er", "ah", "mm", "hmm"} for t in find_norms):
        return "find_is_only_filler"
    if len(find_tokens) == original_token_count and original_token_count <= 3:
        return "whole_short_segment_rewrite"
    if find.lower().startswith(("ms", "mr", "mrs")) and replace == replace.lower():
        return "style_or_title_formatting"
    if find.lower().startswith(("ms", "mr", "mrs")) and replace.lower().startswith(("miss", "mister", "misses")):
        return "style_or_title_formatting"
    low_content = {
        "yeah", "yep", "right", "okay", "ok", "alright", "all", "and", "that",
        "so", "well", "then", "there", "you", "know",
    }
    replace_norms = [t["norm"] for t in replace_tokens]
    if len(find_norms) <= 2 and find_norms and all(t in low_content for t in find_norms):
        return "low_content_discourse_marker"
    if len(replace_norms) <= 3 and replace_norms and all(t in low_content for t in replace_norms):
        return "low_content_discourse_marker"
    return None


def canonicalize_replacement(find: str, replace: str) -> str:
    """Preserve obvious numeric formatting from the canonical transcript."""
    if "%" not in find:
        return replace
    norm = local_equivalence_norm(replace)
    percent_values = {
        "hundred percent": "100%",
        "one hundred percent": "100%",
        "a hundred percent": "100%",
        "ten percent": "10%",
        "twenty percent": "20%",
        "fifty percent": "50%",
    }
    return percent_values.get(norm, replace)


def tokenize_with_spans(text: str) -> list[dict]:
    return [
        {"text": m.group(0), "norm": token_norm(m.group(0)), "start": m.start(), "end": m.end()}
        for m in TOKEN_RE.finditer(text)
    ]


def normalize_segments(raw: dict) -> list[dict]:
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


def candidate_indices_from_disagreements(path: Path | None, segments: list[dict]) -> set[int] | None:
    if path is None:
        return None
    raw = json.loads(path.read_text())
    out: set[int] = set()
    for item in raw.get("disagreements", []):
        for idx in item.get("a_segment_indices", []):
            out.add(int(idx))
        start = float(item.get("start") or 0)
        end = float(item.get("end") or start)
        for idx, seg in enumerate(segments):
            if overlap_seconds(start, end, float(seg.get("start") or 0), float(seg.get("end") or 0)) > 0:
                out.add(idx)
    return out


def extract_clip(src_audio: Path, out_dir: Path, start: float, end: float, pad: float) -> tuple[Path, float]:
    clip_start = max(0.0, start - pad)
    clip_duration = max(0.2, end - clip_start + pad)
    out_path = out_dir / f"clip_{int(start * 1000):08d}_{int(end * 1000):08d}.wav"
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
            f"{clip_duration:.3f}",
            "-ar",
            "16000",
            "-ac",
            "1",
            "-c:a",
            "pcm_s16le",
            str(out_path),
        ],
        check=True,
    )
    return out_path, clip_start


def vibevoice_generate(model, audio_path: Path, context: str | None, max_tokens: int) -> dict:
    kwargs = {
        "audio": str(audio_path),
        "max_tokens": max_tokens,
        "temperature": 0.0,
        "verbose": False,
    }
    if context:
        kwargs["context"] = context
    result = model.generate(**kwargs)
    if is_dataclass(result):
        return asdict(result)
    if isinstance(result, dict):
        return dict(result)
    if isinstance(result, str):
        return {"text": result}

    out: dict = {}
    for attr in ("text", "segments", "language", "prompt_tokens", "generation_tokens", "total_tokens"):
        value = getattr(result, attr, None)
        if value is not None:
            out[attr] = value
    return out


def overlap_seconds(a_start: float, a_end: float, b_start: float, b_end: float) -> float:
    return max(0.0, min(a_end, b_end) - max(a_start, b_start))


def relisten_text_for_segment(local_segments: list[dict], clip_start: float, seg_start: float, seg_end: float) -> str:
    rel_start = seg_start - clip_start
    rel_end = seg_end - clip_start
    selected: list[str] = []
    for local in local_segments:
        ls = float(local.get("start") or 0)
        le = float(local.get("end") or 0)
        ov = overlap_seconds(rel_start, rel_end, ls, le)
        dur = max(0.001, le - ls)
        if ov >= 0.25 or ov / dur >= 0.35:
            selected.append((local.get("text") or "").strip())
    return " ".join(s for s in selected if s).strip()


def build_replacement_patches(original: str, relistened: str, max_find_words: int) -> list[dict]:
    original_tokens = tokenize_with_spans(original)
    relisten_tokens = tokenize_with_spans(relistened)
    if not original_tokens or not relisten_tokens:
        return []

    matcher = SequenceMatcher(
        a=[t["norm"] for t in original_tokens],
        b=[t["norm"] for t in relisten_tokens],
        autojunk=False,
    )
    patches: list[dict] = []
    for tag, i1, i2, j1, j2 in matcher.get_opcodes():
        if tag != "replace":
            continue
        find_tokens = original_tokens[i1:i2]
        repl_tokens = relisten_tokens[j1:j2]
        if not find_tokens or not repl_tokens:
            continue
        if len(find_tokens) > max_find_words:
            continue
        if len(repl_tokens) > max_find_words or len(repl_tokens) / max(1, len(find_tokens)) > 3.0:
            # VibeVoice sometimes emits a single broad local segment that
            # includes the neighboring turn. If the diff is at the edge of the
            # canonical segment, keep only the nearest replacement-sized phrase
            # instead of letting the extra context turn into a rewrite.
            n = len(find_tokens)
            if i2 == len(original_tokens):
                repl_tokens = repl_tokens[:n]
            elif i1 == 0:
                repl_tokens = repl_tokens[-n:]
            else:
                continue
        if len(repl_tokens) > max_find_words:
            continue
        find_start = find_tokens[0]["start"]
        find_end = find_tokens[-1]["end"]
        find = original[find_start:find_end]
        replace = canonicalize_replacement(find, " ".join(t["text"] for t in repl_tokens))
        reject_reason = unsafe_or_trivial_patch(find, replace, len(original_tokens))
        if reject_reason:
            continue
        ratio = len(repl_tokens) / max(1, len(find_tokens))
        if ratio < 0.33 or ratio > 3.0:
            continue
        patches.append({
            "find_start": find_start,
            "find_end": find_end,
            "find": find,
            "replace": replace,
            "find_words": len(find_tokens),
            "replace_words": len(repl_tokens),
        })
    return patches


def apply_patches(text: str, patches: list[dict]) -> str:
    out = text
    for patch in sorted(patches, key=lambda p: int(p["find_start"]), reverse=True):
        out = out[: patch["find_start"]] + patch["replace"] + out[patch["find_end"] :]
    return out


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--vibevoice-json", type=Path, required=True)
    parser.add_argument("--audio", type=Path, required=True)
    parser.add_argument("--model", type=Path, required=True)
    parser.add_argument("--out", type=Path, required=True)
    parser.add_argument("--audit-log", type=Path, required=True)
    parser.add_argument("--disagreements", type=Path, default=None)
    parser.add_argument("--context", default=None)
    parser.add_argument("--pad", type=float, default=0.8)
    parser.add_argument("--max-tokens", type=int, default=512)
    parser.add_argument("--max-find-words", type=int, default=4)
    parser.add_argument("--limit", type=int, default=0)
    args = parser.parse_args()

    raw = json.loads(args.vibevoice_json.read_text())
    original_segments = list(raw.get("segments") or [])
    normalized_segments = normalize_segments(raw)
    candidate_indices = candidate_indices_from_disagreements(args.disagreements, normalized_segments)

    selected_indices = []
    for idx, seg in enumerate(normalized_segments):
        if candidate_indices is not None and idx not in candidate_indices:
            continue
        if (seg.get("text") or "").strip().lower() in {"[music]", "[silence]"}:
            continue
        selected_indices.append(idx)
    if args.limit > 0:
        selected_indices = selected_indices[: args.limit]

    print(f"[v6] selected {len(selected_indices)} candidate segments")
    print(f"[v6] loading VibeVoice model from {args.model}")
    from mlx_audio.stt.utils import load

    load_start = time.time()
    model = load(str(args.model))
    load_seconds = time.time() - load_start
    print(f"[v6] model loaded in {load_seconds:.1f}s")

    work_dir = Path(tempfile.mkdtemp(prefix="phase_a_v6_relisten_"))
    new_segments = [dict(seg) for seg in original_segments]
    audit: list[dict] = []
    total_generate_seconds = 0.0

    for count, idx in enumerate(selected_indices, start=1):
        seg = normalized_segments[idx]
        text = seg["text"]
        clip, clip_start = extract_clip(args.audio, work_dir, seg["start"], seg["end"], args.pad)
        t0 = time.time()
        relisten_raw = vibevoice_generate(model, clip, args.context, args.max_tokens)
        generate_seconds = time.time() - t0
        total_generate_seconds += generate_seconds
        local_segments = normalize_segments(relisten_raw)
        relistened = relisten_text_for_segment(local_segments, clip_start, seg["start"], seg["end"])
        patches = build_replacement_patches(text, relistened, args.max_find_words)
        after = apply_patches(text, patches) if patches else text

        if patches:
            new_segments[idx]["original_text"] = new_segments[idx].get("original_text") or text
            new_segments[idx]["text"] = after
            new_segments[idx]["corrected_by"] = "local-vibevoice-relisten-v6"

        audit.append({
            "segment_index": idx,
            "start": seg["start"],
            "end": seg["end"],
            "before": text,
            "relisten_text": relistened,
            "patches": patches,
            "after": after,
            "applied": bool(patches),
            "generate_seconds": generate_seconds,
            "local_segments": local_segments,
        })
        print(f"[v6] {count:02d}/{len(selected_indices):02d} seg {idx}: {len(patches)} patch(es)")

    out_payload = dict(raw)
    out_payload["segments"] = new_segments
    args.out.write_text(json.dumps(out_payload, indent=2))
    args.audit_log.write_text(json.dumps({
        "model_load_seconds": load_seconds,
        "total_generate_seconds": total_generate_seconds,
        "candidate_segments": selected_indices,
        "applied_count": sum(1 for item in audit if item["applied"]),
        "audit": audit,
    }, indent=2))
    print(f"[v6] applied patches to {sum(1 for item in audit if item['applied'])} segment(s)")
    print(f"[v6] wrote {args.out}")
    print(f"[v6] audit log -> {args.audit_log}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
