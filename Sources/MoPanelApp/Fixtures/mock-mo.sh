#!/bin/bash
# TEST ONLY. This program never accesses user files or runs a cleanup.
set -eu
fixture_root="$(cd "$(dirname "$0")" && pwd)"
command_name="${1:---help}"
if [[ "$command_name" == "--version" ]]; then
    printf '%s\n' 'Mole version 1.62.0' 'Channel: Stable (synthetic fixture)'
    exit 0
fi
if [[ "$command_name" == "--help" ]]; then
    printf '%s\n' 'Mole: clean uninstall optimize analyze status purge installer slim history touchid completion update remove help version'
    exit 0
fi
case "$command_name" in
    clean|uninstall|optimize|analyze|status|purge|installer|slim|history|touchid|completion|update|remove)
        for fixture_arg in "$@"; do
            if [[ "$fixture_arg" == "--help" ]]; then
                cat "$fixture_root/help/$command_name.txt"
                exit 0
            fi
        done
        ;;
    *) printf '%s\n' 'TEST FIXTURE: unsupported command' >&2; exit 2 ;;
esac
case "$command_name" in
    status)
        for fixture_arg in "$@"; do
            if [[ "$fixture_arg" == "--watch" ]]; then
                trap 'exit 0' INT TERM HUP
                while true; do cat "$fixture_root/status.ndjson"; sleep 2; done
            fi
        done
        cat "$fixture_root/status.json"
        ;;
    analyze)
        if [[ "${!#}" == "/MoPanel-fixture-large" ]]; then cat "$fixture_root/analyze-large.json"; else cat "$fixture_root/analyze.json"; fi
        ;;
    uninstall)
        if [[ "${2:-}" == "--list" ]]; then cat "$fixture_root/apps.json"; else printf '%s\n' 'TEST FIXTURE: no uninstallation performed'; fi
        ;;
    history) cat "$fixture_root/history.json" ;;
    *) printf '%s\n' 'TEST FIXTURE: no system changes performed' ;;
esac
