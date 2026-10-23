#!/bin/bash
set -euo pipefail
TASK_ROOT=$(cd "$(dirname "$0")/.." && pwd)
GROUP=${1:-core}
RESULTS_DIR="$TASK_ROOT/.build/test-results"
mkdir -p "$RESULTS_DIR"
FAILED=0

run() {
  local name=$1
  shift
  printf 'Running %s\n' "$name"
  if "$@" >"$RESULTS_DIR/$name.log" 2>&1; then
    tail -n 1 "$RESULTS_DIR/$name.log"
  else
    tail -n 35 "$RESULTS_DIR/$name.log" >&2
    FAILED=$((FAILED + 1))
  fi
}

core() {
  for name in reconstruction local-api lattice-archive editing sidebar file-library zotero-import import-backup localization-templates metadata-intents metadata-refresh service-correctness; do
    run "$name" "$TASK_ROOT/scripts/test-$name.sh"
  done
  run connector "$TASK_ROOT/Tests/Connector/run.sh"
}

ui() {
  for name in native-table native-window-group settings-window-coordinator add-paper-sheets paper-reader-annotations inspector-title-selection inspector-hover-geometry; do
    run "$name" "$TASK_ROOT/scripts/test-$name.sh"
  done
  run inspector-direct-editing "$TASK_ROOT/scripts/test-inspector-direct-editing.sh" --run
}

case "$GROUP" in
  core) core ;;
  ui) ui ;;
  all) core; ui ;;
  ax)
    run inspector-accessibility "$TASK_ROOT/scripts/test-inspector-accessibility.sh"
    run native-table-accessibility "$TASK_ROOT/scripts/test-native-table-accessibility.sh"
    ;;
  *) printf 'Usage: %s [core|ui|all|ax]\n' "$0" >&2; exit 2 ;;
esac
printf 'Test groups failed: %s\n' "$FAILED"
[[ $FAILED -eq 0 ]]
