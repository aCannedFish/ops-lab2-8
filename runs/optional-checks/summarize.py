#!/usr/bin/env python3
"""Recompute O3 alert transitions from raw files; run from the repository root."""
import datetime
import hashlib
import json
from pathlib import Path

root = Path("runs")
checks = root / "optional-checks"


transitions = []
last = None
for line in (checks / "alerts.jsonl").read_text().splitlines():
    entry = json.loads(line)
    alerts = entry["response"]["data"]["alerts"]
    state = ",".join(sorted({alert["state"] for alert in alerts})) or "inactive"
    if state != last:
        stamp = datetime.datetime.fromisoformat(entry["time"]).astimezone(
            datetime.timezone(datetime.timedelta(hours=8))
        )
        transitions.append({"time": stamp.isoformat(), "state": state, "alerts": alerts})
        last = state

prediction_hash = (checks / "prediction.sha256").read_text().split()[0]
if hashlib.sha256((checks / "prediction.md").read_bytes()).hexdigest() != prediction_hash:
    raise ValueError("Pre-measurement prediction snapshot checksum mismatch")

source = json.loads((checks / "source-sha256.json").read_text())
for name, expected in source["sha256"].items():
    actual = hashlib.sha256(Path(name).read_bytes().replace(b"\r\n", b"\n")).hexdigest()
    if actual != expected:
        raise ValueError(f"Local source differs from remote measured source: {name}")

print(json.dumps({"o3_transitions": transitions,
                  "source_files_verified": len(source["sha256"])}, indent=2))
