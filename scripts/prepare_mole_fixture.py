#!/usr/bin/env python3
"""Fetch an untouched official Mole checkout and verified release binaries for CI.

This is a build-time helper, never bundled/invoked as the user's installer.
No installer script, sudo, shell profile edit or cleanup is executed.
"""
import argparse
import hashlib
import json
import pathlib
import re
import subprocess
import urllib.request


def fetch(url):
    request = urllib.request.Request(url, headers={"User-Agent": "MoPanel-CI/0.1"})
    with urllib.request.urlopen(request, timeout=90) as response:
        return response.read()


def is_macos_stable(release):
    # The official repository also publishes Windows-specific tags. Do not
    # mistake its latest pointer for a macOS release if that pointer changes.
    return (not release.get("prerelease") and not release.get("draft")
            and re.fullmatch(r"V?\d+\.\d+(?:\.\d+)?", release.get("tag_name", "")) is not None)


def main():
    parser = argparse.ArgumentParser()
    selection = parser.add_mutually_exclusive_group(required=True)
    selection.add_argument("--tag")
    selection.add_argument("--latest", action="store_true")
    parser.add_argument("--directory", required=True, type=pathlib.Path)
    args = parser.parse_args()
    if args.latest:
        release = json.loads(fetch("https://api.github.com/repos/tw93/Mole/releases/latest"))
        if not is_macos_stable(release):
            releases = json.loads(fetch("https://api.github.com/repos/tw93/Mole/releases?per_page=30"))
            release = next((entry for entry in releases if is_macos_stable(entry)), None)
            if release is None:
                raise RuntimeError("No official stable macOS release was found")
        tag = release["tag_name"]
    else:
        tag = args.tag
    if not re.fullmatch(r"V?\d+\.\d+(?:\.\d+)?", tag):
        raise ValueError("Unexpected official stable release tag")
    destination = args.directory.resolve()
    if destination.exists():
        raise FileExistsError("Use a new empty CI fixture destination")
    subprocess.run(["git", "clone", "--depth", "1", "--branch", tag,
                    "https://github.com/tw93/Mole.git", str(destination)], check=True, timeout=120)
    commit = subprocess.check_output(["git", "-C", str(destination), "rev-parse", "HEAD"], text=True).strip()
    if tag == "V1.62.0" and commit != "91a7bf44f96995361b10b5a0e9efae36a1490bf9":
        raise RuntimeError("The audited V1.62.0 tag moved; review the upstream source before continuing")
    base = "https://github.com/tw93/Mole/releases/download/" + tag + "/"
    checksums_text = fetch(base + "SHA256SUMS").decode("utf-8")
    checksums = {}
    for line in checksums_text.splitlines():
        fields = line.split(maxsplit=1)
        if len(fields) == 2:
            checksums[fields[1].lstrip(" *")] = fields[0]
    for command in ("analyze", "status"):
        name = command + "-darwin-arm64"
        if name not in checksums:
            raise RuntimeError("Missing official checksum for " + name)
        data = fetch(base + name)
        if hashlib.sha256(data).hexdigest() != checksums[name]:
            raise RuntimeError("Checksum mismatch for " + name)
        output = destination / "bin" / (command + "-go")
        output.write_bytes(data)
        output.chmod(0o755)
    (destination / "MOPANEL_CI_SOURCE.json").write_text(json.dumps({"tag": tag, "commit": commit,
        "official_binaries_verified": True}, indent=2) + "\n")
    print(str(destination / "mo"))


if __name__ == "__main__":
    main()
