#!/usr/bin/env python3
"""Convert `fluidaudiocli process --output` JSON to RTTM: fluid_json_to_rttm.py <json> <clip-id>."""
import json
import sys

doc = json.load(open(sys.argv[1]))
for s in doc["segments"]:
    start, end = s["startTimeSeconds"], s["endTimeSeconds"]
    print(f"SPEAKER {sys.argv[2]} 1 {start:.3f} {end - start:.3f} <NA> <NA> {s['speakerId']} <NA> <NA>")
