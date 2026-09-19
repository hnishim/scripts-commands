#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RUNTIME_DIR="$HOME/Library/Application Support/my.script.calc-business-days"
VENV_DIR="$RUNTIME_DIR/.venv"

if [ -n "${PYTHON_BIN:-}" ]; then
    python_bin="$PYTHON_BIN"
elif [ -x /opt/homebrew/bin/python3 ]; then
    python_bin=/opt/homebrew/bin/python3
else
    python_bin="$(command -v python3 || true)"
fi

if [ -z "$python_bin" ] || ! "$python_bin" -c 'import sys; raise SystemExit(sys.version_info < (3, 10))'; then
    echo "Python 3.10以上が必要です。" >&2
    exit 1
fi

mkdir -p "$RUNTIME_DIR"
if [ ! -x "$VENV_DIR/bin/python" ]; then
    "$python_bin" -m venv "$VENV_DIR"
fi
"$VENV_DIR/bin/python" -m pip install -r "$SCRIPT_DIR/requirements.txt"
