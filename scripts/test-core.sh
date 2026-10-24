#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Test first-party code without resolving UI packages. Requires XCTest.
set -euo pipefail
mopanel_root="$(cd "$(dirname "$0")/.." && pwd)"
if ! printf 'import XCTest\n' | swiftc -typecheck - >/dev/null 2>&1; then
    printf 'XCTest is unavailable. Select full Xcode for this command with DEVELOPER_DIR, or run scripts/probe-monitoring.sh for bounded standalone checks.\n' >&2
    exit 2
fi
mopanel_test_root="$(mktemp -d "${TMPDIR:-/tmp}/mopanel-core-tests.XXXXXX")"
trap 'rm -rf "$mopanel_test_root"' EXIT
mkdir -p "$mopanel_test_root/Sources" "$mopanel_test_root/Tests"
for mopanel_target in MoPanelCore MoPanelProcess MoPanelGuardian; do
    cp -R "$mopanel_root/Sources/$mopanel_target" "$mopanel_test_root/Sources/"
done
for mopanel_target in MoPanelCoreTests MoPanelProcessTests; do
    cp -R "$mopanel_root/Tests/$mopanel_target" "$mopanel_test_root/Tests/"
done
cat > "$mopanel_test_root/Package.swift" <<'SWIFT'
// swift-tools-version: 6.0
import PackageDescription
let package = Package(name: "MoPanelCoreValidation", platforms: [.macOS("27.0")], targets: [
    .target(name: "MoPanelCore"), .target(name: "MoPanelProcess"),
    .executableTarget(name: "MoPanelGuardian", linkerSettings: [.linkedLibrary("util", .when(platforms: [.linux]))]),
    .testTarget(name: "MoPanelCoreTests", dependencies: ["MoPanelCore"], resources: [.copy("Fixtures")]),
    .testTarget(name: "MoPanelProcessTests", dependencies: ["MoPanelProcess"])
], swiftLanguageModes: [.v5])
SWIFT
swift build --package-path "$mopanel_test_root" --build-system native --product MoPanelGuardian --jobs 2
mopanel_test_bin="$(swift build --package-path "$mopanel_test_root" --build-system native --show-bin-path)"
MOPANEL_GUARDIAN="$mopanel_test_bin/MoPanelGuardian" \
    swift test --package-path "$mopanel_test_root" --build-system native --jobs 2 "$@"
