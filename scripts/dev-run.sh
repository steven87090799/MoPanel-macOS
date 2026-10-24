#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Apply this project's development tools to one command, without editing shell profiles.
set -euo pipefail
mopanel_root="$(cd "$(dirname "$0")/.." && pwd)"
if [ "$#" -eq 0 ]; then
    printf 'Usage: bash scripts/dev-run.sh COMMAND [ARGUMENTS...]\n' >&2
    exit 2
fi
if [ -d /opt/homebrew/bin ]; then export PATH="/opt/homebrew/bin:$PATH"; fi
if [ -z "${DEVELOPER_DIR:-}" ] && [ -d /Applications/Xcode.app/Contents/Developer ]; then
    export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
fi
if [ -x "$mopanel_root/.venv/bin/python3" ]; then
    export VIRTUAL_ENV="$mopanel_root/.venv"
    export PATH="$VIRTUAL_ENV/bin:$PATH"
fi
cd "$mopanel_root"
exec "$@"
