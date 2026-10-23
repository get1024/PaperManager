#!/bin/bash
# Remove reproducible build output, retaining the latest test logs by default.
set -euo pipefail
TASK_ROOT=$(cd "$(dirname "$0")/.." && pwd)
KEEP_RESULTS=1
if [[ $# -gt 1 ]]; then
  printf 'Usage: %s [--all]\n' "$0" >&2
  exit 2
fi
case "${1:-}" in
  '') ;;
  --all) KEEP_RESULTS=0 ;;
  *) printf 'Usage: %s [--all]\n' "$0" >&2; exit 2 ;;
esac
BUILD_ROOT="$TASK_ROOT/.build"
if [[ -L "$BUILD_ROOT" ]]; then
  printf '%s\n' 'Refusing to clean a symlinked .build directory.' >&2
  exit 1
fi
shopt -s nullglob dotglob
for entry in "$BUILD_ROOT"/*; do
  if [[ "$KEEP_RESULTS" == 1 && "$entry" == "$BUILD_ROOT/test-results" ]]; then
    continue
  fi
  /bin/rm -rf -- "$entry"
done
printf '%s\n' 'Build intermediates removed.'
