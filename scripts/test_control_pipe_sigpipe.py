#!/usr/bin/env python3
"""Compile actual transport into disposable SIG_DFL children; never invokes Mole.

Normal: python3 scripts/test_control_pipe_sigpipe.py --output result.json
Historical source: add --source /tmp/ManagedProcess-before.swift --expect-sigpipe
Use --swiftc /absolute/path/to/swiftc when Swift is not on PATH.
"""
import argparse
import hashlib
import json
import pathlib
import shutil
import signal
import subprocess
import tempfile


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--swiftc", default=shutil.which("swiftc"))
    parser.add_argument("--source", type=pathlib.Path)
    parser.add_argument("--output", type=pathlib.Path)
    parser.add_argument("--expect-sigpipe", action="store_true")
    args = parser.parse_args()
    root = pathlib.Path(__file__).resolve().parent.parent
    source = (args.source or root / "Sources/MoPanelProcess/ManagedProcess.swift").resolve()
    fixture = root / "scripts/fixtures/ControlPipeSIGPIPEProbe.swift"
    if not args.swiftc or not source.is_file():
        raise SystemExit("An installed Swift compiler and actual ManagedProcess.swift source are required")
    results = []
    with tempfile.TemporaryDirectory(prefix="mopanel-sigpipe-probe-") as directory:
        temporary = pathlib.Path(directory)
        helper = temporary / "fixture-guardian"
        helper.write_text("#!/bin/sh\nexec 0<&-\nprintf 'CLOSED_READY\\n'\n/bin/sleep 0.3\nexit 0\n")
        helper.chmod(0o700)
        binary = temporary / "closed-pipe-probe"
        command = [args.swiftc, "-swift-version", "5", "-parse-as-library",
                   "-module-cache-path", str(temporary / "module-cache")]
        if not args.expect_sigpipe:
            command += ["-D", "MOPANEL_SAFE_CONTROL_WRITER"]
        command += [str(source), str(fixture), "-o", str(binary)]
        compiled = subprocess.run(command, text=True, capture_output=True, timeout=60)
        if compiled.returncode:
            raise SystemExit("Probe compilation failed:\n" + compiled.stderr[-16000:])
        modes = ["resize", "send", "cancel"] + ([] if args.expect_sigpipe else ["pending"])
        for mode in modes:
            completed = subprocess.run([str(binary), str(helper), mode], capture_output=True, text=True, timeout=5)
            if mode == "pending":
                passed = completed.returncode == 0 and "PENDING_SIGNAL_PRESERVED MASK_RESTORED" in completed.stdout
            else:
                expected = -signal.SIGPIPE if args.expect_sigpipe else 0
                passed = completed.returncode == expected and "CONTROL_CLOSED_WHILE_RUNNING=true" in completed.stdout
                if not args.expect_sigpipe:
                    passed = passed and "PROBE_SURVIVED" in completed.stdout
            results.append({"mode": mode, "exit": completed.returncode, "passed": passed,
                            "stdout": completed.stdout[-16000:], "stderr": completed.stderr[-16000:]})
    report = {"scope": "Actual ManagedProcess.swift compiled into disposable children with SIGPIPE=SIG_DFL; a private helper closes stdin before reporting READY and remains alive. No installed Mole or user data.",
              "source_sha256": hashlib.sha256(source.read_bytes()).hexdigest(),
              "probe_sha256": hashlib.sha256(fixture.read_bytes()).hexdigest(),
              "expect_sigpipe": args.expect_sigpipe, "all_passed": all(item["passed"] for item in results), "results": results}
    encoded = json.dumps(report, indent=2) + "\n"
    print(encoded, end="")
    if args.output:
        args.output.write_text(encoded)
    return 0 if report["all_passed"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
