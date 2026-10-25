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
    clean)
        # Exact fixture-only dry-run delay keeps the real Stop button testable.
        # This script never invokes an installed CLI or touches cleanup targets.
        if [[ "$#" -eq 2 && "${2:-}" == "--dry-run" ]]; then
            trap 'exit 130' INT TERM HUP
            sleep 3
        elif [[ "$#" -eq 1 ]]; then
            # Keep the safe interactive fixture alive while the actual Details
            # button is expanded/folded. No input or real file access occurs.
            trap 'exit 130' INT TERM HUP
            printf '%s\n' 'TEST FIXTURE: operation running; no system changes'
            sleep 6
        fi
        printf '%s\n' 'TEST FIXTURE: no system changes performed'
        ;;
    status)
        for fixture_arg in "$@"; do
            if [[ "$fixture_arg" == "--watch" ]]; then
                trap 'exit 0' INT TERM HUP
                while true; do cat "$fixture_root/status.ndjson"; sleep 2; done
            fi
        done
        if [[ "$#" -eq 1 && -t 0 ]]; then
            trap 'exit 130' INT TERM HUP
            stty -echo -icanon min 1 time 0
            printf '\033[2J\033[HMOLE DASHBOARD · SYNTHETIC FIXTURE\nCPU 25%%   GPU 18%%   Memory 50%%\nPress R to read terminal size, Q to leave.\n'
            while true; do
                key=''; IFS= read -r -s -n 1 key || exit 0
                case "$key" in
                    r|R) printf '\nFIXTURE_SIZE=%s\n' "$(stty size)" ;;
                    q|Q) exit 0 ;;
                esac
            done
        fi
        cat "$fixture_root/status.json"
        ;;
    analyze)
        # Only the no-path overview call is delayed for the native scan-cancel
        # test. Explicit-path and large benchmark fixture reads stay unchanged.
        if [[ "$#" -eq 2 && "${2:-}" == "--json" ]]; then
            trap 'exit 130' INT TERM HUP
            sleep 3
        fi
        if [[ "${!#}" == "/MoPanel-fixture-large" ]]; then cat "$fixture_root/analyze-large.json"; else cat "$fixture_root/analyze.json"; fi
        ;;
    uninstall)
        if [[ "${2:-}" == "--list" ]]; then cat "$fixture_root/apps.json"; else printf '%s\n' 'TEST FIXTURE: no uninstallation performed'; fi
        ;;
    installer)
        # A disposable selector exercises the real PTY -> terminal screen ->
        # native checkbox bridge. It never reads or changes installer files.
        if [[ ! -t 0 ]]; then printf '%s\n' 'TEST FIXTURE: no system changes performed'; exit 0; fi
        first_selected=1
        second_selected=0
        cursor=0
        while true; do
            chosen=$((first_selected + second_selected))
            printf '\033[2J\033[HSelect Installers to Remove, %s selected\n\n' "$chosen"
            if [[ "$cursor" -eq 0 ]]; then printf '➤ '; else printf '  '; fi
            if [[ "$first_selected" -eq 1 ]]; then printf '● '; else printf '○ '; fi
            printf 'Example One.dmg · 120 MB\n'
            if [[ "$cursor" -eq 1 ]]; then printf '➤ '; else printf '  '; fi
            if [[ "$second_selected" -eq 1 ]]; then printf '● '; else printf '○ '; fi
            printf 'Example Two.pkg · 80 MB\n\n↑↓ | Space Select | Enter Confirm | A All | I Invert | Q Quit\n'
            key=''; IFS= read -r -s -n 1 key || exit 0
            case "$key" in
                $'\033')
                    more=''; IFS= read -r -s -n 2 more || exit 0
                    [[ "$more" == '[B' ]] && cursor=1
                    [[ "$more" == '[A' ]] && cursor=0
                    ;;
                ' ') if [[ "$cursor" -eq 1 ]]; then second_selected=$((1 - second_selected)); else first_selected=$((1 - first_selected)); fi ;;
                q|Q) exit 0 ;;
                '') break ;;
            esac
        done
        printf '\033[2J\033[H➤ Delete %s installers, fixture only Enter confirm, ESC cancel: ' "$chosen"
        key=''; IFS= read -r -s -n 1 key || exit 0
        [[ -z "$key" ]] || exit 0
        printf '\n✓ Preview complete: %s synthetic installers, no files changed\n' "$chosen"
        ;;
    history) cat "$fixture_root/history.json" ;;
    *) printf '%s\n' 'TEST FIXTURE: no system changes performed' ;;
esac
