#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Bounded checks of actual first-party sources, for hosts without XCTest/Xcode.
set -euo pipefail
mopanel_root="$(cd "$(dirname "$0")/.." && pwd)"
mopanel_probe_root="$(mktemp -d "${TMPDIR:-/tmp}/mopanel-monitoring-probe.XXXXXX")"
trap 'rm -rf "$mopanel_probe_root"' EXIT
mopanel_process_source="$mopanel_root/Sources/MoPanelProcess/ManagedProcess.swift"
mopanel_probe_mode=all
if [ "$#" -gt 0 ]; then
    if [ "$#" -ne 2 ] || [ "$1" != --process-source-ref ]; then
        printf 'Usage: bash scripts/probe-monitoring.sh [--process-source-ref COMMIT]\n' >&2
        exit 2
    fi
    mopanel_baseline="$(git -C "$mopanel_root" rev-parse --verify --end-of-options "$2^{commit}")"
    git -C "$mopanel_root" show "$mopanel_baseline:Sources/MoPanelProcess/ManagedProcess.swift" > "$mopanel_probe_root/ManagedProcess.swift"
    mopanel_process_source="$mopanel_probe_root/ManagedProcess.swift"
    mopanel_probe_mode=stream
fi
if [ "$(uname -s)" = Linux ]; then
    cc -O2 "$mopanel_root/Sources/MoPanelGuardian/main.c" -lutil -o "$mopanel_probe_root/MoPanelGuardian"
else
    cc -O2 "$mopanel_root/Sources/MoPanelGuardian/main.c" -o "$mopanel_probe_root/MoPanelGuardian"
fi
swiftc -swift-version 5 -O -parse-as-library \
    "$mopanel_root/Sources/MoPanelCore/NativeControlPolicy.swift" \
    "$mopanel_root/Sources/MoPanelCore/MonitoringPreferences.swift" \
    "$mopanel_root/Sources/MoPanelCore/StatusTimestampDisplay.swift" \
    "$mopanel_process_source" "$mopanel_root/scripts/probe_monitoring.swift" \
    -o "$mopanel_probe_root/probe"
MOPANEL_GUARDIAN="$mopanel_probe_root/MoPanelGuardian" "$mopanel_probe_root/probe" "$mopanel_probe_mode"
