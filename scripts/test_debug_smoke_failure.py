#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Only disposable fixture bytes and mocked signing/debugger commands."""
import json
import pathlib
import plistlib
import shutil
import subprocess
import tempfile
import unittest
from unittest import mock
import debug_smoke_failure as debug
import signature_policy


class DebugFailureTests(unittest.TestCase):
    def fixture(self, root):
        app = root / "release/MoPanel.app"
        for name in debug.PROTECTED_FILES:
            path = app / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(("synthetic " + name).encode())
        output = root / "reports"; output.mkdir()
        environment = {"CI": "true", "GITHUB_ACTIONS": "true", "RUNNER_TEMP": str(root),
                       "MOPANEL_SMOKE_REPORT": str(root / "formal.json"), "MOPANEL_GITHUB_TOKEN": "synthetic-not-a-token"}
        return app, output, environment

    def commands(self, commands, signing_code=0):
        def run(arguments, **kwargs):
            commands.append(arguments)
            self.assertLessEqual(kwargs["timeout"], 8)
            if arguments[0] == "/usr/bin/ditto":
                shutil.copytree(arguments[1], arguments[2])
            elif arguments[0] == "/usr/bin/codesign":
                copy = pathlib.Path(arguments[-1])
                entitlement = pathlib.Path(arguments[arguments.index("--entitlements") + 1])
                self.assertEqual(plistlib.loads(entitlement.read_bytes()), {"com.apple.security.get-task-allow": True})
                (copy / "Contents/MacOS/MoPanel").write_bytes(b"synthetic signed copy")
            else:
                self.fail("Unexpected diagnostic command")
            return subprocess.CompletedProcess(arguments, signing_code if arguments[0] == "/usr/bin/codesign" else 0)
        return run

    def test_requires_failed_macos_ci_and_never_runs_after_success(self):
        with mock.patch.object(debug.platform, "system", return_value="Darwin"), mock.patch.object(debug.subprocess, "run") as run:
            for failed, environment in [(False, {"CI": "true", "GITHUB_ACTIONS": "true"}), (True, {}), (True, {"CI": "true"})]:
                result = debug.diagnose(pathlib.Path("missing"), pathlib.Path("missing"), environment, failed=failed)
                self.assertFalse(result["attempted"])
            run.assert_not_called()

    def test_only_copy_is_signed_original_hashes_preserved_and_report_is_separate(self):
        with tempfile.TemporaryDirectory(prefix="mopanel-debug-guard-") as temporary:
            actual = pathlib.Path(temporary) / "actual"; actual.mkdir()
            root = pathlib.Path(temporary) / "alias"; root.symlink_to(actual, target_is_directory=True)
            app, output, environment = self.fixture(root)
            before = debug.original_hashes(app); commands = []
            def lldb(guardian, executable, child_environment, directory, seconds):
                self.assertNotEqual(executable, app / "Contents/MacOS/MoPanel")
                self.assertEqual(guardian, app.resolve() / "Contents/Helpers/MoPanelGuardian")
                self.assertNotEqual(child_environment["MOPANEL_SMOKE_REPORT"], environment["MOPANEL_SMOKE_REPORT"])
                self.assertNotIn("MOPANEL_GITHUB_TOKEN", child_environment)
                self.assertLessEqual(seconds, 43)
                pathlib.Path(child_environment["MOPANEL_SMOKE_REPORT"]).write_text('{"fixture_only":true,"success":true}')
                return {"status": "synthetic_debugger_result", "exit_code": 0}
            with mock.patch.object(debug.platform, "system", return_value="Darwin"), mock.patch.object(debug.subprocess, "run", side_effect=self.commands(commands)), mock.patch.object(debug, "run_lldb", side_effect=lldb):
                result = debug.diagnose(app, output, environment, failed=True)
            self.assertTrue(result["original_files_unchanged"])
            self.assertEqual(result["status"], "diagnostic_finished_not_acceptance", result)
            self.assertTrue(result["original_smoke_still_failed"])
            self.assertEqual(debug.original_hashes(app), before)
            self.assertFalse(pathlib.Path(environment["MOPANEL_SMOKE_REPORT"]).exists())
            self.assertEqual(list(root.glob("mopanel-debug-only-*")), [])
            self.assertTrue((output / "smoke-debug-app-report.json").exists())

    def test_signing_denial_is_recorded_without_debugger_or_security_changes(self):
        with tempfile.TemporaryDirectory(prefix="mopanel-debug-guard-") as temporary:
            root = pathlib.Path(temporary); app, output, environment = self.fixture(root); commands = []
            with mock.patch.object(debug.platform, "system", return_value="Darwin"), mock.patch.object(debug.subprocess, "run", side_effect=self.commands(commands, 1)), mock.patch.object(debug, "run_lldb") as lldb:
                result = debug.diagnose(app, output, environment, failed=True)
            lldb.assert_not_called()
            self.assertEqual(result["status"], "diagnostic_failed")
            self.assertTrue(result["original_files_unchanged"])
            self.assertFalse(result["host_security_settings_changed"])

    def test_unexpected_original_change_is_detected(self):
        with tempfile.TemporaryDirectory(prefix="mopanel-debug-guard-") as temporary:
            root = pathlib.Path(temporary); app, output, environment = self.fixture(root); commands = []
            def changed(*args):
                (app / "Contents/MacOS/MoPanel").write_bytes(b"isolated tampering fixture")
                return {"status": "synthetic"}
            with mock.patch.object(debug.platform, "system", return_value="Darwin"), mock.patch.object(debug.subprocess, "run", side_effect=self.commands(commands)), mock.patch.object(debug, "run_lldb", side_effect=changed):
                result = debug.diagnose(app, output, environment, failed=True)
            self.assertFalse(result["original_files_unchanged"])
            self.assertTrue(result["original_smoke_still_failed"])

    def test_debugger_fixed_arguments_and_lifeline_guard(self):
        with tempfile.TemporaryDirectory(prefix="mopanel-debug-guard-") as temporary:
            process = mock.Mock(); process.wait.return_value = 1
            process.stdin.closed = False
            with mock.patch.object(debug.subprocess, "Popen", return_value=process) as popen:
                result = debug.run_lldb(pathlib.Path("/fixture/guardian"), pathlib.Path("/fixture/copy.app/Contents/MacOS/MoPanel"), {}, pathlib.Path(temporary), 40)
            arguments = popen.call_args.args[0]
            self.assertEqual(arguments[:5], ["/fixture/guardian", "--capture", "--timeout-ms", "36000", "--"])
            self.assertIn("--no-lldbinit", arguments)
            self.assertIn("thread backtrace -c 128 all", arguments)
            self.assertEqual(arguments[-1], "--smoke-test")
            self.assertTrue(result["guardian_reaped"])
            process.stdin.close.assert_called_once()

    def test_sigpipe_stops_only_debug_copy_and_is_never_suppressed(self):
        with tempfile.TemporaryDirectory(prefix="mopanel-debug-guard-") as temporary:
            root = pathlib.Path(temporary)
            app, output, environment = self.fixture(root)
            before = debug.original_hashes(app)
            process = mock.Mock(); process.wait.return_value = 1
            process.stdin.closed = False
            with mock.patch.object(debug.platform, "system", return_value="Darwin"), \
                    mock.patch.object(debug.subprocess, "run", side_effect=self.commands([])), \
                    mock.patch.object(debug.subprocess, "Popen", return_value=process) as popen:
                result = debug.diagnose(app, output, environment, failed=True)
            arguments = popen.call_args.args[0]
            commands = [arguments[i + 1] for i, value in enumerate(arguments[:-1]) if value == "-o"]
            signal_commands = [command for command in commands if command.startswith("process handle")]
            self.assertEqual(signal_commands, ["process handle SIGPIPE --stop true --notify true --pass true"])
            self.assertLess(commands.index(signal_commands[0]), commands.index("run"))
            executable = pathlib.Path(arguments[-2])
            self.assertNotEqual(executable, app.resolve() / "Contents/MacOS/MoPanel")
            self.assertTrue(executable.parents[3].name.startswith("mopanel-debug-only-"))
            self.assertEqual(arguments[-1], "--smoke-test")
            self.assertTrue(result["original_smoke_still_failed"])
            self.assertTrue(result["original_files_unchanged"])
            self.assertEqual(debug.original_hashes(app), before)
            self.assertFalse(result["host_security_settings_changed"])

    def test_release_policy_rejects_debug_entitlement_even_if_false(self):
        for value in (True, False):
            run = mock.Mock(return_value=subprocess.CompletedProcess([], 0, stdout=plistlib.dumps({"com.apple.security.get-task-allow": value})))
            with self.assertRaises(RuntimeError):
                signature_policy.require_release_entitlements("/fixture/release", run=run)

    def test_debugger_timeout_closes_lifeline_and_reaps_guardian(self):
        with tempfile.TemporaryDirectory(prefix="mopanel-debug-guard-") as temporary:
            process = mock.Mock(); process.wait.side_effect = [subprocess.TimeoutExpired("fixture", 40), 124]
            process.returncode = 124; process.stdin.closed = False
            with mock.patch.object(debug.subprocess, "Popen", return_value=process):
                result = debug.run_lldb(pathlib.Path("/fixture/guardian"), pathlib.Path("/fixture/copy.app/Contents/MacOS/MoPanel"), {}, pathlib.Path(temporary), 40)
            self.assertEqual(result["status"], "debugger_deadline_exceeded")
            self.assertTrue(result["guardian_reaped"])
            process.stdin.close.assert_called()
            process.kill.assert_not_called()
            self.assertEqual(process.wait.call_args_list, [mock.call(timeout=40), mock.call(timeout=3)])

    def test_release_policy_accepts_empty_entitlements_and_rejects_unparseable(self):
        for raw in (b"", plistlib.dumps({})):
            run = mock.Mock(return_value=subprocess.CompletedProcess([], 0, stdout=raw))
            self.assertTrue(signature_policy.require_release_entitlements("/fixture/release", run=run))
        run = mock.Mock(return_value=subprocess.CompletedProcess([], 0, stdout=b"unparseable"))
        with self.assertRaises(plistlib.InvalidFileException):
            signature_policy.require_release_entitlements("/fixture/release", run=run)


if __name__ == "__main__":
    unittest.main(verbosity=2)
