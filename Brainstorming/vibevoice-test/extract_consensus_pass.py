"""Extract a Consensus pass from a project.json into the hypothesis format used by score.py."""
import json
import sys
from pathlib import Path

if len(sys.argv) < 3:
    print("Usage: extract_consensus_pass.py <project.json> <pass_index> [out.json]")
    sys.exit(1)

project_path = Path(sys.argv[1])
idx = int(sys.argv[2])
out_path = Path(sys.argv[3]) if len(sys.argv) > 3 else None

d = json.loads(project_path.read_text())
ps = d["passes"][idx]
segs = ps["result"]["segments"]
turns = []
for s in segs:
    turns.append({
        "speaker": s["speakerID"],
        "start": float(s["start"]),
        "end": float(s["end"]),
        "text": s["text"],
    })
hyp = {
    "engineName": ps.get("engineName"),
    "diarizationEngineName": ps.get("diarizationEngineName"),
    "modelName": ps.get("modelName"),
    "turns": turns,
}
out_text = json.dumps(hyp, indent=2)
if out_path:
    out_path.write_text(out_text)
    print(f"Wrote {len(turns)} turns to {out_path}")
else:
    print(out_text)
