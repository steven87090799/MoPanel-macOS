#!/usr/bin/env python3
"""Synthetic report-generation regression tests; no App, Git or Mole runs."""
import json
import os
import pathlib
import subprocess
import sys
import tempfile
import unittest


SCRIPT = pathlib.Path(__file__).with_name("write_release_report.py")
DOCUMENTS = {
    "COMPATIBILITY.md": "",
    "Source/COMPATIBILITY.md": "../",
    "Source/docs/GUI_PARITY.md": "../../",
    "Source/docs/MOPANEL_ADDITIONS.md": "../../",
}
ORIGINAL = "# Original synthetic historical snapshot\n\nOlder smoke failed; hardware remains unverified.\n"


class ReleaseReportTests(unittest.TestCase):
    def run_generator(self, test_log):
        temporary = tempfile.TemporaryDirectory(prefix="mopanel-report-regression-")
        self.addCleanup(temporary.cleanup)
        package = pathlib.Path(temporary.name)
        reports = package / "Reports"
        reports.mkdir()
        for relative in DOCUMENTS:
            path = package / relative
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(ORIGINAL)
        (package / "TEST_REPORT.md").write_text(ORIGINAL)
        (package / "Source/TEST_REPORT.md").write_text(ORIGINAL)
        gates = {name: {"passed": True, "pipeline_exit_code": 0,
                        "command_exit_code": 0, "tee_exit_code": 0}
                 for name in ("swift-test", "fixture-smoke")}
        (reports / "validation-gates.json").write_text(json.dumps({
            "schema_version": 1, "required_gates": list(gates),
            "gates": gates, "all_required_passed": True}))
        for name in ("validation-gate-harness.log", "smoke-driver-tests.log",
                     "crash-evidence-tests.log", "debug-diagnostic-tests.log",
                     "guardian-test.log"):
            (reports / name).write_text("Ran 1 test in 0.001s\n\nOK\n")
        (reports / "swift-test.log").write_text(test_log)
        (reports / "bundle-verification.txt").write_text(
            "PASS: bundle layout, ARM64 executables, signature integrity\n")
        (reports / "smoke-test.json").write_text(json.dumps({
            "success": True, "window_created": True, "fixture_only": True,
            "checks": {"fixture_resource_inside_app": True}}))
        (reports / "performance.json").write_text(json.dumps({
            "fixture_only": True,
            "modes": [{"mode": mode, "cpu_mean_percent": 0, "cpu_peak_percent": 0,
                       "rss_mean_bytes": 0, "rss_peak_bytes": 0}
                      for mode in ("idle", "monitor", "scan")]}))
        environment = os.environ.copy()
        environment.pop("GITHUB_ACTIONS", None)
        result = subprocess.run([sys.executable, str(SCRIPT), str(package)],
                                env=environment, capture_output=True, text=True,
                                timeout=5, check=False)
        return package, result

    def test_actual_suite_summaries_supply_counts_and_history_is_preserved(self):
        log = ("Test Suite 'GitWorktreeIntegrationTests' passed at synthetic-time.\n"
               "Executed 3 tests, with 0 failures (0 unexpected) in 0.1 seconds\n"
               "Test Suite 'GitWorktreeParserTests' passed at synthetic-time.\n"
               "Executed 5 tests, with 0 failures (0 unexpected) in 0.1 seconds\n"
               "Test Suite 'SyntheticCore.xctest' passed at synthetic-time.\n"
               "Executed 8 tests, with 0 failures (0 unexpected) in 0.2 seconds\n")
        package, result = self.run_generator(log)
        self.assertEqual(result.returncode, 0, result.stderr)
        report = (package / "TEST_REPORT.md").read_text()
        self.assertIn("GitWorktreeIntegrationTests：3 個案例通過", report)
        self.assertIn("GitWorktreeParserTests：5 個案例通過", report)
        self.assertIn("已包含在前述 XCTest 總數", report)
        self.assertIn("沒有操作使用者的既有倉庫", report)
        self.assertEqual((package / "Source/TEST_REPORT.md").read_text(), report)
        for relative, prefix in DOCUMENTS.items():
            document = (package / relative).read_text()
            self.assertTrue(document.endswith(ORIGINAL), relative)
            self.assertIn(f"]({prefix}TEST_REPORT.md)", document)
            self.assertIn(f"]({prefix}Reports/)", document)
            self.assertIn("不表示全部 UI 或官方付費功能已驗收", document)

    def test_absent_or_incomplete_git_suite_does_not_claim_git_execution(self):
        package, result = self.run_generator(
            "Test Suite 'GitWorktreeIntegrationTests' passed at synthetic-time.\n"
            "unrelated line without an XCTest summary\n"
            "Test Suite 'SyntheticCore.xctest' passed at synthetic-time.\n"
            "Executed 8 tests, with 0 failures (0 unexpected) in 0.2 seconds\n")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertNotIn("## Git worktree 隔離驗證", (package / "TEST_REPORT.md").read_text())

    def test_parser_only_does_not_claim_real_git_integration(self):
        package, result = self.run_generator(
            "Test Suite 'GitWorktreeParserTests' passed at synthetic-time.\n"
            "Executed 2 tests, with 0 failures (0 unexpected) in 0.1 seconds\n")
        self.assertEqual(result.returncode, 0, result.stderr)
        report = (package / "TEST_REPORT.md").read_text()
        self.assertIn("GitWorktreeParserTests：2 個案例通過", report)
        self.assertIn("不宣稱已執行真 Git 整合驗證", report)
        self.assertNotIn("使用真 Git 與每個測試新建", report)

    def test_failed_suite_still_blocks_generation_and_keeps_documents_unchanged(self):
        package, result = self.run_generator(
            "Test Suite 'GitWorktreeIntegrationTests' failed at synthetic-time.\n"
            "Executed 3 tests, with 1 failure (0 unexpected) in 0.1 seconds\n")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Swift tests do not show a clean result", result.stderr)
        for relative in ["TEST_REPORT.md", "Source/TEST_REPORT.md", *DOCUMENTS]:
            self.assertEqual((package / relative).read_text(), ORIGINAL)


if __name__ == "__main__":
    unittest.main(verbosity=2)
