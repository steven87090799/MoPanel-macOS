#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
set -euo pipefail
input_path="${1:?Pass a MoPanel.app bundle or release ZIP}"
if [[ "$(uname -s)" != Darwin ]]; then
    echo "Apple codesign/lipo verification requires macOS." >&2
    exit 1
fi
unpack_dir=""
trap 'if [[ -n "$unpack_dir" ]]; then rm -rf "$unpack_dir"; fi' EXIT
if [[ "$input_path" == *.zip ]]; then
    unzip -t "$input_path"
    unpack_dir="$(mktemp -d "${TMPDIR:-/tmp}/mopanel-verify.XXXXXX")"
    ditto -x -k "$input_path" "$unpack_dir"
    app_path="$unpack_dir/MoPanel.app"
    for item in README.md CHANGELOG.md COMPATIBILITY.md CLI_COVERAGE.md TEST_REPORT.md LICENSE THIRD_PARTY_NOTICES.md Source/Package.swift BUILD_MANIFEST.json; do
        test -s "$unpack_dir/$item"
    done
    python3 - "$unpack_dir" <<'PY'
import hashlib, json, pathlib, sys
root = pathlib.Path(sys.argv[1])
manifest = json.loads((root / 'BUILD_MANIFEST.json').read_text())
for item in manifest['files']:
    path = root / item['path']
    assert path.is_file(), f"Missing {path}"
    assert hashlib.sha256(path.read_bytes()).hexdigest() == item['sha256'], f"Hash mismatch {path}"
print(f"Manifest: verified {len(manifest['files'])} files")
PY
else
    app_path="$input_path"
fi
test -d "$app_path"
plutil -lint "$app_path/Contents/Info.plist"
test "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$app_path/Contents/Info.plist")" = MoPanel
test "$(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' "$app_path/Contents/Info.plist")" = 27.0
test -s "$app_path/Contents/Resources/MoPanel.icns"
for executable in "$app_path/Contents/MacOS/MoPanel" "$app_path/Contents/Helpers/MoPanelGuardian" "$app_path/Contents/Helpers/MoPanelEditor"; do
    test -x "$executable"
    architecture="$(lipo -archs "$executable")"
    test "$architecture" = arm64
    file "$executable"
    codesign --verify --strict --verbose=4 "$executable"
done
codesign --verify --deep --strict --verbose=4 "$app_path"
codesign -dv --verbose=4 "$app_path" 2>&1
echo 'Gatekeeper assessment (ad-hoc builds may be rejected; no security settings changed):'
if spctl --assess --type execute --verbose=4 "$app_path"; then
    echo 'Gatekeeper assessment accepted in this environment.'
else
    echo 'Gatekeeper did not accept this ad-hoc build. This is not a notarized distribution.'
fi
echo 'PASS: bundle layout, ARM64 executables, signature integrity, and requested archive checks.'
