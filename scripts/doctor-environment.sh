#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Read-only checks. Run through dev-run.sh to select the project environment.
set -uo pipefail
mopanel_missing=0
for mopanel_tool in git python3 gh jq go shellcheck rg mas; do
    if command -v "$mopanel_tool" >/dev/null 2>&1; then
        printf 'OK   %s: %s\n' "$mopanel_tool" "$(command -v "$mopanel_tool")"
    else
        printf 'MISS %s\n' "$mopanel_tool"
        mopanel_missing=$((mopanel_missing + 1))
    fi
done
if xcodebuild -version 2>/dev/null; then
    printf 'OK   Full Xcode\n'
else
    printf 'MISS Full Xcode; install Xcode and complete its first launch\n'
    mopanel_missing=$((mopanel_missing + 1))
fi
for mopanel_tool in swift xctest xctrace; do
    if mopanel_location="$(xcrun --find "$mopanel_tool" 2>/dev/null)"; then
        printf 'OK   %s: %s\n' "$mopanel_tool" "$mopanel_location"
    else
        printf 'MISS %s\n' "$mopanel_tool"
        mopanel_missing=$((mopanel_missing + 1))
    fi
done
if xcrun --sdk macosx metal --version 2>/dev/null; then
    printf 'OK   Metal Toolchain\n'
else
    printf 'MISS Metal Toolchain; run xcodebuild -downloadComponent MetalToolchain with full Xcode\n'
    mopanel_missing=$((mopanel_missing + 1))
fi
if mopanel_sdk="$(xcrun --sdk macosx --show-sdk-version 2>/dev/null)"; then
    printf 'SDK  macOS %s\n' "$mopanel_sdk"
    if [ "${mopanel_sdk%%.*}" -lt 27 ]; then mopanel_missing=$((mopanel_missing + 1)); fi
else
    printf 'MISS macOS SDK\n'
    mopanel_missing=$((mopanel_missing + 1))
fi
printf 'Missing checks: %s\n' "$mopanel_missing"
[ "$mopanel_missing" -eq 0 ]
