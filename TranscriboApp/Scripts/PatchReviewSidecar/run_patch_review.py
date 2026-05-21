"""Consensus patch-centered Deep Review sidecar.

This is the app-side productionization of the May 1 v6/v8 architecture:

1. Treat VibeVoice as the canonical transcript.
2. Use a second ASR transcript only as a heatmap/candidate generator.
3. Re-listen to disputed local windows with VibeVoice and apply only small
   deterministic word-replacement patches.
4. Verify remaining candidate patches with masked cloze audio grounding: the
   disputed phrase is replaced with a blank and the verifier may choose only
   between the current phrase and the second-opinion phrase.

The sidecar never writes a free-form transcript. It returns the canonical
segments plus exact string patches and an audit log.
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
from dataclasses import asdict, is_dataclass
from difflib import SequenceMatcher
from pathlib import Path

try:
    os.setpgrp()
except OSError:
    pass

os.environ.setdefault("TQDM_DISABLE", "1")


TOKEN_RE = re.compile(r"[A-Za-z0-9]+(?:'[A-Za-z0-9]+)?%?")
FILLER_TOKENS = {
    "um", "uh", "uhh", "umm", "ah", "ahh", "er", "erm", "mm", "mmm",
    "hmm", "hmmm",
}
LOW_CONTENT_TOKENS = {
    "yeah", "yep", "right", "okay", "ok", "alright", "all", "and", "that",
    "so", "well", "then", "there", "you", "know",
}

MASKED_PROMPT = """You are filling one blank in a transcript using the audio.

Transcript with blank:
"{masked_segment}"

Allowed fills:
1. "{find}"
2. "{replace}"

Listen to the audio and choose the fill that is actually spoken. Use the surrounding words only as anchors. Reply with exactly one JSON object:
{{"fill":"one allowed fill exactly","confidence":0.0,"reason":"..."}}
"""


def emit_progress(message: str, fraction: float | None = None, **extra) -> None:
    payload = {"message": message}
    if fraction is not None:
        payload["fraction"] = max(0.0, min(1.0, fraction))
    payload.update(extra)
    print(json.dumps(payload), file=sys.stderr, flush=True)


def token_norm(token: str) -> str:
    s = token.lower().strip()
    if s.endswith("%"):
        s = s[:-1]
    return s.replace("'", "")


def tokenize_with_spans(text: str) -> list[dict]:
    return [
        {"text": m.group(0), "norm": token_norm(m.group(0)), "start": m.start(), "end": m.end()}
        for m in TOKEN_RE.finditer(text)
    ]


def normalize_for_comparison(text: str) -> str:
    s = text.lower()
    s = s.replace("n't", " not")
    s = s.replace("'ll", " will")
    s = s.replace("'re", " are")
    s = s.replace("'ve", " have")
    s = s.replace("'m", " am")
    s = s.replace("'d", " would")
    s = s.replace("'s", " is")
    s = s.replace("'", "")
    s = s.replace("%", " percent ")
    s = re.sub(r"[^\w\s]", " ", s)
    number_words = {
        "zero": "0", "one": "1", "two": "2", "three": "3", "four": "4",
        "five": "5", "six": "6", "seven": "7", "eight": "8", "nine": "9",
        "ten": "10", "eleven": "11", "twelve": "12", "thirteen": "13",
        "fourteen": "14", "fifteen": "15", "sixteen": "16", "seventeen": "17",
        "eighteen": "18", "nineteen": "19", "twenty": "20", "thirty": "30",
        "forty": "40", "fifty": "50", "sixty": "60", "seventy": "70",
        "eighty": "80", "ninety": "90", "hundred": "100",
    }
    tokens = [number_words.get(t, t) for t in s.split()]
    return " ".join(t for t in tokens if t and t not in FILLER_TOKENS)


def is_trivial_diff(find: str, replace: str) -> bool:
    return normalize_for_comparison(find) == normalize_for_comparison(replace)


def local_equivalence_norm(text: str) -> str:
    aliases = {
        "cause": "because",
        "cuz": "because",
        "cos": "because",
        "ms": "miss",
        "mrs": "misses",
    }
    tokens = [token_norm(t["text"]) for t in tokenize_with_spans(text)]
    return " ".join(aliases.get(t, t) for t in tokens if t)


def unsafe_or_trivial_patch(find: str, replace: str, original_token_count: int) -> str | None:
    if is_trivial_diff(find, replace):
        return "trivial_diff"
    if local_equivalence_norm(find) == local_equivalence_norm(replace):
        return "local_equivalence_diff"
    find_tokens = tokenize_with_spans(find)
    replace_tokens = tokenize_with_spans(replace)
    find_norms = [t["norm"] for t in find_tokens]
    replace_norms = [t["norm"] for t in replace_tokens]
    if find_norms and all(t in FILLER_TOKENS for t in find_norms):
        return "find_is_only_filler"
    if len(find_tokens) == original_token_count and original_token_count <= 3:
        return "whole_short_segment_rewrite"
    if find.lower().startswith(("ms", "mr", "mrs")) and replace == replace.lower():
        return "style_or_title_formatting"
    if find.lower().startswith(("ms", "mr", "mrs")) and replace.lower().startswith(("miss", "mister", "misses")):
        return "style_or_title_formatting"
    if len(find_norms) <= 2 and find_norms and all(t in LOW_CONTENT_TOKENS for t in find_norms):
        return "low_content_discourse_marker"
    if len(replace_norms) <= 3 and replace_norms and all(t in LOW_CONTENT_TOKENS for t in replace_norms):
        return "low_content_discourse_marker"
    return None


def canonicalize_replacement(find: str, replace: str) -> str:
    if "%" not in find:
        return replace
    percent_values = {
        "hundred percent": "100%",
        "one hundred percent": "100%",
        "a hundred percent": "100%",
        "ten percent": "10%",
        "twenty percent": "20%",
        "fifty percent": "50%",
    }
    return percent_values.get(local_equivalence_norm(replace), replace)


def normalize_items(raw: dict) -> list[dict]:
    items = raw.get("segments") or raw.get("turns") or raw.get("transcription") or []
    out: list[dict] = []
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


def concatenate_segments(segments: list[dict]) -> tuple[str, list[dict]]:
    parts: list[str] = []
    offsets: list[dict] = []
    pos = 0
    for idx, seg in enumerate(segments):
        if parts:
            parts.append(" ")
            pos += 1
        text = seg["text"]
        start = pos
        parts.append(text)
        pos += len(text)
        offsets.append({
            "index": idx,
            "start_char": start,
            "end_char": pos,
            "audio_start": float(seg["start"]),
            "audio_end": float(seg["end"]),
            "text": text,
        })
    return "".join(parts), offsets


def segment_for_span(offsets: list[dict], start: int, end: int) -> dict | None:
    for seg in offsets:
        if seg["start_char"] <= start and end <= seg["end_char"]:
            return seg
    return None


def normalized_terms(raw: str) -> set[str]:
    return {
        " ".join(t["norm"] for t in tokenize_with_spans(term))
        for term in raw.split(",")
        if term.strip()
    }


def generate_candidates(
    canonical_segments: list[dict],
    opinion_segments: list[dict],
    max_words: int,
    protected_terms: set[str],
) -> list[dict]:
    canonical_text, offsets = concatenate_segments(canonical_segments)
    opinion_text = " ".join(item["text"] for item in opinion_segments)
    canonical_tokens = tokenize_with_spans(canonical_text)
    opinion_tokens = tokenize_with_spans(opinion_text)
    matcher = SequenceMatcher(
        a=[t["norm"] for t in canonical_tokens],
        b=[t["norm"] for t in opinion_tokens],
        autojunk=False,
    )
    candidates: list[dict] = []
    seen: set[tuple[int, int, int, str]] = set()
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
        reject = unsafe_or_trivial_patch(find, replace, len(tokenize_with_spans(seg["text"])))
        if reject:
            continue
        key = (seg["index"], find_start - seg["start_char"], find_end - seg["start_char"], replace_norm)
        if key in seen:
            continue
        seen.add(key)
        candidates.append({
            "segment_index": seg["index"],
            "segment_text": seg["text"],
            "find_start": find_start - seg["start_char"],
            "find_end": find_end - seg["start_char"],
            "find": find,
            "replace": replace,
            "audio_start": seg["audio_start"],
            "audio_end": seg["audio_end"],
        })
    return candidates


def apply_patches(text: str, patches: list[dict]) -> str:
    out = text
    for patch in sorted(patches, key=lambda p: int(p["find_start"]), reverse=True):
        out = out[: patch["find_start"]] + patch["replace"] + out[patch["find_end"] :]
    return out


def extract_clip(ffmpeg: Path, src_audio: Path, out_dir: Path, start: float, end: float, pad: float, prefix: str) -> tuple[Path, float]:
    clip_start = max(0.0, start - pad)
    duration = max(0.2, end - clip_start + pad)
    out = out_dir / f"{prefix}_{int(start * 1000):08d}_{int(end * 1000):08d}.wav"
    subprocess.run(
        [
            str(ffmpeg),
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
    return out, clip_start


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
        reject = unsafe_or_trivial_patch(find, replace, len(original_tokens))
        if reject:
            continue
        ratio = len(repl_tokens) / max(1, len(find_tokens))
        if ratio < 0.33 or ratio > 3.0:
            continue
        patches.append({
            "find_start": find_start,
            "find_end": find_end,
            "find": find,
            "replace": replace,
        })
    return patches


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
        if isinstance(obj, dict) and ("fill" in obj or "decision" in obj):
            return obj
    return {"fill": "", "confidence": 0.0, "reason": "no_valid_json", "raw": raw[-800:]}


def mask_segment_text(segment_text: str, find_start: int, find_end: int) -> str:
    return segment_text[:find_start].rstrip() + " ____ " + segment_text[find_end:].lstrip()


def call_masked_verifier(
    llama_cli: Path,
    gguf: Path,
    mmproj: Path,
    audio_clip: Path,
    prompt: str,
    timeout: float,
) -> tuple[dict, float, str]:
    args = [
        str(llama_cli),
        "-m", str(gguf),
        "--mmproj", str(mmproj),
        "--audio", str(audio_clip),
        "-p", prompt,
        "-n", "256",
        "--temp", "0.0",
        "-ngl", "99",
        "--ctx-size", "4096",
        "--jinja",
    ]
    t0 = time.time()
    try:
        proc = subprocess.run(args, capture_output=True, check=False, timeout=timeout)
    except subprocess.TimeoutExpired:
        return {"fill": "", "confidence": 0.0, "reason": "timeout"}, time.time() - t0, ""
    elapsed = time.time() - t0
    stdout = proc.stdout.decode("utf-8", errors="replace") if proc.stdout else ""
    stderr = proc.stderr.decode("utf-8", errors="replace") if proc.stderr else ""
    raw = stdout + "\n" + stderr
    if proc.returncode != 0:
        return {"fill": "", "confidence": 0.0, "reason": f"error_code_{proc.returncode}", "raw": raw[-800:]}, elapsed, raw
    return extract_json(raw), elapsed, raw


def run_local_relisten(
    *,
    segments: list[dict],
    candidate_indices: set[int],
    audio: Path,
    model_path: Path,
    ffmpeg: Path,
    context: str | None,
    work_dir: Path,
    pad: float,
    max_tokens: int,
    max_find_words: int,
) -> tuple[list[dict], list[dict], dict]:
    if not candidate_indices:
        return segments, [], {"candidate_segments": [], "applied_count": 0, "total_generate_seconds": 0.0}

    emit_progress("Loading VibeVoice for local re-listen", 0.42, stage="v6_load")
    from mlx_audio.stt.utils import load

    t0 = time.time()
    model = load(str(model_path))
    load_seconds = time.time() - t0

    new_segments = [dict(seg) for seg in segments]
    events: list[dict] = []
    total_generate_seconds = 0.0
    selected = sorted(idx for idx in candidate_indices if 0 <= idx < len(segments))

    for count, idx in enumerate(selected, start=1):
        seg = new_segments[idx]
        text = seg["text"]
        base_fraction = 0.44 + (count - 1) / max(1, len(selected)) * 0.22
        emit_progress(
            f"Local re-listen {count}/{len(selected)}",
            base_fraction,
            stage="v6_relisten",
            segment_index=idx,
        )
        clip, clip_start = extract_clip(ffmpeg, audio, work_dir, float(seg["start"]), float(seg["end"]), pad, "relisten")
        gen_start = time.time()
        relisten_raw = vibevoice_generate(model, clip, context, max_tokens)
        generate_seconds = time.time() - gen_start
        total_generate_seconds += generate_seconds
        local_segments = normalize_items(relisten_raw)
        relistened = relisten_text_for_segment(local_segments, clip_start, float(seg["start"]), float(seg["end"]))
        patches = build_replacement_patches(text, relistened, max_find_words)
        if not patches:
            continue
        after = apply_patches(text, patches)
        new_segments[idx]["text"] = after
        for patch in patches:
            events.append({
                "segment_index": idx,
                "stage": "v6_local_relisten",
                "source": "VibeVoice local re-listen",
                "find": patch["find"],
                "replace": patch["replace"],
                "before_segment": text,
                "after_segment": after,
                "confidence": None,
                "reason": f"Local VibeVoice re-listen heard: {relistened}",
            })

    stats = {
        "candidate_segments": selected,
        "applied_count": len(events),
        "model_load_seconds": load_seconds,
        "total_generate_seconds": total_generate_seconds,
    }
    return new_segments, events, stats


def run_masked_cloze(
    *,
    segments: list[dict],
    opinion_segments: list[dict],
    audio: Path,
    gguf: Path,
    mmproj: Path,
    llama_cli: Path,
    ffmpeg: Path,
    protected_terms: set[str],
    work_dir: Path,
    max_words: int,
    confidence_threshold: float,
    pad: float,
    timeout: float,
    limit: int,
) -> tuple[list[dict], list[dict], dict]:
    candidates = generate_candidates(segments, opinion_segments, max_words, protected_terms)
    if limit > 0:
        candidates = candidates[:limit]
    emit_progress(f"Generated {len(candidates)} masked-cloze candidates", 0.68, stage="v8_candidates")

    new_segments = [dict(seg) for seg in segments]
    accepted_by_segment: dict[int, list[dict]] = {}
    audit: list[dict] = []
    events: list[dict] = []
    total_seconds = 0.0

    for idx, cand in enumerate(candidates, start=1):
        frac = 0.70 + (idx - 1) / max(1, len(candidates)) * 0.27
        emit_progress(
            f"Masked cloze {idx}/{len(candidates)}",
            frac,
            stage="v8_verify",
            segment_index=cand["segment_index"],
        )
        clip, _ = extract_clip(ffmpeg, audio, work_dir, cand["audio_start"], cand["audio_end"], pad, "verify")
        prompt = MASKED_PROMPT.format(
            masked_segment=mask_segment_text(cand["segment_text"], cand["find_start"], cand["find_end"]).replace('"', '\\"'),
            find=cand["find"].replace('"', '\\"'),
            replace=cand["replace"].replace('"', '\\"'),
        )
        parsed, elapsed, raw = call_masked_verifier(llama_cli, gguf, mmproj, clip, prompt, timeout)
        total_seconds += elapsed
        confidence = float(parsed.get("confidence") or 0.0)
        fill = str(parsed.get("fill") or "").strip()
        if fill == cand["replace"]:
            decision = "apply_patch"
        elif fill == cand["find"]:
            decision = "keep_current"
        else:
            decision = "keep_current"
            parsed["reason"] = f"fill_not_allowed_or_not_exact: {fill!r}; " + str(parsed.get("reason") or "")
        applied = decision == "apply_patch" and confidence >= confidence_threshold
        if applied:
            accepted_by_segment.setdefault(cand["segment_index"], []).append({
                "find_start": cand["find_start"],
                "find_end": cand["find_end"],
                "find": cand["find"],
                "replace": cand["replace"],
                "confidence": confidence,
                "reason": parsed.get("reason"),
            })
        audit.append({
            "candidate_index": idx - 1,
            "candidate": cand,
            "decision": decision,
            "confidence": confidence,
            "reason": parsed.get("reason"),
            "fill": parsed.get("fill"),
            "applied": applied,
            "elapsed_seconds": elapsed,
            "raw_tail": raw[-1000:],
        })

    for seg_idx, patches in accepted_by_segment.items():
        before = new_segments[seg_idx]["text"]
        after = apply_patches(before, patches)
        new_segments[seg_idx]["text"] = after
        for patch in patches:
            events.append({
                "segment_index": seg_idx,
                "stage": "v8_masked_cloze",
                "source": "Masked cloze audio verifier",
                "find": patch["find"],
                "replace": patch["replace"],
                "before_segment": before,
                "after_segment": after,
                "confidence": patch.get("confidence"),
                "reason": patch.get("reason"),
            })

    stats = {
        "candidate_count": len(candidates),
        "applied_count": len(events),
        "total_seconds": total_seconds,
        "audit": audit,
    }
    return new_segments, events, stats


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--vibevoice-json", type=Path, required=True)
    parser.add_argument("--opinion-json", type=Path, required=True)
    parser.add_argument("--audio", type=Path, required=True)
    parser.add_argument("--vibevoice-model", type=Path, required=True)
    parser.add_argument("--gguf", type=Path, required=True)
    parser.add_argument("--mmproj", type=Path, required=True)
    parser.add_argument("--out", type=Path, required=True)
    parser.add_argument("--audit-log", type=Path, required=True)
    parser.add_argument("--context", default=None)
    parser.add_argument("--protected-terms", default="")
    parser.add_argument("--max-words", type=int, default=5)
    parser.add_argument("--confidence-threshold", type=float, default=0.85)
    parser.add_argument("--relisten-pad", type=float, default=0.8)
    parser.add_argument("--verify-pad", type=float, default=1.2)
    parser.add_argument("--relisten-max-tokens", type=int, default=512)
    parser.add_argument("--max-find-words", type=int, default=4)
    parser.add_argument("--limit", type=int, default=0)
    parser.add_argument("--timeout", type=float, default=420.0)
    parser.add_argument("--ffmpeg", type=Path, default=Path("/opt/homebrew/bin/ffmpeg"))
    parser.add_argument("--llama-mtmd-cli", type=Path, default=Path("/opt/homebrew/bin/llama-mtmd-cli"))
    args = parser.parse_args()

    for label, path in {
        "audio": args.audio,
        "vibevoice model": args.vibevoice_model,
        "verifier model": args.gguf,
        "verifier mmproj": args.mmproj,
        "ffmpeg": args.ffmpeg,
        "llama-mtmd-cli": args.llama_mtmd_cli,
    }.items():
        if not path.exists():
            emit_progress(f"Missing {label}: {path}", stage="error")
            return 2

    start = time.time()
    emit_progress("Loading transcript inputs", 0.02, stage="load")
    canonical_raw = json.loads(args.vibevoice_json.read_text())
    opinion_raw = json.loads(args.opinion_json.read_text())
    canonical_segments = normalize_items(canonical_raw)
    opinion_segments = normalize_items(opinion_raw)
    protected = normalized_terms(args.protected_terms)

    if not canonical_segments:
        emit_progress("No canonical segments to review", stage="error")
        return 3

    initial_candidates = generate_candidates(canonical_segments, opinion_segments, args.max_words, protected)
    candidate_indices = {int(c["segment_index"]) for c in initial_candidates}
    emit_progress(
        f"Found {len(candidate_indices)} candidate segments",
        0.35,
        stage="candidate_heatmap",
        candidate_segments=len(candidate_indices),
    )

    work_dir = Path(tempfile.mkdtemp(prefix="consensus_patch_review_"))
    applied_events: list[dict] = []

    relistened_segments, v6_events, v6_stats = run_local_relisten(
        segments=canonical_segments,
        candidate_indices=candidate_indices,
        audio=args.audio,
        model_path=args.vibevoice_model,
        ffmpeg=args.ffmpeg,
        context=args.context,
        work_dir=work_dir,
        pad=args.relisten_pad,
        max_tokens=args.relisten_max_tokens,
        max_find_words=args.max_find_words,
    )
    applied_events.extend(v6_events)

    verified_segments, v8_events, v8_stats = run_masked_cloze(
        segments=relistened_segments,
        opinion_segments=opinion_segments,
        audio=args.audio,
        gguf=args.gguf,
        mmproj=args.mmproj,
        llama_cli=args.llama_mtmd_cli,
        ffmpeg=args.ffmpeg,
        protected_terms=protected,
        work_dir=work_dir,
        max_words=args.max_words,
        confidence_threshold=args.confidence_threshold,
        pad=args.verify_pad,
        timeout=args.timeout,
        limit=args.limit,
    )
    applied_events.extend(v8_events)

    out_payload = dict(canonical_raw)
    out_payload["segments"] = verified_segments
    out_payload["engine"] = "Consensus Patch Review"
    args.out.write_text(json.dumps(out_payload, indent=2))

    audit = {
        "architecture": "tool_constrained_patch_editor_v1",
        "description": "VibeVoice canonical transcript plus second-ASR heatmap, VibeVoice local re-listen, and masked-cloze audio verification.",
        "candidate_segment_count": len(candidate_indices),
        "applied_count": len(applied_events),
        "applied_patches": applied_events,
        "v6_local_relisten": v6_stats,
        "v8_masked_cloze": v8_stats,
        "protected_terms": sorted(protected),
        "wall_clock_seconds": time.time() - start,
    }
    args.audit_log.write_text(json.dumps(audit, indent=2))
    emit_progress(f"Applied {len(applied_events)} patch(es)", 1.0, stage="done", applied_count=len(applied_events))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
