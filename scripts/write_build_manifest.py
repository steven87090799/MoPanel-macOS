#!/usr/bin/env python3
"""Inventory the actual release bytes, not claims about unperformed tests."""
import datetime
import hashlib
import json
import pathlib
import platform
import subprocess
import sys

root = pathlib.Path(sys.argv[1]).resolve()
items = []
for path in sorted(root.rglob("*")):
    if path.is_file() and path.name != "BUILD_MANIFEST.json":
        items.append({"path": path.relative_to(root).as_posix(), "size": path.stat().st_size,
                      "sha256": hashlib.sha256(path.read_bytes()).hexdigest()})
manifest = {
    "generated_at": datetime.datetime.now(datetime.timezone.utc).isoformat(),
    "host_os": platform.platform(), "host_architecture": platform.machine(),
    "signature": "ad-hoc", "notarized": False,
    "mole_bundled": False, "minimum_macos": "27.0", "files": items,
    "validation_evidence": "Reports/",
}
(root / "BUILD_MANIFEST.json").write_text(json.dumps(manifest, indent=2) + "\n")
