#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Preserve command/tee failures and refuse later phases until both gates pass."""
import argparse
import datetime
import json
import pathlib
import re

REQUIRED = {"swift-test", "fixture-smoke"}


def timestamp():
    return datetime.datetime.now(datetime.timezone.utc).isoformat()


def save(path, value):
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_suffix(path.suffix + ".tmp")
    temporary.write_text(json.dumps(value, ensure_ascii=False, indent=2) + "\n")
    temporary.replace(path)


def read(path):
    value = json.loads(path.read_text())
    if value.get("schema_version") != 1 or set(value.get("required_gates", [])) != REQUIRED or not isinstance(value.get("gates"), dict):
        raise ValueError("Invalid independent validation gate summary")
    return value


def record(path, name, log, pipeline_exit, command_exit, tee_exit):
    value = read(path)
    if name not in REQUIRED or name in value["gates"]:
        raise ValueError("Unknown or duplicate validation gate")
    reasons = []
    if pipeline_exit != 0:
        reasons.append("pipeline_nonzero")
    if command_exit != 0:
        reasons.append("command_nonzero")
    if tee_exit != 0:
        reasons.append("tee_nonzero")
    skipped = None
    if name == "swift-test":
        try:
            text = log.read_text(errors="replace")
            summaries = re.findall(r"Executed (\d+) tests?, with (\d+) failures?", text)
            skipped_summaries = re.findall(r"Executed (\d+) tests?, with (\d+) tests? skipped and (\d+) failures?", text)
            skipped = max((int(n) for _, n, _ in skipped_summaries), default=0)
            summaries += [(count, failures) for count, _, failures in skipped_summaries]
            if not summaries:
                reasons.append("missing_xctest_summary")
            elif any(int(failures) != 0 for _, failures in summaries):
                reasons.append("xctest_failures")
            if skipped:
                reasons.append("xctest_skipped")
        except OSError as error:
            reasons.append("unreadable_xctest_log")
    value["gates"][name] = {
        "recorded_at": timestamp(), "pipeline_exit_code": pipeline_exit,
        "command_exit_code": command_exit, "tee_exit_code": tee_exit,
        "log": str(log), "swift_skipped_count": skipped,
        "passed": not reasons, "failure_reasons": reasons,
    }
    value["all_required_passed"] = set(value["gates"]) == REQUIRED and all(gate.get("passed") is True for gate in value["gates"].values())
    save(path, value)
    print("Recorded", name, "PASS" if not reasons else "FAIL", "pipeline=", pipeline_exit,
          "command=", command_exit, "tee=", tee_exit)


def require(path):
    value = read(path)
    passed = (set(value["gates"]) == REQUIRED and value.get("all_required_passed") is True
              and all(gate.get("passed") is True and gate.get("pipeline_exit_code") == 0
                      and gate.get("command_exit_code") == 0 and gate.get("tee_exit_code") == 0
                      for gate in value["gates"].values()))
    if not passed:
        failed = {name: value["gates"].get(name, {"failure_reasons": ["not_executed"]})
                  for name in sorted(REQUIRED) if value["gates"].get(name, {}).get("passed") is not True}
        print("STOP: independent XCTest/fixture-UI validation gates failed; no performance, guardian acceptance, official CLI execution or release packaging will follow.")
        print(json.dumps(failed, ensure_ascii=False))
        raise SystemExit(1)
    print("PASS: both independent XCTest and fixture-only UI gates; later acceptance phases may proceed.")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="action", required=True)
    for name in ("initialize", "require"):
        commands.add_parser(name).add_argument("summary", type=pathlib.Path)
    command = commands.add_parser("record")
    command.add_argument("summary", type=pathlib.Path)
    command.add_argument("gate", choices=sorted(REQUIRED))
    command.add_argument("log", type=pathlib.Path)
    command.add_argument("pipeline_exit", type=int)
    command.add_argument("command_exit", type=int)
    command.add_argument("tee_exit", type=int)
    args = parser.parse_args()
    if args.action == "initialize":
        save(args.summary, {"schema_version": 1, "started_at": timestamp(), "required_gates": sorted(REQUIRED),
                            "gates": {}, "all_required_passed": False,
                            "scope": "Independent XCTest and fixture-only UI collection; both must pass before remaining acceptance or packaging."})
    elif args.action == "record":
        record(args.summary, args.gate, args.log, args.pipeline_exit, args.command_exit, args.tee_exit)
    else:
        require(args.summary)


if __name__ == "__main__":
    main()
