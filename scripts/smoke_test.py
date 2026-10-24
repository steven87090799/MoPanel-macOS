#!/usr/bin/env python3
"""Launch the compiled native UI in explicit fixture-only smoke mode."""
import argparse
import json
import os
import pathlib
import subprocess
import tempfile
import time

parser = argparse.ArgumentParser()
parser.add_argument("app", type=pathlib.Path)
parser.add_argument("--output", required=True, type=pathlib.Path)
args = parser.parse_args()
executable = args.app.resolve() / "Contents/MacOS/MoPanel"
if not executable.is_file():
    parser.error("Compiled MoPanel executable is missing")
with tempfile.TemporaryDirectory(prefix="mopanel-smoke-") as temporary:
    report_path = pathlib.Path(temporary) / "ui.json"
    environment = dict(os.environ)
    environment["MOPANEL_SMOKE_REPORT"] = str(report_path)
    environment["MOPANEL_TEST_MODE"] = "1"
    start = time.monotonic()
    completed = subprocess.run([str(executable), "--smoke-test"], env=environment,
                               capture_output=True, timeout=45, check=False)
    if completed.returncode != 0:
        raise RuntimeError(f"UI smoke process failed: {completed.returncode}; "
                           + completed.stderr.decode(errors="replace")[-3000:])
    if not report_path.exists():
        raise RuntimeError("UI exited without writing smoke evidence")
    report = json.loads(report_path.read_text())
    for field in ("success", "window_created", "fixture_only"):
        if report.get(field) is not True:
            raise RuntimeError(f"UI smoke failed {field}: {report}")
    if report.get("checks", {}).get("fixture_resource_inside_app") is not True:
        raise RuntimeError("Installed resource resolution was not proven inside the App bundle")
    report["elapsed_seconds"] = round(time.monotonic() - start, 3)
    report["executable"] = "MoPanel.app/Contents/MacOS/MoPanel"
    report["process_exit_code"] = completed.returncode
    report["scope"] = "Native window and explicit safe fixture routes; not real cleanup acceptance."
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(report, indent=2, ensure_ascii=False) + "\n")
    print("PASS: native UI smoke evidence", args.output)
