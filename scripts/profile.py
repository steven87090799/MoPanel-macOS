#!/usr/bin/env python3
"""Measure native UI CPU/RSS with fixtures or an explicit read-only CI engine.

The two modes produce separate evidence. No cleanup, uninstall, optimization,
slimming, updater, or interactive command is permitted by the real-mode app.
"""
import argparse
import datetime
import hashlib
import json
import math
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


def prepare_real_manifest(directory, mode, cli):
    """Create only our own fresh, flat corpus; never accept a user's scan root."""
    if mode not in ("idle", "monitor", "scan"):
        raise ValueError("Unknown real benchmark mode")
    directory = directory.resolve(strict=True)
    cli = cli.resolve(strict=True)
    for name in ("home", "tmp", "corpus"):
        (directory / name).mkdir(mode=0o700)
    if mode == "scan":
        payload = (b"MoPanel disposable read-only benchmark corpus\n" * 100)[:4096]
        assert len(payload) == 4096
        for index in range(5000):
            name = f"{index:05d} corpus 繁體中文 '{index}' $().bin"
            (directory / "corpus" / name).write_bytes(payload)
    report = directory / (mode + ".json")
    manifest = {"schema_version": 1, "mode": mode,
                "created_at_epoch": time.time(), "session_root": str(directory),
                "cli_path": str(cli), "cli_sha256": hashlib.sha256(cli.read_bytes()).hexdigest(),
                "home_path": str(directory / "home"), "tmp_path": str(directory / "tmp"),
                "corpus_path": str(directory / "corpus"), "report_path": str(report)}
    manifest_path = directory / ("manifest-" + mode + ".json")
    manifest_path.write_text(json.dumps(manifest, indent=2) + "\n")
    manifest_path.chmod(0o600)
    return manifest_path, manifest


def validate_evidence(evidence, mode, real_manifest=None):
    if evidence.get("mode") != mode or evidence.get("completed") is not True:
        raise RuntimeError(f"{mode} did not finish its requested workload: {evidence}")
    if real_manifest is None:
        if evidence.get("fixture_only") is not True:
            raise RuntimeError("Fixture benchmark selected a real engine")
        return
    if evidence.get("fixture_only") is not False or evidence.get("read_only_enforced") is not True:
        raise RuntimeError("Real benchmark did not prove read-only engine isolation")
    for key in ("cli_path", "corpus_path"):
        if evidence.get(key) != real_manifest[key]:
            raise RuntimeError(f"Real benchmark changed its declared {key}")
    if not evidence.get("cli_version") or not evidence.get("cli_fingerprint"):
        raise RuntimeError("Real benchmark did not identify its engine")
    receipt_path = pathlib.Path(real_manifest["cli_path"]).parent / "MOPANEL_CI_SOURCE.json"
    receipt = json.loads(receipt_path.read_text())
    if (receipt.get("official_binaries_verified") is not True
            or evidence.get("cli_source_tag") != receipt.get("tag")
            or evidence.get("cli_source_commit") != receipt.get("commit")):
        raise RuntimeError("Real benchmark engine provenance does not match the prepared source")
    if mode == "idle" and evidence.get("watch_samples") != 0:
        raise RuntimeError("Idle benchmark unexpectedly collected watch samples")
    if mode == "monitor" and evidence.get("watch_samples", 0) < 3:
        raise RuntimeError("Monitor benchmark did not collect sustained real metrics")
    if mode == "scan":
        if (evidence.get("corpus_file_count") != 5000
                or evidence.get("corpus_logical_bytes") != 5000 * 4096
                or evidence.get("scans", 0) < 1):
            raise RuntimeError("Real scan did not measure the declared disposable corpus")
        intervals = evidence.get("scan_intervals", [])
        if not intervals or any(interval.get("scan_status") != "complete"
                                or interval.get("entry_count") != 5000
                                for interval in intervals):
            raise RuntimeError("Real corpus scans did not all produce complete official results")


def workload_samples(samples, evidence, mode, real=False):
    started = evidence.get("started_at_epoch")
    duration = evidence.get("duration_seconds")
    if not all(isinstance(value, (int, float)) and math.isfinite(value)
               for value in (started, duration)) or duration < 5:
        raise RuntimeError(f"{mode} did not identify its actual workload interval")
    selected = [sample for sample in samples if started + 2 <= sample["observed_at_epoch"] <= started + duration
                and sample["process_count"] > 0 and sample["rss_bytes"] > 0]
    if real and mode == "scan":
        intervals = evidence["scan_intervals"]
        selected = [sample for sample in selected if any(
            interval["start_epoch"] <= sample["observed_at_epoch"] <= interval["end_epoch"]
            for interval in intervals)]
    if len(selected) < 5:
        raise RuntimeError(f"{mode} did not provide enough active post-warmup samples")
    return selected


def run_mode(executable, mode, directory, real_cli=None):
    report_path = directory / (mode + ".json")
    log_path = directory / (mode + ".log")
    environment = dict(os.environ)
    environment.pop("MOPANEL_GITHUB_TOKEN", None)
    environment["MOPANEL_BENCHMARK_REPORT"] = str(report_path)
    manifest = None
    arguments = [str(executable), "--benchmark", mode]
    if real_cli is None:
        environment["MOPANEL_TEST_MODE"] = "1"
    else:
        environment.pop("MOPANEL_TEST_MODE", None)
        manifest_path, manifest = prepare_real_manifest(directory, mode, real_cli)
        environment["MOPANEL_AUDIT_CLI"] = manifest["cli_path"]
        environment["MOPANEL_BENCHMARK_MANIFEST"] = str(manifest_path)
        arguments = [str(executable), "--benchmark-real", mode]
    samples = []
    with log_path.open("w") as log:
        process = subprocess.Popen(arguments, env=environment, stdout=log, stderr=log)
        started = time.monotonic()
        try:
            while process.poll() is None:
                elapsed = time.monotonic() - started
                if elapsed > (90 if real_cli is not None else 45):
                    raise TimeoutError(f"{mode} benchmark did not finish")
                if elapsed >= 2:
                    sample = process_tree(process.pid)
                    sample["elapsed_seconds"] = round(elapsed, 3)
                    sample["observed_at_epoch"] = time.time()
                    samples.append(sample)
                time.sleep(0.5)
        finally:
            if process.poll() is None:
                process.terminate()
                try:
                    process.wait(timeout=3)
                except subprocess.TimeoutExpired:
                    process.kill()
                    process.wait(timeout=3)
    if not report_path.is_file():
        raise RuntimeError(f"{mode} exited {process.returncode} without evidence: "
                           + log_path.read_text(errors="replace")[-6000:])
    evidence = json.loads(report_path.read_text())
    if process.returncode != 0:
        raise RuntimeError(f"{mode} exited {process.returncode}: {evidence}; "
                           + log_path.read_text(errors="replace")[-3000:])
    validate_evidence(evidence, mode, manifest)
    selected = workload_samples(samples, evidence, mode, real_cli is not None)
    return {"mode": mode, "sample_interval_seconds": 0.5, "warmup_seconds": 2,
            "sample_filter": "actual phase, excluding warmup and shutdown; real scans additionally require an active official scan interval",
            "cpu_mean_percent": round(statistics.mean(x["cpu_percent"] for x in selected), 3),
            "cpu_peak_percent": max(x["cpu_percent"] for x in selected),
            "rss_mean_bytes": round(statistics.mean(x["rss_bytes"] for x in selected)),
            "rss_peak_bytes": max(x["rss_bytes"] for x in selected),
            "max_process_count": max(x["process_count"] for x in selected),
            "samples": selected, "observed_phase_samples": len(samples), "app_evidence": evidence}


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("app", type=pathlib.Path)
    parser.add_argument("--output", required=True, type=pathlib.Path)
    parser.add_argument("--real-cli", type=pathlib.Path,
                        help="Explicit verified CI engine; never an installed user CLI")
    args = parser.parse_args()
    executable = args.app.resolve() / "Contents/MacOS/MoPanel"
    if platform.system() != "Darwin" or not executable.is_file():
        parser.error("A compiled macOS bundle and macOS host are required")
    real_cli = args.real_cli.resolve(strict=True) if args.real_cli else None
    modes = []
    if real_cli is not None:
        if os.environ.get("CI") != "true" or os.environ.get("GITHUB_ACTIONS") != "true":
            parser.error("Real-engine benchmarks require the explicit isolated GitHub CI environment")
        runner_value = os.environ.get("RUNNER_TEMP")
        if not runner_value:
            parser.error("RUNNER_TEMP is required for a disposable benchmark session")
        runner_temp = pathlib.Path(runner_value).resolve(strict=True)
        configured = os.environ.get("MOPANEL_AUDIT_CLI")
        if (not configured or pathlib.Path(configured).resolve(strict=True) != real_cli
                or not real_cli.is_relative_to(runner_temp)):
            parser.error("Real CLI must match the prepared CI path inside RUNNER_TEMP")
        for mode in ("idle", "monitor", "scan"):
            with tempfile.TemporaryDirectory(prefix="mopanel-real-benchmark-", dir=runner_temp) as temporary:
                modes.append(run_mode(executable, mode, pathlib.Path(temporary).resolve(), real_cli))
    else:
        with tempfile.TemporaryDirectory(prefix="mopanel-profile-") as temporary:
            modes = [run_mode(executable, mode, pathlib.Path(temporary)) for mode in ("idle", "monitor", "scan")]
    result = {"recorded_at": datetime.datetime.now(datetime.timezone.utc).isoformat(),
              "host": platform.platform(), "architecture": platform.machine(),
              "method": "ps CPU/RSS samples of GUI plus all observed descendants",
              "fixture_only": real_cli is None, "read_only_enforced": real_cli is not None,
              "limitation": ("Official read-only CLI on a fresh 5000-file, 4096-byte/file flat corpus; repeated scans use warm OS filesystem caches. This is not cleanup or a representative full-disk workload. "
                             if real_cli is not None else "Synthetic fixtures measure GUI overhead, not real CLI workload costs. ")
                            + "CPU is ps lifetime-average percent; peaks are observed sample maxima, not Instruments traces.",
              "modes": modes}
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(result, indent=2) + "\n")
    print("Recorded official read-only CLI performance:" if real_cli is not None else "Recorded fixture UI performance:", args.output)


if __name__ == "__main__":
    main()
