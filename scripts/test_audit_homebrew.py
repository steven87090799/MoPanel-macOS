#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Synthetic audit-script tests; never runs Homebrew or modifies an app."""
import json
import os
import pathlib
import signal
import subprocess
import sys
import unittest
from unittest import mock

import audit_homebrew as audit


class HomebrewAuditTests(unittest.TestCase):
    def fixture(self, name):
        return (pathlib.Path(__file__).resolve().parents[1] / "Tests/MoPanelCoreTests/Fixtures" / name).read_bytes()

    def test_shared_homebrew_fixtures_match_native_contract(self):
        result = audit.validate_snapshot(self.fixture("brew-info-v2.json"), self.fixture("brew-outdated-v2.json"))
        self.assertEqual(result["installed_cask_count"], 4)
        self.assertEqual(result["outdated_cask_count"], 1)
        self.assertEqual(result["explicit_app_target_count"], 4)
        self.assertFalse(result["inventory_record_names_paths_urls_retained"])
        self.assertNotIn("example-editor", json.dumps(result))

    def test_missing_and_conflicting_json_cannot_pass(self):
        for invalid in (b"{}", b"[]", b'{"casks":null}', b"not-json"):
            with self.assertRaises(audit.AuditFailure):
                audit.validate_snapshot(invalid, self.fixture("brew-outdated-v2.json"))
        info = json.loads(self.fixture("brew-info-v2.json"))
        info["casks"][0]["installed"] = "other-version"
        with self.assertRaises(audit.AuditFailure):
            audit.validate_snapshot(json.dumps(info).encode(), self.fixture("brew-outdated-v2.json"))

    def test_safety_flag_loss_is_explicitly_read_only(self):
        helps = {"info": "brew info --json=v2 --cask --installed", "outdated": "brew outdated --json=v2 --cask",
                 "upgrade": "brew upgrade --cask --dry-run --no-quit --require-sha", "update": "brew update Homebrew"}
        self.assertTrue(audit.help_contract(helps)["upgrade_contract_compatible"])
        helps["upgrade"] = helps["upgrade"].replace("--no-quit", "--no-quit-unsupported")
        result = audit.help_contract(helps)
        self.assertTrue(result["read_contract_compatible"])
        self.assertFalse(result["upgrade_contract_compatible"])
        self.assertEqual(result["missing_required_flags"]["upgrade"], ["--no-quit"])

    def test_mutations_rejected_before_process_creation(self):
        with mock.patch.object(audit.subprocess, "Popen") as popen:
            for args in (("update",), ("upgrade", "--cask", "app"), ("install", "app"), ("outdated", "--json=v2", ";id")):
                with self.assertRaises(audit.AuditFailure):
                    audit.invoke(args, [])
            popen.assert_not_called()

    def test_caskroom_contract_requires_one_path_and_does_not_retain_it(self):
        result = audit.validate_caskroom(b"/opt/homebrew/Caskroom\n")
        self.assertTrue(result["single_absolute_path"])
        self.assertFalse(result["raw_path_retained"])
        self.assertFalse(result["installed_recipe_files_audited"])
        self.assertNotIn("/opt/homebrew", json.dumps(result))
        for value in (b"relative", b"/one\n/two\n", b"/one\0", b""):
            with self.assertRaises(audit.AuditFailure):
                audit.validate_caskroom(value)

    def test_environment_does_not_forward_tokens_or_homebrew_hooks(self):
        with mock.patch.dict(os.environ, {"GITHUB_TOKEN": "private", "AWS_SECRET_ACCESS_KEY": "private", "BASH_ENV": "/evil",
                                         "HOMEBREW_API_DOMAIN": "https://attacker.invalid", "HOMEBREW_NO_ANALYTICS": "0"}):
            env = audit.safe_environment()
        for key in ("GITHUB_TOKEN", "AWS_SECRET_ACCESS_KEY", "BASH_ENV", "HOMEBREW_API_DOMAIN", "SSH_AUTH_SOCK"):
            self.assertNotIn(key, env)
        for key in audit.PROTECTIVE_ENV:
            self.assertEqual(env[key], "1")

    def child(self, code):
        return subprocess.Popen([sys.executable, "-c", code], stdin=subprocess.DEVNULL,
                                stdout=subprocess.PIPE, stderr=subprocess.PIPE, start_new_session=True)

    def test_small_stdout_and_stderr_are_drained(self):
        process = self.child("import os; os.write(1,b'one'); os.write(2,b'two')")
        self.assertEqual(audit.bounded_output(process, 3, 1024), (b"one", b"two"))
        self.assertEqual(process.returncode, 0)

    def test_output_limit_stops_owned_child(self):
        process = self.child("import os,time; os.write(1,b'x'*65536); time.sleep(30)")
        with self.assertRaisesRegex(audit.AuditFailure, "command_output_limit"):
            audit.bounded_output(process, 3, 1024)
        self.assertIsNotNone(process.poll())

    def test_timeout_stops_owned_child(self):
        process = self.child("import time; time.sleep(30)")
        with self.assertRaisesRegex(audit.AuditFailure, "command_timeout"):
            audit.bounded_output(process, 0.1, 1024)
        self.assertIsNotNone(process.poll())

    def test_darwin_zombie_permission_race_reaps_then_rechecks_group(self):
        process = mock.Mock(pid=12345)
        # TERM succeeds, the process exits between poll and the first probe,
        # and a later poll reaps it so the process group disappears.
        with mock.patch.object(audit.os, "killpg", side_effect=[None, PermissionError(1, "denied"), ProcessLookupError(3, "gone")]) as killpg:
            audit.stop_group(process, grace_seconds=0.1)
        self.assertEqual(killpg.call_args_list, [mock.call(12345, signal.SIGTERM), mock.call(12345, 0), mock.call(12345, 0)])
        self.assertGreaterEqual(process.poll.call_count, 3)
        process.wait.assert_called_once_with(timeout=3)

    def test_darwin_zombie_during_term_is_not_assumed_absent(self):
        process = mock.Mock(pid=12345)
        with mock.patch.object(audit.os, "killpg", side_effect=[PermissionError(1, "denied"), ProcessLookupError(3, "gone")]) as killpg:
            audit.stop_group(process, grace_seconds=0)
        self.assertEqual(killpg.call_args_list, [mock.call(12345, signal.SIGTERM), mock.call(12345, 0)])
        process.wait.assert_called_once_with(timeout=3)

    def test_persistent_group_permission_failure_is_not_hidden(self):
        process = mock.Mock(pid=12345)
        with mock.patch.object(audit.os, "killpg", side_effect=PermissionError(1, "denied")) as killpg:
            with self.assertRaisesRegex(audit.AuditFailure, "^command_cleanup_permission_denied$"):
                audit.stop_group(process, grace_seconds=0)
        self.assertIn(mock.call(12345, signal.SIGKILL), killpg.call_args_list)
        process.wait.assert_called_once_with(timeout=3)

    def test_absent_group_still_reaps_direct_child(self):
        process = mock.Mock(pid=12345)
        with mock.patch.object(audit.os, "killpg", side_effect=ProcessLookupError(3, "gone")):
            audit.stop_group(process)
        process.wait.assert_called_once_with(timeout=3)

    def test_cleanup_failure_still_closes_both_pipes(self):
        process = self.child("pass")
        with mock.patch.object(audit, "stop_group", side_effect=audit.AuditFailure("command_cleanup_permission_denied")):
            with self.assertRaisesRegex(audit.AuditFailure, "command_cleanup_permission_denied"):
                audit.bounded_output(process, 3, 1024)
        self.assertEqual(process.returncode, 0)
        self.assertTrue(process.stdout.closed)
        self.assertTrue(process.stderr.closed)

    def test_non_ci_environment_never_launches_homebrew(self):
        with mock.patch.object(audit.platform, "system", return_value="Linux"), mock.patch.object(audit.subprocess, "Popen") as popen:
            result, code = audit.audit()
        self.assertEqual(code, 1)
        self.assertEqual(result["status"], "unsupported_environment")
        self.assertEqual(result["commands"], [])
        popen.assert_not_called()


if __name__ == "__main__":
    unittest.main(verbosity=2)
