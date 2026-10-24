#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Fail closed: a distributable is produced only after real Apple ARM64 build/tests.
set -euo pipefail
project_root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$project_root"
if [[ "$(uname -s)" != Darwin || "$(uname -m)" != arm64 ]]; then
    echo "MoPanel release packaging requires an Apple Silicon Mac with Xcode 27+." >&2
    exit 1
fi
sdk_version="$(xcrun --sdk macosx --show-sdk-version)"
if [[ "${sdk_version%%.*}" -lt 27 ]]; then
    echo "macOS SDK 27 or newer is required; found $sdk_version." >&2
    exit 1
fi
export MACOSX_DEPLOYMENT_TARGET=27.0
mkdir -p build/reports build/releases
source scripts/validation-gates.sh
python3 scripts/test_validation_gates.py 2>&1 | tee build/reports/validation-gate-harness.log
python3 scripts/test_smoke_driver.py 2>&1 | tee build/reports/smoke-driver-tests.log
python3 scripts/test_crash_evidence.py 2>&1 | tee build/reports/crash-evidence-tests.log
python3 scripts/test_debug_smoke_failure.py 2>&1 | tee build/reports/debug-diagnostic-tests.log
mopanel_initialize_validation_gates build/reports/validation-gates.json
build_staging="$(mktemp -d "$project_root/build/staging.XXXXXX")"
trap 'rm -rf "$build_staging"' EXIT
xcodebuild -version > build/reports/xcode-version.txt
xcrun swift --version > build/reports/swift-version.txt
sw_vers > build/reports/macos-version.txt
uname -m > build/reports/architecture.txt
xcrun swift package resolve 2>&1 | tee build/reports/resolve.log
python3 - <<'PY'
import json, pathlib
resolved = json.loads(pathlib.Path('Package.resolved').read_text())
pins = {p['identity']: p for p in resolved['pins']}
pin = pins['swiftterm']['state']
assert pin['revision'] == '5d14406844143538cd8f8851d2d8a67c1fe443e5', 'SwiftTerm source revision changed; review before building'
assert pin.get('version') == '1.20.0', 'Unexpected SwiftTerm version'
pathlib.Path('build/reports/dependencies.json').write_text(json.dumps(resolved, indent=2) + '\n')
PY
xcrun swift build --configuration release --arch arm64 --product MoPanelGuardian 2>&1 | tee build/reports/build-guardian.log
binary_dir="$(xcrun swift build --configuration release --arch arm64 --show-bin-path)"
mopanel_capture_validation_gate build/reports/validation-gates.json swift-test build/reports/swift-test.log \
    env MOPANEL_GUARDIAN="$binary_dir/MoPanelGuardian" xcrun swift test --arch arm64
xcrun swift build --configuration release --arch arm64 --product MoPanel 2>&1 | tee build/reports/build-app.log
xcrun swift build --configuration release --arch arm64 --product MoPanelEditor 2>&1 | tee build/reports/build-editor.log
app_path="$build_staging/MoPanel.app"
mkdir -p "$app_path/Contents/MacOS" "$app_path/Contents/Resources" "$app_path/Contents/Helpers"
install -m 755 "$binary_dir/MoPanel" "$app_path/Contents/MacOS/MoPanel"
install -m 755 "$binary_dir/MoPanelGuardian" "$app_path/Contents/Helpers/MoPanelGuardian"
install -m 755 "$binary_dir/MoPanelEditor" "$app_path/Contents/Helpers/MoPanelEditor"
cp Resources/Info.plist "$app_path/Contents/Info.plist"
printf 'APPL????' > "$app_path/Contents/PkgInfo"
shopt -s nullglob
for resource in "$binary_dir"/*.bundle; do
    ditto "$resource" "$app_path/Contents/Resources/$(basename "$resource")"
done
# GitHub contents uploads and SwiftPM copies may normalize a resource's mode.
# Only this known safe test fixture receives executable permission.
fixture_count=0
for fixture in "$app_path/Contents/Resources/"*.bundle/Fixtures/mock-mo.sh "$app_path/Contents/Resources/"*.bundle/Contents/Resources/Fixtures/mock-mo.sh; do
    chmod 755 "$fixture"
    fixture_count=$((fixture_count + 1))
done
test "$fixture_count" -eq 1
xcrun swift scripts/create_icon.swift "$build_staging/MoPanel.iconset"
iconutil --convert icns --output "$app_path/Contents/Resources/MoPanel.icns" "$build_staging/MoPanel.iconset"
cp LICENSE THIRD_PARTY_NOTICES.md "$app_path/Contents/Resources/"
if [[ -d ThirdParty ]]; then
    ditto ThirdParty "$app_path/Contents/Resources/ThirdParty"
fi
# Ad-hoc identity is deliberate. This is not Developer ID signing/notarization.
codesign --force --sign - --options runtime --identifier org.mopanel.guardian "$app_path/Contents/Helpers/MoPanelGuardian"
codesign --force --sign - --options runtime --identifier org.mopanel.editor "$app_path/Contents/Helpers/MoPanelEditor"
codesign --force --sign - --options runtime --identifier org.mopanel.app "$app_path"
bash scripts/verify-package.sh "$app_path" > build/reports/bundle-verification.txt 2>&1
mopanel_capture_validation_gate build/reports/validation-gates.json fixture-smoke build/reports/smoke-run.log \
    python3 scripts/smoke_test.py "$app_path" --output build/reports/smoke-test.json
# Both independently collected outcomes must pass, including tee and skip checks.
# A failed gate can never proceed to benchmarks, official CLI probes or packaging.
mopanel_require_validation_gates build/reports/validation-gates.json
python3 scripts/test_profile.py 2>&1 | tee build/reports/profile-harness-tests.log
python3 scripts/profile.py "$app_path" --output build/reports/performance.json
python3 scripts/test_guardian.py "$app_path/Contents/Helpers/MoPanelGuardian" 2>&1 | tee build/reports/guardian-test.log
# Safe read-only CLI compatibility probes are optional locally and mandatory in CI.
if [[ -n "${MOPANEL_AUDIT_CLI:-}" ]]; then
    python3 scripts/audit_cli.py "$MOPANEL_AUDIT_CLI" --output build/reports/cli-contract.json
    if [[ "${CI:-}" == true && "${GITHUB_ACTIONS:-}" == true ]]; then
        python3 scripts/profile.py "$app_path" --real-cli "$MOPANEL_AUDIT_CLI" --output build/reports/performance-real-cli.json
    fi
elif [[ "${CI:-}" == true && "${GITHUB_ACTIONS:-}" == true ]]; then
    echo "CI release requires the verified official baseline for read-only acceptance and real-engine measurements." >&2
    exit 1
fi
package_path="$build_staging/distribution"
mkdir -p "$package_path/Source" "$package_path/Reports"
ditto "$app_path" "$package_path/MoPanel.app"
for document in README.md CHANGELOG.md COMPATIBILITY.md CLI_COVERAGE.md TEST_REPORT.md LICENSE THIRD_PARTY_NOTICES.md; do
    cp "$document" "$package_path/$document"
done
# Explicit source inventory avoids copying build caches, local binaries or secrets.
for source_dir in Sources Tests Resources scripts docs ThirdParty .github; do
    rsync -a --exclude '__pycache__' --exclude '.DS_Store' "$source_dir" "$package_path/Source/"
done
for source_file in Package.swift Package.resolved .gitignore README.md CHANGELOG.md COMPATIBILITY.md CLI_COVERAGE.md TEST_REPORT.md LICENSE THIRD_PARTY_NOTICES.md; do
    if [[ -f "$source_file" ]]; then cp "$source_file" "$package_path/Source/"; fi
done
# Include the exact dependency sources and their original licenses alongside
# the linked binary. Do not include Git metadata or dependency build caches.
mkdir -p "$package_path/Source/Vendor"
dependency_count=0
for checkout in "$project_root/.build/checkouts/"*; do
    if [[ -d "$checkout" ]]; then
        rsync -a --exclude '.git' --exclude '.build' --exclude '.DS_Store' \
            --exclude '__pycache__' "$checkout" "$package_path/Source/Vendor/"
        dependency_count=$((dependency_count + 1))
    fi
done
test "$dependency_count" -ge 1
cat > "$package_path/Source/Vendor/README-MoPanel.txt" <<'EOF'
These are the exact SwiftPM dependency source checkouts used for this build,
including their original license files. Package.resolved and Reports/dependencies.json
record revisions. The main Package.swift retains official upstream URLs; these
copies are corresponding-source references, not a claim of an offline build setup.
SwiftTerm is linked into MoPanel. Swift Argument Parser and documentation plugins
may be resolved by SwiftTerm's package manifest without being linked into MoPanel.
No official Mole cleanup engine is bundled here.
EOF
ditto build/reports "$package_path/Reports"
python3 scripts/write_release_report.py "$package_path"
python3 scripts/write_build_manifest.py "$package_path"
archive="$project_root/build/releases/MoPanel-macOS27-arm64.zip"
staged_archive="$build_staging/MoPanel-macOS27-arm64.zip"
ditto -c -k --sequesterRsrc "$package_path" "$staged_archive"
bash scripts/verify-package.sh "$staged_archive" > build/reports/zip-verification.txt 2>&1
mv "$staged_archive" "$archive"
(cd build/releases && shasum -a 256 MoPanel-macOS27-arm64.zip > SHA256SUMS.txt)
ditto "$app_path" "$project_root/build/releases/MoPanel.app"
echo "Verified artifact: $archive"
cat build/releases/SHA256SUMS.txt
