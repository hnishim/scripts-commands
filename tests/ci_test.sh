#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

command -v bash >/dev/null
command -v python3 >/dev/null

find . -type f -name '*.sh' \
  -not -path './_archive/*' \
  -not -path './.git/*' \
  -print \
  | LC_ALL=C sort \
  | while IFS= read -r script_path; do
      echo "bash -n ${script_path}"
      bash -n "$script_path"
    done

python3 - <<'PY'
from pathlib import Path

excluded = {".git", "_archive"}
paths = [
    path
    for path in Path(".").rglob("*.py")
    if not any(part in excluded for part in path.parts)
]

for path in sorted(paths, key=lambda item: item.as_posix()):
    print(f"python compile {path}")
    source = path.read_text(encoding="utf-8")
    compile(source, str(path), "exec")
PY

bash tests/test_calc_business_days_namespace.sh
