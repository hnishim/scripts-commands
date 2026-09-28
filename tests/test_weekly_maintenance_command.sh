#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
command_rel="weekly-maintenance.sh"
command_path="$repo_root/$command_rel"

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

[[ -f "$command_path" ]] || fail "$command_rel is missing"

mode="$(git -C "$repo_root" ls-files --stage -- "$command_rel" | awk '{print $1}')"
[[ "$mode" == "100755" ]] || fail "$command_rel must be stored with Git mode 100755 (actual: ${mode:-untracked})"

grep -Fxq '# @raycast.schemaVersion 1' "$command_path" \
  || fail "Raycast schemaVersion metadata is missing"
grep -Fxq '# @raycast.title Weekly Maintenance' "$command_path" \
  || fail "Raycast title metadata is missing"
grep -Fxq '# @raycast.mode silent' "$command_path" \
  || fail "Raycast silent mode metadata is missing"
grep -Eq '^# @raycast\.description .+' "$command_path" \
  || fail "Raycast description metadata is missing"

if grep -Eq '^# @raycast\.argument[0-9]+' "$command_path"; then
  fail "weekly maintenance command must not accept Raycast arguments"
fi

operational_lines="$(
  awk '
    NF && $0 !~ /^[[:space:]]*#/ {
      sub(/^[[:space:]]+/, "")
      sub(/[[:space:]]+$/, "")
      print
    }
  ' "$command_path"
)"
case "$operational_lines" in
  "open 'warp://tab_config/weekly-maintenance'"|"open \"warp://tab_config/weekly-maintenance\"")
    ;;
  *)
    fail "wrapper must contain only the canonical Warp URI delegation"
    ;;
esac

tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir"' EXIT

cat > "$tmpdir/open" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$#" > "$OPEN_LOG"
printf '%s\n' "$@" >> "$OPEN_LOG"
EOF
chmod +x "$tmpdir/open"

open_log="$tmpdir/open.log"
OPEN_LOG="$open_log" PATH="$tmpdir:$PATH" "$command_path"

[[ "$(sed -n '1p' "$open_log")" == "1" ]] \
  || fail "wrapper must call open with exactly one argument"
[[ "$(sed -n '2p' "$open_log")" == "warp://tab_config/weekly-maintenance" ]] \
  || fail "wrapper must delegate to the canonical weekly-maintenance Warp URI"
[[ -z "$(sed -n '3p' "$open_log")" ]] \
  || fail "wrapper passed unexpected extra arguments to open"

printf 'PASS: weekly-maintenance Raycast command contract\n'
