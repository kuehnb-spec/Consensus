"""Inject controlled, audibly-detectable errors into a VibeVoice transcript.

The VibeVoice baseline on this audio is too clean to surface meaningful
review-pipeline behavior — there are very few wrong words for a reviewer to
catch, so a "0 corrections applied" result is consistent with both
"the reviewer is engaged and correctly says nothing's wrong" and
"the reviewer is rubber-stamping every input."

This tool fixes the ambiguity by deliberately corrupting N specific segments
with substitutions that are clearly audible mismatches between the candidate
text and the actual speech. Run Phase A on the output and the detection rate
becomes a calibrated signal:

    0/N detected at any threshold → reviewer is rubber-stamping (architecture fails).
    N/N detected at high threshold → reviewer engages (architecture works).

The `injected_index` field on each modified segment lets the scorer separate
true-positives (caught injection), false-negatives (missed injection),
true-negatives (correctly didn't flag a real segment), and false-positives
(wrongly flagged a real segment).
"""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path


# (segment_index, original_phrase, replacement_phrase, why_it's_audible)
INJECTIONS: list[tuple[int, str, str, str]] = [
    (1, "Brant Kuehn", "Bernard Cohen",
     "Different proper name; audio clearly enunciates 'Brant Kuehn'."),
    (2, "Marie", "Tracy",
     "Different proper name; audio clearly says 'Marie'."),
    (5, "mediation", "meditation",
     "One-letter swap that flips meaning entirely (legal mediation vs sitting silently)."),
    (8, "Virginia counsel", "Florida counsel",
     "Different state name in legal context; clearly audible."),
    (22, "100%", "10%",
     "Different number; audio clearly states one hundred percent."),
    (28, "JAMS", "AAA",
     "Different arbitration organization; abbreviations sound different."),
    (29, "different arbitrator", "different attorney",
     "Different professional role; words sound nothing alike."),
    (47, "funding", "lunch",
     "Substantive content swap; clearly different word."),
]


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--in", dest="in_path", type=Path, required=True,
                        help="Input VibeVoice JSON (canonical baseline transcript).")
    parser.add_argument("--out", type=Path, required=True,
                        help="Output corrupted JSON path.")
    parser.add_argument("--manifest", type=Path, required=True,
                        help="Side-car JSON listing the injections (for scoring).")
    args = parser.parse_args()

    raw = json.loads(args.in_path.read_text())
    segments = list(raw.get("segments") or [])

    manifest_records = []
    applied = 0
    skipped = []

    for idx, original, replacement, why in INJECTIONS:
        if idx >= len(segments):
            skipped.append((idx, "out of range"))
            continue
        seg = segments[idx]
        text = seg.get("text") or ""
        if original not in text:
            # Try case-insensitive
            lower_text = text.lower()
            lower_original = original.lower()
            if lower_original not in lower_text:
                skipped.append((idx, f"phrase {original!r} not found in segment"))
                continue
            # Re-find with original casing preserved minimally
            start = lower_text.index(lower_original)
            end = start + len(original)
            new_text = text[:start] + replacement + text[end:]
        else:
            new_text = text.replace(original, replacement, 1)
        manifest_records.append({
            "segment_index": idx,
            "start": seg.get("start"),
            "end": seg.get("end"),
            "original_phrase": original,
            "replacement_phrase": replacement,
            "why_audible": why,
            "original_text": text,
            "corrupted_text": new_text,
        })
        seg["text"] = new_text
        seg["injected_error"] = True
        seg["original_text"] = text
        applied += 1

    raw["segments"] = segments
    raw["injection_manifest"] = manifest_records
    raw["injection_applied"] = applied
    raw["injection_skipped"] = skipped
    args.out.write_text(json.dumps(raw, indent=2))
    args.manifest.write_text(json.dumps({
        "source": str(args.in_path),
        "injections": manifest_records,
        "skipped": skipped,
    }, indent=2))

    print(f"[inject] applied {applied} of {len(INJECTIONS)} injections")
    if skipped:
        print(f"[inject] skipped: {skipped}")
    print(f"[inject] wrote corrupted transcript -> {args.out}")
    print(f"[inject] wrote manifest -> {args.manifest}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
