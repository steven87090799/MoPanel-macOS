#!/usr/bin/env python3
"""Create a clearly labelled source-review ZIP; never an App release substitute."""
import argparse
import hashlib
import pathlib
import stat
import zipfile

parser = argparse.ArgumentParser()
parser.add_argument("--output", required=True, type=pathlib.Path)
args = parser.parse_args()
root = pathlib.Path(__file__).resolve().parent.parent
output = args.output.resolve()
if output.name == "MoPanel-macOS27-arm64.zip" or "source" not in output.name.lower():
    parser.error("A source-only ZIP must have 'source' in its name and cannot use the App release filename")
directories = ("Sources", "Tests", "Resources", "scripts", "docs", "ThirdParty", ".github")
documents = ("Package.swift", "Package.resolved", ".gitignore", "README.md", "CHANGELOG.md", "COMPATIBILITY.md",
             "CLI_COVERAGE.md", "TEST_REPORT.md", "LICENSE", "THIRD_PARTY_NOTICES.md")
files = [root / name for name in documents if (root / name).is_file()]
for name in directories:
    files += [path for path in (root / name).rglob("*") if path.is_file()
              and not path.is_symlink() and "__pycache__" not in path.parts
              and path.name != ".DS_Store"]
output.parent.mkdir(parents=True, exist_ok=True)
with zipfile.ZipFile(output, "w", zipfile.ZIP_DEFLATED, compresslevel=9) as archive:
    archive.writestr("MoPanel/SOURCE_ONLY.txt", "SOURCE REVIEW PACKAGE ONLY\n"
                     "This archive contains source code and actual test evidence.\n"
                     "It is NOT the compiled MoPanel macOS App ZIP.\n"
                     "Read TEST_REPORT.md for the remaining macOS build/validation requirements.\n")
    for path in sorted(files):
        archive.write(path, "MoPanel/" + path.relative_to(root).as_posix())
with zipfile.ZipFile(output) as archive:
    bad_file = archive.testzip()
    if bad_file:
        raise RuntimeError("Corrupt source archive entry: " + bad_file)
digest = hashlib.sha256(output.read_bytes()).hexdigest()
output.with_suffix(output.suffix + ".sha256").write_text(digest + "  " + output.name + "\n")
print(f"SOURCE ONLY: {output}\nSHA-256: {digest}\nFiles: {len(files)}")
