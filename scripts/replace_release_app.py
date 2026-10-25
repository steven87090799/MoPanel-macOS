#!/usr/bin/env python3
"""Replace a generated app bundle without merging resources from older builds."""
import argparse
import pathlib
import shutil
import subprocess
import tempfile


def replace_bundle(source, destination, verify=None):
    source, destination = pathlib.Path(source), pathlib.Path(destination)
    if not source.is_dir() or source.is_symlink() or destination.is_symlink():
        raise ValueError('Expected ordinary app bundle directories')
    if destination.exists() and not destination.is_dir():
        raise ValueError('Existing app destination is not a directory')
    destination.parent.mkdir(parents=True, exist_ok=True)
    if verify is None:
        verify = lambda path: subprocess.run(['codesign', '--verify', '--deep', '--strict', str(path)], check=True)
    with tempfile.TemporaryDirectory(prefix='.mopanel-release-', dir=destination.parent) as temporary:
        stage = pathlib.Path(temporary)
        fresh, previous = stage / destination.name, stage / 'previous.app'
        # copytree starts with a nonexistent destination. No stale Contents or
        # old SwiftPM resource-bundle layout can survive from a previous build.
        shutil.copytree(source, fresh, symlinks=True, copy_function=shutil.copy2)
        verify(fresh)
        had_previous = destination.exists()
        if had_previous: destination.rename(previous)
        try:
            fresh.rename(destination)
        except BaseException:
            if had_previous: previous.rename(destination)
            raise


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('source', type=pathlib.Path)
    parser.add_argument('destination', type=pathlib.Path)
    args = parser.parse_args()
    replace_bundle(args.source, args.destination)
