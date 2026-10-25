#!/usr/bin/env python3
"""Package only named validation outputs, never local exploratory reports."""
import argparse
import pathlib
import shutil

NAMES = frozenset('''architecture.txt xcode-version.txt swift-version.txt macos-version.txt dependencies.json
resolve.log build-guardian.log build-app.log build-editor.log swift-test.log validation-gates.json
validation-gate-harness.log smoke-driver-tests.log crash-evidence-tests.log debug-diagnostic-tests.log
release-report-tests.log control-pipe-sigpipe.json control-pipe-sigpipe.log bundle-verification.txt
smoke-run.log smoke-test.json smoke-test.stdout.log smoke-test.stderr.log smoke-window.png
release-app-tests.log performance.json performance-real-cli.json profile-harness-tests.log guardian-test.log cli-contract.json'''.split())
REQUIRED = frozenset(['swift-test.log', 'smoke-test.json', 'performance.json', 'validation-gates.json'])

def copy_reports(source, destination):
    missing = [name for name in REQUIRED if not (source / name).is_file() or (source / name).is_symlink()]
    if missing:
        raise RuntimeError('Missing current validation reports: ' + ', '.join(sorted(missing)))
    destination.mkdir(parents=True, exist_ok=True)
    for name in sorted(NAMES):
        path = source / name
        if path.is_file() and not path.is_symlink():
            shutil.copy2(path, destination / name)

if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('source', type=pathlib.Path)
    parser.add_argument('destination', type=pathlib.Path)
    args = parser.parse_args()
    copy_reports(args.source, args.destination)
