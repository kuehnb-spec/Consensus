#!/usr/bin/env python3
"""
Test the LLM-reconciliation hypothesis: feed two ASR transcripts to an LLM and
see whether its reasoned output beats every word-alignment strategy we've tried.

Uses Claude Sonnet as a stand-in for the app's local Qwen 8B — the task is small
enough (reading text and applying world knowledge) that if any reasonably capable
LLM gets it right, local Qwen should too. This is a proof-of-concept to decide
whether to commit engineering effort to the Swift integration.

Usage:
    ./llm_reconcile.py <project-json> <ground-truth-json>
"""

from __future__ import annotations

import argparse
import json
import re
import sys
from pathlib import Path

SCRIPT_DIR = Path(__file__).resolve().parent
sys.path.insert(0, str(SCRIPT_DIR))

from score import Turn, score as score_turns, load_hypothesis, write_markdown_report

try:
    import anthropic
except ImportError:
    print("error: anthropic sdk not installed", file=sys.stderr)
    sys.exit(1)


SYSTEM_PROMPT = """You are a precise transcription editor. You will receive two independent
transcripts of the same audio from different speech recognition engines. Your task is
to produce the single most accurate transcript by reasoning about content.

Rules:
  1. Both engines have errors. Use their agreement where possible; when they
     disagree, pick the option that makes sense in context.
  2. PRESERVE the speaker labels and rough segment boundaries from Engine A —
     its diarization has been validated. You may merge adjacent same-speaker
     segments if the text is continuous.
  3. Apply domain knowledge: recognize legal/professional terminology. Do NOT
     invent words that neither engine produced.
  4. If a segment is genuinely ambiguous after reasoning, output the text you
     think is most likely and prefix the segment's text with "[UNCERTAIN] ".
  5. Output STRICTLY valid JSON — an array of {"speaker", "start", "end", "text"}
     objects. No commentary before or after.

The content is a phone call between two speakers. Legal, business, and
arbitration terminology is plausible. Proper names mentioned: Brant Kuehn
(pronounced "Keen"), Marie Larsen, Anthony, Legalist, JAMS.
"""


def extract_pass_turns(project_path: Path, pass_kind: str) -> list[Turn]:
    doc = json.loads(project_path.read_text(encoding="utf-8"))
    mapping = doc.get("speakerMapping", {}).get("names", {})
    for p in doc["passes"]:
        if p.get("kind") == pass_kind:
            turns = []
            for s in p["result"]["segments"]:
                sid = s.get("speakerID", "UNKNOWN")
                turns.append(Turn(
                    speaker=mapping.get(sid, sid).upper(),
                    start=float(s.get("start", 0)),
                    end=float(s.get("end", 0)),
                    text=s.get("text", "").strip(),
                ))
            return turns
    raise ValueError(f"no {pass_kind} pass found")


def format_engine_a(turns: list[Turn]) -> str:
    lines = []
    for t in turns:
        lines.append(f"[{t.speaker} @ {t.start:.1f}s-{t.end:.1f}s]")
        lines.append(t.text)
        lines.append("")
    return "\n".join(lines)


def format_engine_b(turns: list[Turn]) -> str:
    """Engine B usually has no speaker labels — just flat text with timestamps."""
    lines = []
    for t in turns:
        lines.append(f"[{t.start:.1f}s] {t.text}")
    return "\n".join(lines)


def reconcile_with_claude(engine_a: list[Turn], engine_b: list[Turn],
                          model: str = "claude-sonnet-4-5-20250929") -> list[Turn]:
    client = anthropic.Anthropic()
    user_content = f"""ENGINE A (Parakeet v3, with speaker labels and timestamps):

{format_engine_a(engine_a)}

--- END ENGINE A ---

ENGINE B (Whisper Large v3, no speaker labels):

{format_engine_b(engine_b)}

--- END ENGINE B ---

Produce the reconciled transcript now as a JSON array."""

    message = client.messages.create(
        model=model,
        max_tokens=16000,
        system=SYSTEM_PROMPT,
        messages=[{"role": "user", "content": user_content}],
    )

    raw = "".join(block.text for block in message.content if block.type == "text")
    # Strip markdown fences if present
    raw = re.sub(r"^```(?:json)?\s*", "", raw.strip())
    raw = re.sub(r"\s*```$", "", raw)

    data = json.loads(raw)
    turns = []
    for row in data:
        turns.append(Turn(
            speaker=row["speaker"].upper(),
            start=float(row["start"]),
            end=float(row["end"]),
            text=row["text"],
        ))
    return turns


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("project", type=Path)
    parser.add_argument("ground_truth", type=Path)
    parser.add_argument("--model", default="claude-sonnet-4-5-20250929")
    parser.add_argument("--output-turns", type=Path, default=Path("/tmp/llm-reconciled-turns.json"))
    parser.add_argument("--output-report", type=Path, default=Path("/tmp/llm-reconciled.report.md"))
    args = parser.parse_args()

    print(f"Loading Engine A (standard) and Engine B (deepReviewComparison) from {args.project.name}...")
    a_turns = extract_pass_turns(args.project, "standard")
    b_turns = extract_pass_turns(args.project, "deepReviewComparison")
    print(f"  Engine A: {len(a_turns)} turns, {sum(len(t.text.split()) for t in a_turns)} words")
    print(f"  Engine B: {len(b_turns)} turns, {sum(len(t.text.split()) for t in b_turns)} words")

    print(f"Sending to {args.model}...")
    reconciled = reconcile_with_claude(a_turns, b_turns, args.model)
    print(f"  Reconciled: {len(reconciled)} turns, {sum(len(t.text.split()) for t in reconciled)} words")

    args.output_turns.write_text(json.dumps({
        "turns": [{"speaker": t.speaker, "start": t.start, "end": t.end, "text": t.text}
                  for t in reconciled]
    }, indent=2))

    ref_turns, _ = load_hypothesis(args.ground_truth, None)
    report = score_turns(reconciled, ref_turns,
                         hyp_label=f"LLM reconciliation via {args.model}",
                         gt_label=args.ground_truth.name)
    write_markdown_report(report, args.output_report)

    print()
    print("--- scores ---")
    print(f"  Plain WER:  {report.plain_wer*100:.2f}%")
    print(f"  cpWER:      {report.cp_wer*100:.2f}%")
    print(f"  DER:        {report.der*100:.2f}%  (miss={report.der_miss*100:.2f}%, fa={report.der_fa*100:.2f}%, spk_err={report.der_speaker_error*100:.2f}%)")
    print(f"  mid-sentence flips:   {report.mid_sentence_flips}")
    print(f"  hyp turns={report.hyp_turn_count}, gt turns={report.gt_turn_count}")
    print(f"Reconciled turns → {args.output_turns}")
    print(f"Detailed report  → {args.output_report}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
