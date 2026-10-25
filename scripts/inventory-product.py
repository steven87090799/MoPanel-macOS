#!/usr/bin/env python3
"""Inventory first-party files and UI entry points; does not claim human review."""
import argparse
import hashlib
import json
import pathlib
import re
import subprocess


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=pathlib.Path, required=True)
    args = parser.parse_args()
    root = pathlib.Path(__file__).resolve().parent.parent
    names = subprocess.check_output(["git", "ls-files", "--cached", "--others", "--exclude-standard", "-z"], cwd=root).decode().split("\0")
    files, controls = [], []
    pattern = re.compile(r"\b(NativeActionButton|NativeAcknowledgementToggle|Button|Toggle|Picker|TextField|Stepper|Link|MenuBarExtra|CommandMenu)\s*(?:\(|\{)")
    for name in sorted(set(filter(None, names))):
        path = root / name
        if path.suffix not in (".swift", ".c", ".h", ".py", ".sh", ".yml") or not path.is_file():
            continue
        content = path.read_bytes()
        source = content.decode(errors="replace")
        files.append({"path": name, "sha256": hashlib.sha256(content).hexdigest(), "lines": len(source.splitlines()),
                      "review_status": "inventory_only; full line-by-line review pending"})
        if name.startswith("Sources/MoPanelApp/"):
            for match in pattern.finditer(source):
                controls.append({"path": name, "line": source.count("\n", 0, match.start()) + 1,
                                 "control": match.group(1), "excerpt": " ".join(source[match.start():].splitlines()[:3])[:260],
                                 "source_trace": "pending per-control verification; see PRODUCT_READINESS_AUDIT.md for verified feature groups",
                                 "test_status": "not individually verified in this audit"})
    result = {"base_commit": subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=root, text=True).strip(),
              "scope": "first-party source, tests, build scripts and workflow; excludes downloaded dependencies and generated binaries",
              "files": files, "ui_controls": controls, "file_count": len(files), "ui_control_count": len(controls),
              "limitation": "Syntax inventory is not proof of feature behavior, source attribution, coverage or a completed manual code audit."}
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(result, ensure_ascii=False, indent=2) + "\n")
    print(f"Inventoried {len(files)} files and {len(controls)} UI entry points: {args.output}")


if __name__ == "__main__":
    main()
