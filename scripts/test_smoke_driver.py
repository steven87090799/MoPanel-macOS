#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Real isolated children plus mocked Mac sampler; no macOS UI or Mole runs."""
import os
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
