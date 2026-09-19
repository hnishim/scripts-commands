#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VENV_PYTHON="$HOME/Library/Application Support/my.script.calc-business-days/.venv/bin/python"

if [ ! -x "$VENV_PYTHON" ]; then
    "$SCRIPT_DIR/setup.sh" >&2
fi

exec "$VENV_PYTHON" "$SCRIPT_DIR/calcBusinessDays.py" "$@"
