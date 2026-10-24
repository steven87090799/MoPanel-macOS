#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Exercise real Bash pipelines with isolated stubs; never launch Mole or an app."""
import json
import os
import pathlib
import subprocess
import tempfile
import unittest

MODULE = pathlib.Path(__file__).resolve().with_name("validation-gates.sh")
RUNNER = r'''#!/bin/bash
set -euo pipefail
source "$1"
mopanel_initialize_validation_gates "$2/summary.json"
mopanel_capture_validation_gate "$2/summary.json" swift-test "$2/swift.log" \
    python3 "$2/command.py" "$3" "$5"
mopanel_capture_validation_gate "$2/summary.json" fixture-smoke "$2/smoke.log" \
    python3 "$2/command.py" "$4" "Fixture-only smoke stub"
mopanel_require_validation_gates "$2/summary.json"
printf 'later acceptance phase reached\n' > "$2/later-phase.txt"
'''


class ValidationGateTests(unittest.TestCase):
    def invoke(self, swift=0, smoke=0, tee=0, summary="Executed 1 test, with 0 failures (0 unexpected)"):
        with tempfile.TemporaryDirectory(prefix="mopanel-gates-test-") as temporary:
            root = pathlib.Path(temporary)
            (root / "run.sh").write_text(RUNNER)
            (root / "command.py").write_text("import sys\nprint(sys.argv[2], flush=True)\nraise SystemExit(int(sys.argv[1]))\n")
            # Retain real tee behavior and inject only its final status.
            binary = root / "bin"
            binary.mkdir()
            stub = binary / "tee"
            stub.write_text('#!/bin/bash\n/usr/bin/tee "$@"\nexit "$MOPANEL_TEST_TEE_EXIT"\n')
            stub.chmod(0o700)
            environment = dict(os.environ)
            environment["PATH"] = str(binary) + os.pathsep + environment["PATH"]
            environment["MOPANEL_TEST_TEE_EXIT"] = str(tee)
            process = subprocess.run(["/bin/bash", "--noprofile", "--norc", "-e", "-o", "pipefail",
                                      str(root / "run.sh"), str(MODULE), str(root), str(swift), str(smoke), summary],
                                     env=environment, capture_output=True, text=True, timeout=10)
            evidence = json.loads((root / "summary.json").read_text())
            return process.returncode, evidence, (root / "later-phase.txt").exists()

    def test_both_pass_allows_later_phase(self):
        status, evidence, continued = self.invoke()
        self.assertEqual(status, 0)
        self.assertTrue(continued)
        self.assertTrue(evidence["all_required_passed"])

    def test_swift_failure_preserves_smoke_evidence_and_blocks_later_phase(self):
        status, evidence, continued = self.invoke(swift=13)
        self.assertNotEqual(status, 0)
        self.assertFalse(continued)
        self.assertEqual(evidence["gates"]["swift-test"]["command_exit_code"], 13)
        self.assertEqual(evidence["gates"]["swift-test"]["pipeline_exit_code"], 13)
        self.assertTrue(evidence["gates"]["fixture-smoke"]["passed"])

    def test_smoke_failure_blocks_later_phase(self):
        status, evidence, continued = self.invoke(smoke=17)
        self.assertNotEqual(status, 0)
        self.assertFalse(continued)
        self.assertEqual(evidence["gates"]["fixture-smoke"]["command_exit_code"], 17)
        self.assertTrue(evidence["gates"]["swift-test"]["passed"])

    def test_tee_failure_is_preserved_separately_and_blocks_later_phase(self):
        status, evidence, continued = self.invoke(tee=23)
        self.assertNotEqual(status, 0)
        self.assertFalse(continued)
        for gate in evidence["gates"].values():
            self.assertEqual(gate["command_exit_code"], 0)
            self.assertEqual(gate["tee_exit_code"], 23)
            self.assertEqual(gate["pipeline_exit_code"], 23)

    def test_skipped_xctest_with_zero_exit_still_blocks_later_phase(self):
        status, evidence, continued = self.invoke(summary="Executed 1 test, with 1 test skipped and 0 failures")
        self.assertNotEqual(status, 0)
        self.assertFalse(continued)
        self.assertIn("xctest_skipped", evidence["gates"]["swift-test"]["failure_reasons"])

    def test_failure_summary_with_zero_exit_still_blocks_later_phase(self):
        status, evidence, continued = self.invoke(summary="Executed 1 test, with 1 failure (0 unexpected)")
        self.assertNotEqual(status, 0)
        self.assertFalse(continued)
        self.assertIn("xctest_failures", evidence["gates"]["swift-test"]["failure_reasons"])


if __name__ == "__main__":
    unittest.main(verbosity=2)
