#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Launch the compiled native UI in explicit fixture-only smoke mode."""
import argparse
import json
import os
import pathlib
import platform
import subprocess
import tempfile
import time
from crash_evidence import collect_owned_crash
from debug_smoke_failure import diagnose

SMOKE_DEADLINE_SECONDS = 45


def needs_startup_debug(outcome, report):
    """A complete logical-failure report does not benefit from a second launch."""
    code = outcome.get("process_exit_code")
    if outcome.get("timed_out") is True or (type(code) is int and code < 0):
        return True
    if report.get("evidence_missing") is True or "invalid_report" in report:
        return True
    if any(type(report.get(field)) is not bool for field in ("success", "window_created", "fixture_only")):
        return True
    checks, errors = report.get("checks"), report.get("errors")
    if (not isinstance(checks, dict) or not checks
            or any(type(value) is not bool for value in checks.values())
            or not isinstance(errors, list) or any(not isinstance(value, str) for value in errors)):
        return True
    return False


def bounded_tail(path, limit=3000):
    try:
        with path.open("rb") as stream:
            stream.seek(0, os.SEEK_END)
            stream.seek(max(0, stream.tell() - limit))
            return stream.read(limit).decode("utf-8", errors="replace")
    except OSError:
        return ""


def sample_owned_app(process, directory):
    """Read a bounded stack sample of our still-running child; never elevate."""
    result = {"attempted": False, "owner": "the exact smoke child process",
              "changes_to_security_settings": False}
    if platform.system() != "Darwin":
        return {**result, "reason": "sample_requires_macos"}
    if process.poll() is not None:
        return {**result, "reason": "smoke_child_already_exited"}
    output = directory / "smoke-sample.txt"
    command_log = directory / "smoke-sample.command.log"
    arguments = ["/usr/bin/sample", str(process.pid), "2", "1", "-file", str(output)]
    result.update(attempted=True, child_pid=process.pid, sampling_seconds=2,
                  diagnostic_timeout_seconds=8, output_file=output.name, command_log=command_log.name)
    try:
        with command_log.open("wb") as stream:
            completed = subprocess.run(arguments, stdin=subprocess.DEVNULL, stdout=stream,
                                       stderr=subprocess.STDOUT, timeout=8, check=False)
        result.update(exit_code=completed.returncode,
                      status="captured" if completed.returncode == 0 and output.is_file() else "sample_command_failed")
    except subprocess.TimeoutExpired:
        result.update(status="sample_command_timed_out")
    except OSError as error:
        result.update(status="sample_unavailable", error_type=type(error).__name__, errno=error.errno)
    result["output_available"] = output.is_file() and output.stat().st_size > 0
    return result


def launch_smoke(arguments, environment, stdout_path, stderr_path,
                 deadline=SMOKE_DEADLINE_SECONDS, diagnostic=sample_owned_app):
    """Persist progress while running; diagnostics never extend a failed deadline."""
    result = {"process_exit_code": None, "timed_out": False,
              "sample_diagnostic": {"attempted": False, "reason": "not_needed"}}
    started_at_epoch = time.time()
    with stdout_path.open("wb") as stdout, stderr_path.open("wb") as stderr:
        try:
            process = subprocess.Popen(arguments, env=environment, stdin=subprocess.DEVNULL,
                                       stdout=stdout, stderr=stderr)
        except OSError as error:
            result["launch_error"] = {"type": type(error).__name__, "errno": error.errno}
            return result
        try:
            process.wait(timeout=deadline)
        except subprocess.TimeoutExpired:
            result["timed_out"] = True
            # Preserve the timeout if sampling fails, is denied, or the app exits
            # while being sampled. Diagnostics never grant additional test time.
            try:
                result["sample_diagnostic"] = diagnostic(process, stdout_path.parent)
            except Exception as error:
                result["sample_diagnostic"] = {"attempted": True, "status": "diagnostic_exception",
                                               "error_type": type(error).__name__}
            if process.poll() is None:
                process.kill()  # Only this Popen child; never broad kill/pkill.
            try:
                process.wait(timeout=5)
                result["child_reaped_after_timeout"] = True
            except subprocess.TimeoutExpired:
                result["child_reaped_after_timeout"] = False
        result["process_exit_code"] = process.poll()
        result["child_pid"] = process.pid
    if result["process_exit_code"] is not None and result["process_exit_code"] < 0 and not result["timed_out"]:
        try:
            result["crash_report"] = collect_owned_crash(process.pid, started_at_epoch, arguments[0], stdout_path.parent)
        except Exception as error:
            result["crash_report"] = {"attempted": True, "status": "diagnostic_exception", "error_type": type(error).__name__}
    return result


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("app", type=pathlib.Path)
    parser.add_argument("--output", required=True, type=pathlib.Path)
    args = parser.parse_args()
    executable = args.app.resolve() / "Contents/MacOS/MoPanel"
    if not executable.is_file():
        parser.error("Compiled MoPanel executable is missing")
    args.output.parent.mkdir(parents=True, exist_ok=True)
    screenshot_path = args.output.parent.resolve() / "smoke-window.png"
    stdout_path = args.output.with_suffix(".stdout.log")
    stderr_path = args.output.with_suffix(".stderr.log")
    with tempfile.TemporaryDirectory(prefix="mopanel-smoke-") as temporary:
        report_path = pathlib.Path(temporary) / "ui.json"
        environment = dict(os.environ)
        environment["MOPANEL_SMOKE_REPORT"] = str(report_path)
        environment["MOPANEL_SMOKE_SCREENSHOT"] = str(screenshot_path)
        environment["MOPANEL_TEST_MODE"] = "1"
        start = time.monotonic()
        outcome = launch_smoke([str(executable), "--smoke-test"], environment, stdout_path, stderr_path)
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
        report["app_reported_success"] = report.get("success")
        report.update(outcome)
        if outcome["timed_out"] or outcome["process_exit_code"] != 0:
            report["success"] = False
        report["elapsed_seconds"] = round(time.monotonic() - start, 3)
        report["test_deadline_seconds"] = SMOKE_DEADLINE_SECONDS
        report["diagnostic_time_is_not_extra_test_time"] = True
        report["executable"] = "MoPanel.app/Contents/MacOS/MoPanel"
        report["screenshot_available"] = screenshot_path.is_file() and screenshot_path.stat().st_size > 0
        scopes = ["Native window, route-selection survival and adapter smoke with the explicit bundled CLI fixture"]
        if report.get("system_tools"):
            scopes.append("safe IOPM assertion and own overlay-window lifecycle probes")
        if report.get("startup_mock"):
            scopes.append("private Startup control-flow mock")
        if report.get("native_ui"):
            scopes.append("identified own-process AppKit accessibility button actions")
        report["scope"] = "; ".join(scopes) + ". See individual checks for success or failure."
        report["scope_limits"] = "Route selection does not prove every page rendered correctly. No complete physical-input or VoiceOver/TCC acceptance, real cleanup, app upgrade, launchctl mutation, disk ejection, screen-input interception or hardware-control validation."
        args.output.write_text(json.dumps(report, indent=2, ensure_ascii=False) + "\n")
        failed = (outcome["timed_out"] or outcome["process_exit_code"] != 0
                  or any(report.get(field) is not True for field in ("success", "window_created", "fixture_only"))
                  or report.get("checks", {}).get("fixture_resource_inside_app") is not True)
        if failed:
            if needs_startup_debug(outcome, report):
                try:
                    report["debug_copy_diagnostic"] = diagnose(args.app, args.output.parent.resolve(), environment, failed=True)
                except Exception as error:
                    report["debug_copy_diagnostic"] = {"status": "diagnostic_exception", "error_type": type(error).__name__}
            else:
                report["debug_copy_diagnostic"] = {"attempted": False,
                    "status": "complete_app_failure_evidence_available", "original_smoke_still_failed": True}
            report["success"] = False
            args.output.write_text(json.dumps(report, indent=2, ensure_ascii=False) + "\n")
        if outcome["timed_out"] or outcome["process_exit_code"] != 0:
            raise RuntimeError(f"UI smoke process failed: exit={outcome['process_exit_code']}, timeout={outcome['timed_out']}; "
                               + json.dumps(report, ensure_ascii=False) + "; stderr=" + bounded_tail(stderr_path))
        for field in ("success", "window_created", "fixture_only"):
            if report.get(field) is not True:
                raise RuntimeError(f"UI smoke failed {field}: {report}")
        if report.get("checks", {}).get("fixture_resource_inside_app") is not True:
            raise RuntimeError("Installed resource resolution was not proven inside the App bundle")
        print("PASS: native UI smoke evidence", args.output)


if __name__ == "__main__":
    main()
