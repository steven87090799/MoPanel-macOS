#!/usr/bin/env python3
"""Inventory the actual release bytes, not claims about unperformed tests."""
import datetime
import hashlib
import json
import os
import pathlib
import platform
import re
import subprocess
import sys

root = pathlib.Path(sys.argv[1]).resolve()
source_revision = os.environ.get("GITHUB_SHA")
if not source_revision or not re.fullmatch(r"[0-9a-fA-F]{40}", source_revision):
    try:
        source_revision = subprocess.run(
            ["git", "-C", str(pathlib.Path(__file__).resolve().parent.parent), "rev-parse", "HEAD"],
            check=True, capture_output=True, text=True, timeout=5).stdout.strip()
    except (OSError, subprocess.SubprocessError):
        source_revision = None
if source_revision is not None and not re.fullmatch(r"[0-9a-fA-F]{40}", source_revision):
    source_revision = None
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
    "source_revision": source_revision,
}
repository, run_id = os.environ.get("GITHUB_REPOSITORY"), os.environ.get("GITHUB_RUN_ID")
if (repository and re.fullmatch(r"[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+", repository)
        and run_id and re.fullmatch(r"[0-9]+", run_id)):
    manifest["workflow_run_url"] = f"https://github.com/{repository}/actions/runs/{run_id}"
(root / "BUILD_MANIFEST.json").write_text(json.dumps(manifest, indent=2) + "\n")
