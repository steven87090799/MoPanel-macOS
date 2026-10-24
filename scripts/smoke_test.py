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
args.output.parent.mkdir(parents=True, exist_ok=True)
screenshot_path = args.output.parent.resolve() / "smoke-window.png"
with tempfile.TemporaryDirectory(prefix="mopanel-smoke-") as temporary:
    report_path = pathlib.Path(temporary) / "ui.json"
    environment = dict(os.environ)
    environment["MOPANEL_SMOKE_REPORT"] = str(report_path)
    environment["MOPANEL_SMOKE_SCREENSHOT"] = str(screenshot_path)
    environment["MOPANEL_TEST_MODE"] = "1"
    start = time.monotonic()
    timed_out = False
    try:
        completed = subprocess.run([str(executable), "--smoke-test"], env=environment,
                                   capture_output=True, timeout=45, check=False)
        exit_code, stdout, stderr = completed.returncode, completed.stdout, completed.stderr
    except subprocess.TimeoutExpired as error:
        timed_out = True
        exit_code, stdout, stderr = None, error.stdout or b"", error.stderr or b""
    # Keep failure evidence before any validation raises or temporary cleanup.
    args.output.with_suffix(".stdout.log").write_bytes(stdout)
    args.output.with_suffix(".stderr.log").write_bytes(stderr)
    report = {"success": False, "evidence_missing": True}
    if report_path.exists():
        try:
            decoded = json.loads(report_path.read_text())
            if not isinstance(decoded, dict):
                raise ValueError("Smoke report is not a JSON object")
            report = decoded
        except (json.JSONDecodeError, ValueError) as error:
            report["invalid_report"] = str(error)
            args.output.with_suffix(".invalid-report.txt").write_bytes(report_path.read_bytes())
    report["elapsed_seconds"] = round(time.monotonic() - start, 3)
    report["executable"] = "MoPanel.app/Contents/MacOS/MoPanel"
    report["process_exit_code"] = exit_code
    report["timed_out"] = timed_out
    report["screenshot_available"] = screenshot_path.is_file() and screenshot_path.stat().st_size > 0
    report["scope"] = "Native window and explicit safe fixture routes; not real cleanup acceptance."
    args.output.write_text(json.dumps(report, indent=2, ensure_ascii=False) + "\n")
    if timed_out or exit_code != 0:
        raise RuntimeError(f"UI smoke process failed: exit={exit_code}, timeout={timed_out}; "
                           + json.dumps(report, ensure_ascii=False) + "; stderr="
                           + stderr.decode(errors="replace")[-3000:])
    for field in ("success", "window_created", "fixture_only"):
        if report.get(field) is not True:
            raise RuntimeError(f"UI smoke failed {field}: {report}")
    if report.get("checks", {}).get("fixture_resource_inside_app") is not True:
        raise RuntimeError("Installed resource resolution was not proven inside the App bundle")
    print("PASS: native UI smoke evidence", args.output)
