#!/usr/bin/env python3
"""Compare two CLI runs of the same clip, ignoring the intended schema changes
(2.0 -> 2.1): segment count, speaker sequence, text, segment times and word
strings must match; confidence, word_timing, provenance, witness and disputes
are ignored.  diff_runs.py OLD.consensus.json NEW.consensus.json"""
import json, sys

a, b = (json.load(open(p)) for p in sys.argv[1:3])
sa, sb = a["segments"], b["segments"]
issues = []
if len(sa) != len(sb):
    issues.append(f"segment count {len(sa)} -> {len(sb)}")
for i, (x, y) in enumerate(zip(sa, sb)):
    for k in ("speaker", "text", "start", "end"):
        if x.get(k) != y.get(k):
            issues.append(f"seg {i} {k} differs")
    if [w["word"] for w in x.get("words") or []] != [w["word"] for w in y.get("words") or []]:
        issues.append(f"seg {i} words differ")
    if [(w["start"], w["end"]) for w in x.get("words") or []] != [(w["start"], w["end"]) for w in y.get("words") or []]:
        issues.append(f"seg {i} word times differ")
if a.get("speakers") != b.get("speakers"):
    issues.append("speaker list differs")
print(f"{sys.argv[2].split('/')[-1]}: {len(sb)} segments, "
      + ("identical words, speakers and times" if not issues else f"{len(issues)} differences: " + "; ".join(issues[:8])))
