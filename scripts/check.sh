#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
SHELL_FILES=(
  "$ROOT/install.sh"
  "$ROOT/bin/hremote"
  "$ROOT/scripts/check.sh"
  "$ROOT/tests/run.sh"
  "$ROOT/tests/sensitive-data.sh"
)

bash -n "${SHELL_FILES[@]}"

if command -v shellcheck >/dev/null 2>&1; then
  shellcheck "${SHELL_FILES[@]}"
else
  printf 'ShellCheck not found; skipping lint (Bash syntax checks still ran).\n'
fi

"$ROOT/tests/run.sh"
"$ROOT/tests/sensitive-data.sh"

printf 'All checks passed.\n'
