#!/usr/bin/env python3
"""Sample actual process CPU/RSS for safe fixture-based UI performance modes.

Measurements describe GUI and its mock CLI children, not full real-Mac Mole
cleanup performance. No real cleanup, uninstall, or slimming is triggered.
"""
import argparse
import datetime
import json
import os
import pathlib
import platform
import statistics
import subprocess
import tempfile
import time


def process_tree(root_pid):
    output = subprocess.check_output(["/bin/ps", "-axo", "pid=,ppid=,%cpu=,rss="], text=True)
    rows = {}
    for line in output.splitlines():
        fields = line.split()
        if len(fields) != 4:
            continue
        try:
            pid, parent = int(fields[0]), int(fields[1])
            rows[pid] = (parent, float(fields[2]), int(fields[3]))
        except ValueError:
            continue
    selected = {root_pid}
    while True:
        new = {pid for pid, row in rows.items() if row[0] in selected}
        if new <= selected:
            break
        selected |= new
    measured = [row for pid, row in rows.items() if pid in selected]
    return {"cpu_percent": round(sum(row[1] for row in measured), 3),
            "rss_bytes": sum(row[2] for row in measured) * 1024,
            "process_count": len(measured)}


def run_mode(executable, mode, directory):
    report_path = directory / (mode + ".json")
    environment = dict(os.environ)
    environment["MOPANEL_BENCHMARK_REPORT"] = str(report_path)
    environment["MOPANEL_TEST_MODE"] = "1"
    samples = []
    with (directory / (mode + ".log")).open("w") as log:
        process = subprocess.Popen([str(executable), "--benchmark", mode], env=environment,
                                   stdout=log, stderr=log)
        started = time.monotonic()
        try:
            while process.poll() is None:
                elapsed = time.monotonic() - started
                if elapsed > 30:
                    raise TimeoutError(f"{mode} fixture benchmark did not finish")
                # Exclude cold launch from steady measurements.
                if elapsed >= 2:
                    sample = process_tree(process.pid)
                    sample["elapsed_seconds"] = round(elapsed, 3)
                    sample["observed_at_epoch"] = time.time()
                    samples.append(sample)
                time.sleep(0.5)
            if process.returncode != 0:
                raise RuntimeError(f"{mode} exited with {process.returncode}")
        finally:
            if process.poll() is None:
                process.terminate()
                try:
                    process.wait(timeout=3)
                except subprocess.TimeoutExpired:
                    process.kill()
                    process.wait(timeout=3)
    if not report_path.is_file():
        raise RuntimeError(f"{mode} did not provide evidence")
    evidence = json.loads(report_path.read_text())
    if evidence.get("mode") != mode or evidence.get("fixture_only") is not True or evidence.get("completed") is not True:
        raise RuntimeError(f"{mode} safety/evidence mismatch: {evidence}")
    started_at = evidence.get("started_at_epoch")
    if not isinstance(started_at, (int, float)):
        raise RuntimeError(f"{mode} did not identify the workload start after CLI detection")
    # Exclude CLI discovery as well as launch, then two seconds of workload warmup.
    samples = [sample for sample in samples if sample["observed_at_epoch"] >= started_at + 2]
    if len(samples) < 5:
        raise RuntimeError(f"{mode} did not provide enough post-warmup samples")
    return {"mode": mode, "sample_interval_seconds": 0.5, "warmup_seconds": 2,
            "cpu_mean_percent": round(statistics.mean(x["cpu_percent"] for x in samples), 3),
            "cpu_peak_percent": max(x["cpu_percent"] for x in samples),
            "rss_mean_bytes": round(statistics.mean(x["rss_bytes"] for x in samples)),
            "rss_peak_bytes": max(x["rss_bytes"] for x in samples),
            "max_process_count": max(x["process_count"] for x in samples),
            "samples": samples, "app_evidence": evidence}


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("app", type=pathlib.Path)
    parser.add_argument("--output", required=True, type=pathlib.Path)
    args = parser.parse_args()
    executable = args.app.resolve() / "Contents/MacOS/MoPanel"
    if platform.system() != "Darwin" or not executable.is_file():
        parser.error("A compiled macOS bundle and macOS host are required")
    with tempfile.TemporaryDirectory(prefix="mopanel-profile-") as temporary:
        result = {"recorded_at": datetime.datetime.now(datetime.timezone.utc).isoformat(),
                  "host": platform.platform(), "architecture": platform.machine(),
                  "method": "ps CPU/RSS samples of GUI plus all observed descendants",
                  "fixture_only": True,
                  "limitation": "Synthetic fixtures measure GUI overhead, not real CLI workload costs. CPU is ps lifetime-average percent.",
                  "modes": [run_mode(executable, mode, pathlib.Path(temporary)) for mode in ("idle", "monitor", "scan")]}
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(result, indent=2) + "\n")
    print("Recorded fixture UI performance:", args.output)


if __name__ == "__main__":
    main()
