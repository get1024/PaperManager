#!/bin/bash
set -euo pipefail
TASK_ROOT=$(cd "$(dirname "$0")/.." && pwd)
TEST_WORK_DIR=$(mktemp -d /tmp/papermanager-add-sheets.XXXXXX)
trap 'rm -rf "$TEST_WORK_DIR"' EXIT
. "$TASK_ROOT/scripts/lib/toolchain.sh"
mkdir -p "$TEST_WORK_DIR/Sources" "$TASK_ROOT/.build/test-module-cache" "$TASK_ROOT/.build/test-results/add-paper-sheets"
cp "$TASK_ROOT"/Sources/PaperManager/Models/*.swift "$TASK_ROOT"/Sources/PaperManager/Services/*.swift \
  "$TASK_ROOT/Sources/PaperManager/Views/ViewUtilities.swift" \
  "$TASK_ROOT/Sources/PaperManager/Views/AddPaperSheets.swift" \
  "$TASK_ROOT/Sources/PaperManager/Views/ImportPreviewView.swift" \
  "$TASK_ROOT/Tests/AddPaperSheetsSmoke.swift" "$TEST_WORK_DIR/Sources/"
/usr/bin/xcrun swiftc -swift-version 5 -whole-module-optimization \
  -sdk "$TEST_SDK" -target "$PM_TARGET" -module-cache-path "$TASK_ROOT/.build/test-module-cache" \
  "$TEST_WORK_DIR"/Sources/*.swift -o "$TEST_WORK_DIR/AddPaperSheetsSmoke"
PAPERMANAGER_LIBRARY_PATH="$TEST_WORK_DIR/library.json" \
PAPERMANAGER_ADD_SHEETS_REPORT="$TASK_ROOT/.build/test-results/add-paper-sheets/report.json" \
  "$TEST_WORK_DIR/AddPaperSheetsSmoke"
