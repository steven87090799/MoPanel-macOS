#!/usr/bin/env python3
"""Read-only acceptance of the installed official Mole command contract.

Only help/version/status/history and analysis of a temporary owned fixture run.
No clean, uninstall, optimize, purge, installer, slim, update or remove action.
"""
import argparse
import datetime
import hashlib
import json
import os
import pathlib
import re
import selectors
import signal
import subprocess
import tempfile
import time


def invoke(cli, arguments, timeout=30):
    process = subprocess.Popen([str(cli), *arguments], stdout=subprocess.PIPE,
                               stderr=subprocess.PIPE, start_new_session=True)
    try:
        stdout, stderr = process.communicate(timeout=timeout)
    except subprocess.TimeoutExpired:
        # A shell launcher may still own a Go helper. Bound the whole group.
        try:
            os.killpg(process.pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
        process.communicate(timeout=3)
        raise
    if process.returncode != 0:
        raise RuntimeError(f"Read-only command {arguments} failed: {process.returncode}: "
                           + stderr.decode(errors="replace")[-1500:])
    return stdout


def collect_watch_frames(process, timeout=60):
    """Bound even a truncated/no-newline stream; buffered readline can hang."""
    frames = []
    pending = bytearray()
    os.set_blocking(process.stdout.fileno(), False)
    with selectors.DefaultSelector() as selector:
        selector.register(process.stdout, selectors.EVENT_READ)
        deadline = time.monotonic() + timeout
        while len(frames) < 2 and time.monotonic() < deadline:
            if not selector.select(timeout=min(1, max(0, deadline - time.monotonic()))):
                continue
            try:
                chunk = os.read(process.stdout.fileno(), 65536)
            except BlockingIOError:
                continue
            if not chunk:
                break
            pending.extend(chunk)
            if len(pending) > 4 * 1024 * 1024:
                raise RuntimeError("Watch frame exceeded the probe's memory limit")
            while b"\n" in pending and len(frames) < 2:
                line, _, remainder = pending.partition(b"\n")
                pending = bytearray(remainder)
                if line.strip():
                    frames.append(json.loads(line))
    if len(frames) != 2 or not all(isinstance(frame, dict) and "collected_at" in frame for frame in frames):
        raise RuntimeError("Watch did not provide two complete NDJSON frames before its deadline")
    return frames


def check_help_contract(command, text, baseline):
    expected = set(re.findall(r"(?<![\w-])--[a-z][a-z0-9-]*", baseline.get(command, "")))
    if command == "uninstall":
        expected.discard("--whitelist")  # Upstream help explicitly says unsupported.
    observed = set(re.findall(r"(?<![\w-])--[a-z][a-z0-9-]*", text))
    missing = expected - observed
    if missing:
        raise RuntimeError(f"{command} help contract lost options: {', '.join(sorted(missing))}")
    return sorted(expected)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("cli", type=pathlib.Path)
    parser.add_argument("--output", required=True, type=pathlib.Path)
    args = parser.parse_args()
    cli = args.cli.expanduser().resolve(strict=True)
    baseline_path = pathlib.Path(__file__).resolve().parent.parent / "Tests/MoPanelCoreTests/Fixtures/help-contract.json"
    baseline_help = json.loads(baseline_path.read_text())
    result = {"recorded_at": datetime.datetime.now(datetime.timezone.utc).isoformat(),
              "scope": "Read-only CLI contract probe on an isolated macOS CI runner",
              "version": invoke(cli, ["--version"]).decode(errors="replace").strip(),
              "help": {}, "destructive_commands_executed": []}
    commands = [[], ["clean"], ["uninstall"], ["optimize"], ["analyze"], ["status"],
                ["purge"], ["installer"], ["slim"], ["history"], ["touchid"],
                ["completion"], ["update"], ["remove"]]
    for prefix in commands:
        data = invoke(cli, prefix + ["--help"])
        if not data.strip():
            raise RuntimeError(f"Empty help output for {prefix}")
        command = " ".join(prefix) or "mo"
        checked_options = check_help_contract(command, data.decode(errors="replace"), baseline_help)
        result["help"][command] = {
            "bytes": len(data), "sha256": hashlib.sha256(data).hexdigest(), "checked_options": checked_options}
    status = json.loads(invoke(cli, ["status", "--json"], timeout=60))
    for key in ("collected_at", "health_score", "cpu", "memory", "disk_io", "network"):
        if key not in status:
            raise RuntimeError("Missing status field: " + key)
    result["status_keys"] = sorted(status)
    history = json.loads(invoke(cli, ["history", "--json", "--limit", "20"]))
    if not isinstance(history, dict) or not {"sessions", "deletions"} <= history.keys():
        raise RuntimeError("History JSON contract mismatch")
    result["history_keys"] = sorted(history)
    applications = json.loads(invoke(cli, ["uninstall", "--list"], timeout=180))
    if not isinstance(applications, list) or any(not isinstance(app, dict) or
            not {"name", "path", "uninstall_name", "source"} <= app.keys() for app in applications):
        raise RuntimeError("Read-only application list contract mismatch")
    result["application_inventory_count"] = len(applications)
    with tempfile.TemporaryDirectory(prefix="mopanel-analysis-") as temporary:
        root = pathlib.Path(temporary)
        (root / "繁體中文 👋 $() ; quote' \".txt").write_text("safe fixture\n")
        (root / "nested").mkdir()
        (root / "nested" / "bytes.bin").write_bytes(b"x" * 8192)
        analysis = json.loads(invoke(cli, ["analyze", "--json", str(root)], timeout=60))
        if analysis.get("scan_status") not in ("complete", "partial", "unavailable"):
            raise RuntimeError("Missing or unknown analyze scan status")
        if analysis.get("path") != str(root) or not isinstance(analysis.get("entries"), list):
            raise RuntimeError("Analyze path/entries contract mismatch")
        result["analysis"] = {"scan_status": analysis["scan_status"],
                              "entries": len(analysis["entries"]),
                              "special_filename_present": any("繁體中文" in e.get("name", "") for e in analysis["entries"])}
        if not result["analysis"]["special_filename_present"]:
            raise RuntimeError("Special filename was lost in analyze JSON")
    # Observe two NDJSON frames from one watch process and close it explicitly.
    process = subprocess.Popen([str(cli), "status", "--json", "--watch", "--interval", "2s"],
                               stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, start_new_session=True)
    try:
        frames = collect_watch_frames(process)
        result["watch_frames"] = len(frames)
    finally:
        if process.stdout:
            process.stdout.close()
        try:
            os.killpg(process.pid, signal.SIGTERM)
        except ProcessLookupError:
            pass
        try:
            process.wait(timeout=3)
        except subprocess.TimeoutExpired:
            try:
                os.killpg(process.pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
            process.wait(timeout=3)
    result["passed"] = True
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(result, indent=2, ensure_ascii=False) + "\n")
    print("PASS: read-only Mole contract probe", args.output)


if __name__ == "__main__":
    main()
