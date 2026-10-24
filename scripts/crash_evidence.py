#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Collect only a recent, positively identified crash report for our own MoPanel PID."""
import datetime
import hashlib
import itertools
import json
import os
import pathlib
import platform
import re
import stat
import time

MAX_FILE = 5 * 1024 * 1024
MAX_TOTAL = 16 * 1024 * 1024


def verified_identity(name, data, pid, started, modified, now, executable):
    if (not name.startswith(("MoPanel-", "MoPanel_", "MoPanel."))
            or pathlib.Path(name).suffix not in {".ips", ".crash"}
            or not started - 1 <= modified <= now + 1 or not 0 < len(data) <= MAX_FILE):
        return None
    try:
        text = data.decode("utf-8", errors="strict")
        if name.endswith(".ips"):
            decoder = json.JSONDecoder()
            first, end = decoder.raw_decode(text.lstrip())
            remainder = text.lstrip()[end:].lstrip()
            if remainder:
                body, end = decoder.raw_decode(remainder)
                if remainder[end:].strip():
                    return None
            else:
                body = first
            if not isinstance(first, dict) or not isinstance(body, dict):
                return None
            report_pid = body.get("pid")
            process_name = body.get("procName")
            if process_name != "MoPanel" or type(report_pid) is not int or report_pid != pid:
                return None
            if first.get("app_name", "MoPanel") != "MoPanel":
                return None
            bundle = first.get("bundleID", body.get("bundleInfo", {}).get("CFBundleIdentifier"))
            if bundle is not None and bundle != "org.mopanel.app":
                return None
            crash_time = first.get("timestamp", body.get("captureTime"))
            process_path = body.get("procPath")
        else:
            process = re.search(r"^Process:\s+MoPanel\s+\[(\d+)\]\s*$", text, re.MULTILINE)
            stamp = re.search(r"^Date/Time:\s*(.+)$", text, re.MULTILINE)
            path = re.search(r"^Path:\s*(.+)$", text, re.MULTILINE)
            if not process or int(process.group(1)) != pid or not stamp:
                return None
            crash_time = stamp.group(1).strip()
            process_path = path.group(1).strip() if path else None
        if not isinstance(crash_time, str):
            return None
        date = datetime.datetime.fromisoformat(crash_time.replace("Z", "+00:00"))
        if date.tzinfo is None or not started - 2 <= date.timestamp() <= now + 1:
            return None
        if process_path is not None and (not isinstance(process_path, str)
                or os.path.realpath(process_path) != os.path.realpath(executable)):
            return None
        return {"process": "MoPanel", "pid": pid, "crash_timestamp": crash_time,
                "filename_mtime_pid_and_process_confirmed": True}
    except (ValueError, TypeError, AttributeError, RecursionError):
        return None


def collect_owned_crash(pid, started, executable, output_directory, *, directories=None, wait_seconds=4):
    result = {"attempted": False, "files": [], "other_app_reports_read": False,
              "security_settings_changed": False}
    if platform.system() != "Darwin":
        return {**result, "reason": "requires_macos"}
    result.update(attempted=True, owner_pid=pid, maximum_wait_seconds=wait_seconds)
    directories = directories or (pathlib.Path.home() / "Library/Logs/DiagnosticReports",
                                  pathlib.Path("/Library/Logs/DiagnosticReports"))
    deadline = time.monotonic() + wait_seconds
    seen, examined, total = set(), 0, 0
    while True:
        for directory in directories:
            for suffix in (".ips", ".crash"):
                try:
                    candidates = itertools.islice(directory.glob("MoPanel*" + suffix), 64)
                    for source in candidates:
                        if examined >= 64 or total >= MAX_TOTAL or time.monotonic() > deadline:
                            break
                        if not source.name.startswith(("MoPanel-", "MoPanel_", "MoPanel.")):
                            continue
                        metadata = source.lstat()
                        if not stat.S_ISREG(metadata.st_mode) or not started - 1 <= metadata.st_mtime <= time.time() + 1:
                            continue
                        key = (str(source), metadata.st_size, metadata.st_mtime_ns)
                        if key in seen or not 0 < metadata.st_size <= min(MAX_FILE, MAX_TOTAL - total):
                            continue
                        seen.add(key); examined += 1
                        fd = os.open(source, os.O_RDONLY | os.O_NOFOLLOW | os.O_CLOEXEC)
                        with os.fdopen(fd, "rb") as stream:
                            current = os.fstat(stream.fileno())
                            if (current.st_dev, current.st_ino, current.st_size, current.st_mtime_ns) != (metadata.st_dev, metadata.st_ino, metadata.st_size, metadata.st_mtime_ns):
                                continue
                            data = stream.read(MAX_FILE + 1)
                        total += len(data)
                        identity = verified_identity(source.name, data, pid, started, metadata.st_mtime,
                                                     time.time(), executable)
                        if identity:
                            destination = output_directory / ("smoke-own-crash" + suffix)
                            destination.write_bytes(data)
                            result.update(status="verified_report_copied", candidates_examined=examined, bytes_read=total)
                            result["files"].append({"file": destination.name, "sha256": hashlib.sha256(data).hexdigest(),
                                                    "bytes": len(data), **identity})
                            return result
                except OSError:
                    # No elevation or reading around access restrictions.
                    continue
        if time.monotonic() >= deadline or examined >= 64 or total >= MAX_TOTAL:
            break
        time.sleep(min(0.2, max(0, deadline - time.monotonic())))
    return {**result, "status": "no_confirmed_report", "candidates_examined": examined, "bytes_read": total}
