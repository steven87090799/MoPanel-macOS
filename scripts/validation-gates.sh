#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Record independent fixture validation outcomes; require both before release work.
_mopanel_gate_recorder="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/validation_gate.py"

mopanel_initialize_validation_gates() {
    python3 "$_mopanel_gate_recorder" initialize "$1"
}

mopanel_capture_validation_gate() {
    local mopanel_gate_summary="$1"
    local mopanel_gate_name="$2"
    local mopanel_gate_log="$3"
    shift 3
    local mopanel_gate_statuses=()
    # An if condition lets us collect the other independent fixture check.
    # Capture $? and PIPESTATUS in ONE assignment before any other command.
    if "$@" 2>&1 | tee "$mopanel_gate_log"; then
        mopanel_gate_statuses=("$?" "${PIPESTATUS[@]}")
    else
        mopanel_gate_statuses=("$?" "${PIPESTATUS[@]}")
    fi
    python3 "$_mopanel_gate_recorder" record "$mopanel_gate_summary" \
        "$mopanel_gate_name" "$mopanel_gate_log" "${mopanel_gate_statuses[@]}"
}

mopanel_require_validation_gates() {
    python3 "$_mopanel_gate_recorder" require "$1"
}
