#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Real isolated children plus mocked Mac sampler; no macOS UI or Mole runs."""
import os
import json
import pathlib
import signal
import subprocess
import sys
import tempfile
import types
import unittest
from unittest import mock
import smoke_test


class SmokeDriverTests(unittest.TestCase):
    @staticmethod
    def logical_failure():
        return {"success": False, "window_created": True, "fixture_only": True,
                "checks": {"fixture_resource_inside_app": True, "accessibility": False},
                "errors": ["Synthetic inaccessible control"]}

    def test_complete_logical_failure_skips_debug_copy_only(self):
        report = self.logical_failure()
        self.assertFalse(smoke_test.needs_startup_debug({"process_exit_code": 1, "timed_out": False}, report))
        self.assertFalse(report["success"])
        self.assertFalse(report["checks"]["accessibility"])

    def test_signal_timeout_missing_and_invalid_reports_still_need_debug(self):
        report = self.logical_failure()
        for outcome in ({"process_exit_code": -11, "timed_out": False}, {"process_exit_code": 0, "timed_out": True}):
            self.assertTrue(smoke_test.needs_startup_debug(outcome, report))
        outcome = {"process_exit_code": 1, "timed_out": False}
        for invalid in ({}, {**report, "evidence_missing": True}, {**report, "invalid_report": ""},
                        {**report, "checks": {"fixture_resource_inside_app": "false"}}):
            self.assertTrue(smoke_test.needs_startup_debug(outcome, invalid))

    def test_main_still_fails_and_saves_failure_when_debug_copy_is_skipped(self):
        with tempfile.TemporaryDirectory(prefix="mopanel-smoke-driver-") as temporary:
            root = pathlib.Path(temporary); app = root / "MoPanel.app"
            executable = app / "Contents/MacOS/MoPanel"; executable.parent.mkdir(parents=True)
            executable.write_bytes(b"not executed; synthetic metadata only")
            output = root / "reports/smoke.json"
            def launch(arguments, environment, stdout, stderr):
                pathlib.Path(environment["MOPANEL_SMOKE_REPORT"]).write_text(json.dumps(self.logical_failure()))
                return {"process_exit_code": 1, "timed_out": False}
            with mock.patch.object(sys, "argv", ["smoke_test.py", str(app), "--output", str(output)]), \
                 mock.patch.object(smoke_test, "launch_smoke", side_effect=launch), \
                 mock.patch.object(smoke_test, "diagnose") as diagnose:
                with self.assertRaisesRegex(RuntimeError, "UI smoke process failed"):
                    smoke_test.main()
            diagnose.assert_not_called()
            saved = json.loads(output.read_text())
            self.assertFalse(saved["success"])
            self.assertEqual(saved["process_exit_code"], 1)
            self.assertTrue(saved["debug_copy_diagnostic"]["original_smoke_still_failed"])

    def test_progress_survives_timeout_and_diagnostic_error_cannot_mask_it(self):
        with tempfile.TemporaryDirectory(prefix="mopanel-smoke-driver-") as temporary:
            root = pathlib.Path(temporary)
            def failed_diagnostic(process, directory):
                self.assertIsNone(process.poll())
                raise PermissionError("Mock sampler permission failure")
            result = smoke_test.launch_smoke(
                [sys.executable, "-c", "import sys,time;print('checkpoint-before-block',file=sys.stderr,flush=True);time.sleep(10)"],
                dict(os.environ), root / "stdout.log", root / "stderr.log", deadline=0.2, diagnostic=failed_diagnostic)
            self.assertTrue(result["timed_out"])
            self.assertTrue(result["child_reaped_after_timeout"])
            self.assertNotEqual(result["process_exit_code"], 0)
            self.assertEqual(result["sample_diagnostic"]["error_type"], "PermissionError")
            self.assertIn("checkpoint-before-block", (root / "stderr.log").read_text())

    def test_nonzero_exit_retains_logs_without_sampling(self):
        with tempfile.TemporaryDirectory(prefix="mopanel-smoke-driver-") as temporary:
            root = pathlib.Path(temporary)
            diagnostic = mock.Mock(side_effect=AssertionError("Must not sample an exited process"))
            result = smoke_test.launch_smoke([sys.executable, "-c", "print('fixture-output');raise SystemExit(7)"],
                dict(os.environ), root / "stdout.log", root / "stderr.log", deadline=2, diagnostic=diagnostic)
            self.assertEqual(result["process_exit_code"], 7)
            self.assertFalse(result["timed_out"])
            diagnostic.assert_not_called()
            self.assertIn("fixture-output", (root / "stdout.log").read_text())

    def test_sampler_permission_failure_is_recorded_without_elevation(self):
        with tempfile.TemporaryDirectory(prefix="mopanel-smoke-driver-") as temporary:
            process = types.SimpleNamespace(pid=43210, poll=lambda: None)
            with mock.patch.object(smoke_test.platform, "system", return_value="Darwin"), \
                 mock.patch.object(smoke_test.subprocess, "run", return_value=subprocess.CompletedProcess([], 1)) as run:
                result = smoke_test.sample_owned_app(process, pathlib.Path(temporary))
            self.assertEqual(result["status"], "sample_command_failed")
            self.assertFalse(result["changes_to_security_settings"])
            self.assertEqual(run.call_args.args[0][:4], ["/usr/bin/sample", "43210", "2", "1"])
            self.assertEqual(run.call_args.kwargs["timeout"], 8)

    def test_sampler_never_runs_after_owned_child_exited(self):
        with tempfile.TemporaryDirectory(prefix="mopanel-smoke-driver-") as temporary:
            process = types.SimpleNamespace(pid=43210, poll=lambda: 0)
            with mock.patch.object(smoke_test.platform, "system", return_value="Darwin"), \
                 mock.patch.object(smoke_test.subprocess, "run") as run:
                result = smoke_test.sample_owned_app(process, pathlib.Path(temporary))
            self.assertFalse(result["attempted"])
            run.assert_not_called()

    def test_crash_diagnostic_failure_preserves_original_signal(self):
        with tempfile.TemporaryDirectory(prefix="mopanel-smoke-driver-") as temporary:
            root = pathlib.Path(temporary)
            with mock.patch.object(smoke_test, "collect_owned_crash", side_effect=PermissionError("Synthetic permission failure")) as collect:
                result = smoke_test.launch_smoke([sys.executable, "-c", "import os,signal;os.kill(os.getpid(),signal.SIGTERM)"],
                    dict(os.environ), root / "stdout.log", root / "stderr.log", deadline=2)
            self.assertEqual(result["process_exit_code"], -signal.SIGTERM)
            self.assertFalse(result["timed_out"])
            self.assertEqual(result["crash_report"]["status"], "diagnostic_exception")
            self.assertEqual(collect.call_args.args[0], result["child_pid"])


if __name__ == "__main__":
    unittest.main(verbosity=2)
