#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Bounded, CI-only diagnosis of an already failed release smoke test.

Only a disposable copy receives get-task-allow. It never becomes a release
artifact or overrides the failed acceptance result. No host security changes.
"""
import hashlib
import json
import os
import pathlib
import platform
import plistlib
import subprocess
import tempfile
import time

MAX_SECONDS = 60
PROTECTED_FILES = ("Contents/MacOS/MoPanel", "Contents/_CodeSignature/CodeResources",
                   "Contents/Helpers/MoPanelGuardian", "Contents/Helpers/MoPanelEditor")


def original_hashes(app):
    result = {}
    for relative in PROTECTED_FILES:
        path = app / relative
        if path.is_symlink() or not path.is_file() or path.stat().st_size > 512 * 1024 * 1024:
            raise RuntimeError("Expected a bounded regular release file")
        with path.open("rb") as stream:
            result[relative] = hashlib.file_digest(stream, "sha256").hexdigest()
    return result


def run_lldb(guardian, executable, environment, directory, seconds):
    log_path = directory / "smoke-debug-lldb.log"
    arguments = [str(guardian), "--capture", "--timeout-ms", str(max(1000, int((seconds - 4) * 1000))),
                 "--", "/usr/bin/xcrun", "lldb", "--no-lldbinit", "--batch",
                 "-o", "settings set target.disable-aslr false",
                 "-o", "process handle SIGPIPE --stop true --notify true --pass true",
                 "-o", "run",
                 "-o", "thread backtrace -c 128 all",
                 "-k", "thread backtrace -c 128 all", "--", str(executable), "--smoke-test"]
    with log_path.open("wb") as log:
        process = subprocess.Popen(arguments, env=environment, stdin=subprocess.PIPE,
                                   stdout=log, stderr=subprocess.STDOUT)
        try:
            code = process.wait(timeout=seconds)
            return {"status": "debugger_exited", "exit_code": code, "guardian_reaped": True,
                    "log": log_path.name, "guardian_timeout_ms": int(arguments[3])}
        except subprocess.TimeoutExpired:
            # EOF tells the already bounded guardian to cancel its exact tree.
            process.stdin.close()
            try:
                process.wait(timeout=3)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait(timeout=1)
            return {"status": "debugger_deadline_exceeded", "exit_code": process.returncode,
                    "guardian_reaped": True, "log": log_path.name}
        finally:
            if process.stdin and not process.stdin.closed:
                process.stdin.close()


def diagnose(app, directory, environment, *, failed):
    result = {"attempted": False, "original_smoke_still_failed": failed,
              "maximum_seconds": MAX_SECONDS, "debug_copy_distributed": False,
              "host_security_settings_changed": False}
    if (not failed or platform.system() != "Darwin" or environment.get("CI") != "true"
            or environment.get("GITHUB_ACTIONS") != "true"):
        return {**result, "status": "not_an_explicit_failed_macos_ci_smoke"}
    started = time.monotonic()
    deadline = started + MAX_SECONDS
    original = app.resolve(strict=True)
    runner_temp_value = environment.get("RUNNER_TEMP")
    if not runner_temp_value or not pathlib.Path(runner_temp_value).is_dir() or original.name != "MoPanel.app":
        return {**result, "status": "required_ci_paths_unavailable"}
    result.update(attempted=True)
    before = None
    def budget(maximum=8, reserve=5):
        remaining = min(maximum, deadline - time.monotonic() - reserve)
        if remaining <= 0:
            raise TimeoutError("Diagnostic budget exhausted")
        return remaining
    try:
        before = original_hashes(original)
        result["original_sha256_before"] = before
        with tempfile.TemporaryDirectory(prefix="mopanel-debug-only-", dir=runner_temp_value) as temporary:
            root = pathlib.Path(temporary)
            copy = root / "MoPanel.app"
            subprocess.run(["/usr/bin/ditto", str(original), str(copy)], check=True,
                           stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL,
                           stderr=subprocess.PIPE, timeout=budget())
            if original_hashes(copy) != before:
                raise RuntimeError("Debug copy bytes differ before signing")
            if any(os.path.samefile(original / name, copy / name) for name in PROTECTED_FILES):
                raise RuntimeError("Debug copy unexpectedly shares original file inodes")
            entitlement = root / "debug-only.plist"
            entitlement.write_bytes(plistlib.dumps({"com.apple.security.get-task-allow": True}))
            with (directory / "smoke-debug-sign.log").open("wb") as log:
                signed = subprocess.run(["/usr/bin/codesign", "--force", "--sign", "-", "--options", "runtime",
                                         "--entitlements", str(entitlement), str(copy)],
                                        stdin=subprocess.DEVNULL, stdout=log, stderr=subprocess.STDOUT,
                                        timeout=budget(), check=False)
            result["copy_sign_exit_code"] = signed.returncode
            if signed.returncode:
                raise RuntimeError("Debug-copy signing failed; no debugger was launched")
            debug_environment = dict(environment)
            debug_environment.pop("MOPANEL_SMOKE_SCREENSHOT", None)
            debug_environment.pop("MOPANEL_GITHUB_TOKEN", None)
            debug_environment["MOPANEL_SMOKE_REPORT"] = str(root / "debug-app-report.json")
            debug_environment["MOPANEL_TEST_MODE"] = "1"
            result["debugger"] = run_lldb(original / "Contents/Helpers/MoPanelGuardian",
                                          copy / "Contents/MacOS/MoPanel", debug_environment,
                                          directory, budget(43, reserve=5))
            result["status"] = "diagnostic_finished_not_acceptance"
            app_report = root / "debug-app-report.json"
            if app_report.is_file() and app_report.stat().st_size <= 1024 * 1024:
                (directory / "smoke-debug-app-report.json").write_bytes(app_report.read_bytes())
    except Exception as error:
        result.update(status="diagnostic_failed", error_type=type(error).__name__, error=str(error)[:1000])
    finally:
        try:
            after = original_hashes(original)
            result["original_sha256_after"] = after
            result["original_files_unchanged"] = before is not None and before == after
        except Exception as error:
            result["original_files_unchanged"] = False
            result["verification_error_type"] = type(error).__name__
        result["elapsed_seconds"] = round(time.monotonic() - started, 3)
        (directory / "smoke-debug-diagnostic.json").write_text(json.dumps(result, indent=2) + "\n")
    return result
