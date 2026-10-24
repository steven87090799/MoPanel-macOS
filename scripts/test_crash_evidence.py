#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Synthetic crash text only; never read the host's diagnostic report folders."""
import datetime
import json
import os
import pathlib
import tempfile
import time
import unittest
from unittest import mock
import crash_evidence as crash


class CrashEvidenceTests(unittest.TestCase):
    def setUp(self):
        self.now = time.time()
        self.started = self.now - 1
        self.path = "/fixture/MoPanel.app/Contents/MacOS/MoPanel"
        self.stamp = datetime.datetime.fromtimestamp(self.now, datetime.timezone.utc).isoformat()
        self.header = {"app_name": "MoPanel", "timestamp": self.stamp, "bundleID": "org.mopanel.app"}
        self.body = {"pid": 43210, "procName": "MoPanel", "procPath": self.path}

    def payload(self):
        return (json.dumps(self.header) + "\n" + json.dumps(self.body)).encode()

    def identify(self, name="MoPanel-fixture.ips", data=None, mtime=None):
        return crash.verified_identity(name, self.payload() if data is None else data, 43210,
                                       self.started, self.now if mtime is None else mtime, self.now, self.path)

    def test_two_json_ips_identity(self):
        self.assertTrue(self.identify()["filename_mtime_pid_and_process_confirmed"])
        self.header["timestamp"] = datetime.datetime.fromtimestamp(self.now, datetime.timezone.utc).strftime("%Y-%m-%d %H:%M:%S.%f %z")
        self.assertIsNotNone(self.identify())

    def test_legacy_crash_identity(self):
        data = f"Process: MoPanel [43210]\nPath: {self.path}\nDate/Time: {self.stamp}\n".encode()
        self.assertIsNotNone(self.identify(name="MoPanel-fixture.crash", data=data))

    def test_wrong_pid_app_or_path_are_not_attached(self):
        for key, value in [("pid", 43211), ("procName", "OtherApp"), ("procPath", "/other/app")]:
            original = self.body[key]
            self.body[key] = value
            self.assertIsNone(self.identify())
            self.body[key] = original

    def test_stale_unrecognized_or_malformed_reports_are_not_attached(self):
        self.assertIsNone(self.identify(mtime=self.started - 10))
        self.assertIsNone(self.identify(name="OtherApp-fixture.ips"))
        self.assertIsNone(self.identify(data=self.payload() + b"\n{}"))
        self.header["timestamp"] = "unknown"
        self.assertIsNone(self.identify())

    def test_collector_reads_only_recent_mopanel_candidates_and_copies_verified_bytes(self):
        with tempfile.TemporaryDirectory(prefix="mopanel-crash-fixture-") as temporary:
            root = pathlib.Path(temporary); output = root / "output"; output.mkdir()
            source = root / "MoPanel-fixture.ips"; source.write_bytes(self.payload())
            (root / "OtherApp-fixture.ips").write_bytes(b"must never be opened")
            (root / "MoPanel-symlink.ips").symlink_to(root / "OtherApp-fixture.ips")
            os.utime(source, (self.now, self.now))
            opened = []
            original_open = os.open
            def tracked_open(path, flags, *args, **kwargs):
                opened.append(pathlib.Path(path).name)
                return original_open(path, flags, *args, **kwargs)
            with mock.patch.object(crash.platform, "system", return_value="Darwin"), mock.patch.object(crash.os, "open", side_effect=tracked_open):
                result = crash.collect_owned_crash(43210, self.started, self.path, output,
                                                   directories=(root,), wait_seconds=0.2)
            self.assertEqual(result["status"], "verified_report_copied")
            self.assertEqual(opened, ["MoPanel-fixture.ips"])
            self.assertEqual((output / "smoke-own-crash.ips").read_bytes(), self.payload())


if __name__ == "__main__":
    unittest.main(verbosity=2)
