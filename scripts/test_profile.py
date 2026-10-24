#!/usr/bin/env python3
"""Isolated tests of measurement safety/evidence; never launches Mole or the UI."""
import copy
import importlib.util
import json
import os
import pathlib
import tempfile
import unittest

spec = importlib.util.spec_from_file_location("mopanel_profile", pathlib.Path(__file__).with_name("profile.py"))
profile = importlib.util.module_from_spec(spec)
spec.loader.exec_module(profile)


class ProfileHarnessTests(unittest.TestCase):
    def test_fresh_flat_corpus_and_no_process_home_change(self):
        original_home = os.environ.get("HOME")
        with tempfile.TemporaryDirectory(prefix="mopanel-profile-test-") as temporary:
            root = pathlib.Path(temporary)
            cli = root / "mock-mo"
            cli.write_bytes(b"fixture, never executed")
            session = root / "mopanel-real-benchmark-test"
            session.mkdir()
            manifest_path, manifest = profile.prepare_real_manifest(session, "scan", cli)
            entries = list((session / "corpus").iterdir())
            self.assertEqual(len(entries), 5000)
            self.assertTrue(all(path.is_file() and not path.is_symlink() for path in entries))
            self.assertEqual(sum(path.stat().st_size for path in entries), 5000 * 4096)
            self.assertEqual(json.loads(manifest_path.read_text()), manifest)
            self.assertFalse(pathlib.Path(manifest["report_path"]).exists())
            self.assertEqual(manifest_path.stat().st_mode & 0o777, 0o600)
        self.assertEqual(os.environ.get("HOME"), original_home)

    def test_real_evidence_requires_readonly_mode_and_matching_provenance(self):
        with tempfile.TemporaryDirectory(prefix="mopanel-evidence-test-") as temporary:
            root = pathlib.Path(temporary)
            cli = root / "mo"
            cli.write_bytes(b"fixture, never executed")
            (root / "MOPANEL_CI_SOURCE.json").write_text(json.dumps({
                "tag": "V1.62.0", "commit": "test-commit", "official_binaries_verified": True}))
            manifest = {"cli_path": str(cli), "corpus_path": str(root / "corpus")}
            evidence = {"mode": "idle", "completed": True, "fixture_only": False,
                        "read_only_enforced": True, "cli_path": str(cli),
                        "corpus_path": str(root / "corpus"), "cli_version": "1.62.0",
                        "cli_fingerprint": "test-fingerprint", "cli_source_tag": "V1.62.0",
                        "cli_source_commit": "test-commit", "watch_samples": 0}
            profile.validate_evidence(evidence, "idle", manifest)
            for key, value in (("read_only_enforced", False), ("fixture_only", True),
                               ("cli_source_commit", "different"), ("cli_path", "/not-the-test-cli"),
                               ("corpus_path", "/not-the-test-corpus"), ("watch_samples", 1)):
                changed = copy.deepcopy(evidence)
                changed[key] = value
                with self.assertRaises(RuntimeError, msg=key):
                    profile.validate_evidence(changed, "idle", manifest)

    def test_fixture_evidence_does_not_accept_a_real_engine(self):
        with self.assertRaises(RuntimeError):
            profile.validate_evidence({"mode": "idle", "completed": True, "fixture_only": False}, "idle")
        profile.validate_evidence({"mode": "idle", "completed": True, "fixture_only": True}, "idle")

    def test_samples_exclude_warmup_shutdown_and_inactive_scan_intervals(self):
        samples = [{"observed_at_epoch": timestamp, "process_count": 1,
                    "rss_bytes": 1024, "cpu_percent": 1} for timestamp in range(99, 115)]
        evidence = {"started_at_epoch": 100, "duration_seconds": 12,
                    "scan_intervals": [{"start_epoch": 103, "end_epoch": 109}]}
        selected = profile.workload_samples(samples, evidence, "scan", real=True)
        self.assertEqual([sample["observed_at_epoch"] for sample in selected], list(range(103, 110)))
        idle = profile.workload_samples(samples, evidence, "idle")
        self.assertEqual([sample["observed_at_epoch"] for sample in idle], list(range(102, 113)))

    def test_missing_or_insufficient_activity_cannot_be_reported(self):
        samples = [{"observed_at_epoch": 103, "process_count": 1, "rss_bytes": 1024, "cpu_percent": 1}]
        for evidence in ({"started_at_epoch": 100, "duration_seconds": 12},
                         {"started_at_epoch": 100},
                         {"started_at_epoch": float("nan"), "duration_seconds": 12}):
            with self.assertRaises(RuntimeError):
                profile.workload_samples(samples, evidence, "idle")


if __name__ == "__main__":
    unittest.main(verbosity=2)
