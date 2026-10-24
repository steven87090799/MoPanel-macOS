#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Observe the installed Homebrew read-only contract on macOS GitHub CI.

No update, install, upgrade, app launch, shell interpolation, token forwarding,
or arbitrary executable override is available. Reports omit app inventories and
raw output. A missing Homebrew is explicitly unavailable, never a passing audit.
"""
import argparse
import datetime
import hashlib
import json
import os
import pathlib
import platform
import pwd
import re
import selectors
import signal
import subprocess
import tempfile
import time


BREW = pathlib.Path("/opt/homebrew/bin/brew")
MAX_OUTPUT = 16 * 1024 * 1024
PROTECTIVE_ENV = {
    "HOMEBREW_NO_ANALYTICS": "1",
    "HOMEBREW_NO_AUTO_UPDATE": "1",
    "HOMEBREW_NO_INSTALL_CLEANUP": "1",
    "HOMEBREW_NO_INSTALLED_DEPENDENTS_CHECK": "1",
}
ALLOWED = frozenset({
    ("--version",),
    ("info", "--help"), ("outdated", "--help"),
    ("upgrade", "--help"), ("update", "--help"),
    ("info", "--json=v2", "--cask", "--installed"),
    ("outdated", "--cask", "--json=v2"),
})


class AuditFailure(Exception):
    """Contains only a fixed audit reason, never raw command output."""


def safe_environment():
    account = pwd.getpwuid(os.getuid())
    return {
        "HOME": account.pw_dir, "USER": account.pw_name, "LOGNAME": account.pw_name,
        "PATH": "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin",
        "LANG": "en_US.UTF-8", "LC_ALL": "en_US.UTF-8", "TERM": "dumb", "NO_COLOR": "1",
        "SHELL": "/bin/zsh", "TMPDIR": tempfile.gettempdir(), **PROTECTIVE_ENV,
    }


def stop_group(process):
    """Only used for this audit's read-only child process group."""
    try:
        os.killpg(process.pid, signal.SIGTERM)
    except ProcessLookupError:
        return
    deadline = time.monotonic() + 2
    while time.monotonic() < deadline:
        process.poll()
        try:
            os.killpg(process.pid, 0)
        except ProcessLookupError:
            break
        time.sleep(0.05)
    else:
        try:
            os.killpg(process.pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
    if process.poll() is None:
        process.wait(timeout=3)


def bounded_output(process, timeout, limit=MAX_OUTPUT):
    """Drain both pipes incrementally; no unbounded communicate/readline call."""
    buffers = {"stdout": bytearray(), "stderr": bytearray()}
    deadline = time.monotonic() + timeout
    try:
        with selectors.DefaultSelector() as selector:
            for name in buffers:
                pipe = getattr(process, name)
                os.set_blocking(pipe.fileno(), False)
                selector.register(pipe, selectors.EVENT_READ, name)
            while selector.get_map():
                remaining = deadline - time.monotonic()
                if remaining <= 0:
                    raise AuditFailure("command_timeout")
                for key, _ in selector.select(timeout=min(0.5, remaining)):
                    try:
                        chunk = os.read(key.fileobj.fileno(), 65536)
                    except (BlockingIOError, InterruptedError):
                        continue
                    if not chunk:
                        selector.unregister(key.fileobj)
                        continue
                    if len(buffers["stdout"]) + len(buffers["stderr"]) + len(chunk) > limit:
                        raise AuditFailure("command_output_limit")
                    buffers[key.data].extend(chunk)
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                raise AuditFailure("command_timeout")
            try:
                process.wait(timeout=remaining)
            except subprocess.TimeoutExpired as error:
                raise AuditFailure("command_timeout") from error
        return bytes(buffers["stdout"]), bytes(buffers["stderr"])
    finally:
        # A launcher may have exited while descendants still hold its pipes.
        # The owned process group, not only the direct parent, must be stopped.
        stop_group(process)
        for name in buffers:
            getattr(process, name).close()


def invoke(arguments, reports, timeout=120, limit=MAX_OUTPUT):
    arguments = tuple(arguments)
    if arguments not in ALLOWED:
        raise AuditFailure("command_outside_read_only_allowlist")
    record = {"executable": str(BREW), "arguments": list(arguments), "status": "started"}
    reports.append(record)
    started = time.monotonic()
    try:
        process = subprocess.Popen([str(BREW), *arguments], stdin=subprocess.DEVNULL,
                                   stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                   start_new_session=True, env=safe_environment())
        stdout, stderr = bounded_output(process, timeout, limit)
        record.update(exit_code=process.returncode, stdout_bytes=len(stdout), stderr_bytes=len(stderr))
        if process.returncode != 0:
            raise AuditFailure("command_nonzero_exit")
        record["status"] = "passed"
        return stdout
    except AuditFailure as error:
        record["status"] = str(error)
        raise
    except OSError as error:
        record.update(status="command_launch_failed", errno=error.errno)
        raise AuditFailure("command_launch_failed") from error
    finally:
        record["duration_seconds"] = round(time.monotonic() - started, 4)


def flags(text):
    return set(re.findall(r"(?<![A-Za-z0-9_-])--[a-z][a-z0-9-]*", text))


def help_contract(helps):
    required = {"info": {"--json", "--cask", "--installed"},
                "outdated": {"--json", "--cask"},
                "upgrade": {"--cask", "--dry-run", "--no-quit", "--require-sha"}}
    missing = {name: sorted(expected - flags(helps[name])) for name, expected in required.items()}
    version_two = all("v2" in helps[name] for name in ("info", "outdated"))
    read = not missing["info"] and not missing["outdated"] and version_two
    return {"read_contract_compatible": read,
            "upgrade_contract_compatible": read and not missing["upgrade"],
            "metadata_refresh_help_recognized": "brew update" in helps["update"] and "Homebrew" in helps["update"],
            "required_flags_observed": {name: sorted(flags(helps[name]) & expected) for name, expected in required.items()},
            "missing_required_flags": missing, "json_v2_documented": version_two}


def valid_text(value):
    return isinstance(value, str) and 0 < len(value.encode("utf-8")) <= 32768 and all(ord(c) >= 32 and not 127 <= ord(c) <= 159 for c in value)


def parse_envelope(payload):
    if len(payload) > MAX_OUTPUT:
        raise AuditFailure("json_output_limit")
    try:
        value = json.loads(payload)
    except (ValueError, UnicodeDecodeError) as error:
        raise AuditFailure("invalid_json") from error
    if not isinstance(value, dict) or not isinstance(value.get("casks"), list) or len(value["casks"]) > 50000:
        raise AuditFailure("invalid_cask_envelope")
    return value["casks"]


def validate_snapshot(info, outdated):
    installed, updates = parse_envelope(info), parse_envelope(outdated)
    by_token, seen_updates = {}, set()
    explicit_target_count = 0
    for record in installed:
        if not isinstance(record, dict) or not all(valid_text(record.get(key)) for key in ("token", "full_token", "version")):
            raise AuditFailure("invalid_installed_identity")
        if record["token"] in by_token:
            raise AuditFailure("duplicate_installed_token")
        if record.get("installed") is not None and not valid_text(record["installed"]):
            raise AuditFailure("invalid_installed_version")
        names = record.get("name")
        if not isinstance(names, list) or len(names) > 50 or not all(valid_text(name) for name in names):
            raise AuditFailure("invalid_display_names")
        for key in ("pinned", "disabled", "auto_updates"):
            if record.get(key) is not None and not isinstance(record[key], bool):
                raise AuditFailure("invalid_boolean_metadata")
        for key in ("tap", "sha256"):
            if record.get(key) is not None and not isinstance(record[key], str):
                raise AuditFailure("invalid_source_metadata")
        if record.get("depends_on") is not None and not isinstance(record["depends_on"], dict):
            raise AuditFailure("invalid_dependency_metadata")
        artifacts = record.get("artifacts")
        if artifacts is not None:
            if not isinstance(artifacts, list) or len(artifacts) > 1000:
                raise AuditFailure("invalid_artifact_metadata")
            for artifact in artifacts:
                if not isinstance(artifact, dict) or (artifact.get("target") is not None and not isinstance(artifact["target"], str)):
                    raise AuditFailure("invalid_artifact_metadata")
                target = artifact.get("target")
                if "app" in artifact and isinstance(target, str) and target.startswith("/") and target.lower().endswith(".app") and "\0" not in target:
                    explicit_target_count += 1
        by_token[record["token"]] = record
    for record in updates:
        if not isinstance(record, dict) or not valid_text(record.get("name")) or not valid_text(record.get("current_version")):
            raise AuditFailure("invalid_outdated_identity")
        versions = record.get("installed_versions")
        if not isinstance(versions, list) or not 1 <= len(versions) <= 100 or not all(valid_text(v) for v in versions):
            raise AuditFailure("invalid_outdated_versions")
        if record.get("pinned") is not None and not isinstance(record["pinned"], bool):
            raise AuditFailure("invalid_outdated_pin")
        original = by_token.get(record["name"])
        if record["name"] in seen_updates or not original or versions != [original.get("installed")] or record["current_version"] != original["version"]:
            raise AuditFailure("inconsistent_or_ambiguous_snapshot")
        seen_updates.add(record["name"])
    return {"envelopes_valid": True, "installed_cask_count": len(installed), "outdated_cask_count": len(updates),
            "explicit_app_target_count": explicit_target_count, "installed_record_fields_exercised": bool(installed),
            "outdated_record_fields_exercised": bool(updates), "cross_snapshot_identity_consistent": True,
            "inventory_record_names_paths_urls_retained": False}


def verify_layout():
    resolved = BREW.resolve(strict=True)
    stat = resolved.stat()
    root = resolved.parent.parent
    if resolved.name != "brew" or resolved.parent.name != "bin" or not resolved.is_file() or not 1 <= stat.st_size <= 2 * 1024 * 1024 or stat.st_mode & 0o002 or not os.access(BREW, os.X_OK):
        raise AuditFailure("unrecognized_homebrew_layout")
    for relative in ("Library/Homebrew/brew.sh", "Library/Homebrew/brew.rb", "Library/Homebrew/cmd/outdated.rb"):
        if not (root / relative).is_file():
            raise AuditFailure("incomplete_homebrew_layout")
    launcher = resolved.read_bytes()
    if not launcher.startswith(b"#!") or b"HOMEBREW_BREW_FILE" not in launcher or b"brew.sh" not in launcher:
        raise AuditFailure("unrecognized_homebrew_launcher")
    return hashlib.sha256(launcher).hexdigest()


def audit():
    result = {"schema_version": 1, "recorded_at": datetime.datetime.now(datetime.timezone.utc).isoformat(),
              "platform": platform.system(), "architecture": platform.machine(), "executable": str(BREW),
              "scope": "Installed Homebrew read-only protocol; no app updates, metadata refresh or app launches",
              "status": "not_started", "latest_homebrew_version_verified": False,
              "mutations_executed": [], "real_app_updates_tested": False,
              "protective_environment": PROTECTIVE_ENV, "credentials_forwarded": False,
              "commands": [], "limitations": []}
    if platform.system() != "Darwin" or platform.machine() != "arm64" or os.environ.get("GITHUB_ACTIONS") != "true" or os.environ.get("CI") != "true" or os.geteuid() == 0:
        result.update(status="unsupported_environment", reason="Requires a non-root arm64 macOS GitHub Actions runner")
        return result, 1
    if not BREW.exists():
        result.update(status="not_available", reason="The explicit /opt/homebrew/bin/brew executable is absent")
        return result, 0
    try:
        result["launcher_sha256"] = verify_layout()
        version = invoke(("--version",), result["commands"], timeout=45, limit=1024 * 1024).decode("utf-8", errors="strict")
        first_line = version.splitlines()[0] if version.splitlines() else ""
        if not first_line.startswith("Homebrew ") or not valid_text(first_line) or len(first_line) > 256:
            raise AuditFailure("invalid_homebrew_version_header")
        result["brew_version"] = first_line
        helps = {name: invoke((name, "--help"), result["commands"], timeout=60, limit=1024 * 1024).decode("utf-8", errors="strict") for name in ("info", "outdated", "upgrade", "update")}
        result["capabilities"] = help_contract(helps)
        if not result["capabilities"]["read_contract_compatible"]:
            raise AuditFailure("read_contract_incompatible")
        info = invoke(("info", "--json=v2", "--cask", "--installed"), result["commands"])
        outdated = invoke(("outdated", "--cask", "--json=v2"), result["commands"])
        result["json_contract"] = validate_snapshot(info, outdated)
        if not result["json_contract"]["installed_record_fields_exercised"]:
            result["limitations"].append("Runner has no installed casks; live JSON validates envelopes only. Record fields are covered by separate synthetic fixtures.")
        if not result["json_contract"]["outdated_record_fields_exercised"]:
            result["limitations"].append("No outdated records were observed; no actual upgrade or dry-run upgrade was executed.")
        result["status"] = "passed" if result["capabilities"]["upgrade_contract_compatible"] else "read_only_compatible_upgrade_unavailable"
        return result, 0
    except (AuditFailure, OSError, UnicodeError) as error:
        reason = str(error) if isinstance(error, AuditFailure) else type(error).__name__
        result.update(status="failed", reason=reason)
        return result, 1


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", required=True, type=pathlib.Path)
    arguments = parser.parse_args()
    report, code = audit()
    arguments.output.parent.mkdir(parents=True, exist_ok=True)
    arguments.output.write_text(json.dumps(report, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    print("Homebrew read-only audit:", report["status"], "->", arguments.output)
    raise SystemExit(code)


if __name__ == "__main__":
    main()
