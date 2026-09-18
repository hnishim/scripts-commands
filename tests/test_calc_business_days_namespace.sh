#!/bin/bash
set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "$0")" && pwd)
REPO_ROOT=$(cd -- "$SCRIPT_DIR/.." && pwd)
CALC_DIR="$REPO_ROOT/calcBusinessDays"
EXPECTED_NAMESPACE='my.script.calc-business-days'
LEGACY_NAMESPACE='com.hnishim.calc-business-days'

python3 - "$CALC_DIR/setup.sh" "$CALC_DIR/run.sh" "$CALC_DIR/README.md" <<'PY'
import sys
from pathlib import Path

setup, run, readme = (Path(p) for p in sys.argv[1:])
expected = "my.script.calc-business-days"
legacy = "com.hnishim.calc-business-days"

for path in (setup, run, readme):
    source = path.read_text(encoding="utf-8")
    if expected not in source:
        raise AssertionError(f"{path.name}: missing {expected}")
    if legacy in source:
        raise AssertionError(f"{path.name}: legacy namespace remains")
PY

TMP_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/hir129-calc-namespace.XXXXXX")
trap 'rm -rf -- "$TMP_ROOT"' EXIT
fake_python="$TMP_ROOT/python3"
events="$TMP_ROOT/events"
home="$TMP_ROOT/home"
mkdir -p "$home"
: >"$events"

cat >"$fake_python" <<'PYTHON'
#!/bin/bash
set -euo pipefail
if [ "${1:-}" = "-c" ]; then
    exit 0
fi
if [ "${1:-}" = "-m" ] && [ "${2:-}" = "venv" ]; then
    target=$3
    printf 'venv:%s\n' "$target" >>"$FAKE_PYTHON_EVENTS"
    mkdir -p "$target/bin"
    cat >"$target/bin/python" <<'RUNTIME'
#!/bin/bash
set -euo pipefail
if [ "${1:-}" = "-m" ] && [ "${2:-}" = "pip" ]; then
    printf 'pip:%s\n' "$*" >>"$FAKE_PYTHON_EVENTS"
    exit 0
fi
printf 'runtime:%s\n' "$*" >>"$FAKE_PYTHON_EVENTS"
RUNTIME
    chmod 755 "$target/bin/python"
    exit 0
fi
exit 2
PYTHON
chmod 755 "$fake_python"

run_setup() {
    HOME="$home" PYTHON_BIN="$fake_python" FAKE_PYTHON_EVENTS="$events" \
        /bin/bash "$CALC_DIR/setup.sh"
}

run_setup
run_setup

new_runtime="$home/Library/Application Support/$EXPECTED_NAMESPACE"
old_runtime="$home/Library/Application Support/$LEGACY_NAMESPACE"
[ -x "$new_runtime/.venv/bin/python" ]
[ ! -e "$old_runtime" ]
[ "$(grep -c '^venv:' "$events")" -eq 1 ]

HOME="$home" FAKE_PYTHON_EVENTS="$events" /bin/bash "$CALC_DIR/run.sh" \
    count --start 2026-09-01 --end 2026-09-02
HOME="$home" FAKE_PYTHON_EVENTS="$events" /bin/bash "$REPO_ROOT/calc-business-days_found.sh" \
    2026-09-01 2026-09-02
HOME="$home" FAKE_PYTHON_EVENTS="$events" /bin/bash "$REPO_ROOT/calc-business-days_find-date.sh" \
    2026-09-01 2
HOME="$home" FAKE_PYTHON_EVENTS="$events" /bin/bash "$REPO_ROOT/calc-business-days_shift-period.sh" \
    2026-09-01 2026-09-02 2026-09-03

[ "$(grep -c '^runtime:' "$events")" -eq 4 ]
printf '%s\n' '[PASS] calc-business-days namespace and entry-point contract'
