#!/usr/bin/env python3
"""Capture read-only launchctl contract samples on an isolated macOS CI runner.

This never invokes enable, disable, bootstrap, bootout, or another mutation.
Nonzero outcomes are retained as evidence instead of interpreted as success.
"""
import argparse
import datetime
import json
import os
import pathlib
import platform
import subprocess


def probe(arguments):
    timed_out = False
    try:
        completed = subprocess.run(["/bin/launchctl", *arguments], capture_output=True,
                                   timeout=10, check=False)
        code, stdout, stderr = completed.returncode, completed.stdout, completed.stderr
    except subprocess.TimeoutExpired as error:
        timed_out = True
        code, stdout, stderr = None, error.stdout or b"", error.stderr or b""
    limit = 1024 * 1024
    return {"executable": "/bin/launchctl", "arguments": arguments, "exit_code": code,
            "timed_out": timed_out, "stdout_bytes": len(stdout), "stderr_bytes": len(stderr),
            "truncated": len(stdout) > limit or len(stderr) > limit,
            "stdout": stdout[:limit].decode("utf-8", errors="replace"),
            "stderr": stderr[:limit].decode("utf-8", errors="replace")}


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--output", required=True, type=pathlib.Path)
    args = parser.parse_args()
    if platform.system() != "Darwin" or os.environ.get("GITHUB_ACTIONS") != "true":
        parser.error("This read-only platform probe is restricted to the macOS GitHub CI runner")
    domain = "gui/" + str(os.getuid())
    commands = [["help"], ["help", "print-disabled"], ["print-disabled", domain],
                ["print", domain + "/com.mopanel.nonexistent.fixture"]]
    result = {"recorded_at": datetime.datetime.now(datetime.timezone.utc).isoformat(),
              "host": platform.platform(), "architecture": platform.machine(),
              "scope": "Read-only launchctl output contracts; no BTM/private database access or changes",
              "mutations_executed": [], "commands": [probe(arguments) for arguments in commands]}
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(result, indent=2, ensure_ascii=False) + "\n")
    print("Recorded read-only launchctl contract samples:", args.output)


if __name__ == "__main__":
    main()
