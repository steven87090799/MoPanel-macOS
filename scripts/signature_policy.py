#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Release bundles must never contain the temporary debugger entitlement."""
import plistlib
import subprocess
import sys


def require_release_entitlements(path, run=subprocess.run):
    result = run(["/usr/bin/codesign", "--display", "--entitlements", ":-", str(path)],
                 check=True, capture_output=True, timeout=8)
    raw = result.stdout.strip()
    values = plistlib.loads(raw) if raw else {}
    if not isinstance(values, dict) or "com.apple.security.get-task-allow" in values:
        raise RuntimeError("Debug entitlement is forbidden in a release executable")
    return True


if __name__ == "__main__":
    for path in sys.argv[1:]:
        require_release_entitlements(path)
    print("PASS: no get-task-allow entitlement in release executables")
