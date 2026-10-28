#!/bin/bash
set -euo pipefail
TASK_ROOT=$(cd "$(dirname "$0")/.." && pwd)
TEST_WORK_DIR=$(mktemp -d /tmp/papermanager-inspector-matrix.XXXXXX)
TEST_HOST_PID=""
cleanup() {
  if [[ -n "$TEST_HOST_PID" ]]; then kill "$TEST_HOST_PID" 2>/dev/null || true; wait "$TEST_HOST_PID" 2>/dev/null || true; fi
  rm -rf "$TEST_WORK_DIR"
}
trap cleanup EXIT
. "$TASK_ROOT/scripts/lib/toolchain.sh"
mkdir -p "$TEST_WORK_DIR/Sources" "$TEST_WORK_DIR/Fixture" "$TASK_ROOT/.build/test-module-cache" "$TASK_ROOT/.build/test-results/inspector-type-matrix"
cp "$TASK_ROOT"/Sources/PaperManager/Models/*.swift "$TASK_ROOT"/Sources/PaperManager/Services/*.swift \
  "$TASK_ROOT/Sources/PaperManager/Views/ViewUtilities.swift" \
  "$TASK_ROOT/Sources/PaperManager/Views/PaperDetailView.swift" \
  "$TASK_ROOT/Sources/PaperManager/Views/PaperPDFPreview.swift" \
  "$TASK_ROOT/Sources/PaperManager/Views/InspectorInlineEditor.swift" \
  "$TASK_ROOT/Tests/InspectorTypeMatrixHost.swift" "$TEST_WORK_DIR/Sources/"
/usr/bin/xcrun swiftc -swift-version 5 -whole-module-optimization -sdk "$TEST_SDK" -target "$PM_TARGET" \
  -module-cache-path "$TASK_ROOT/.build/test-module-cache" "$TEST_WORK_DIR"/Sources/*.swift \
  -o "$TEST_WORK_DIR/InspectorTypeMatrixHost"
/usr/bin/xcrun swiftc -parse-as-library -sdk "$TEST_SDK" "$TASK_ROOT/Tests/InspectorTypeMatrixAXClient.swift" -o "$TEST_WORK_DIR/InspectorTypeMatrixAXClient"
PAPERMANAGER_MATRIX_ROOT="$TEST_WORK_DIR/Fixture" "$TEST_WORK_DIR/InspectorTypeMatrixHost" &
TEST_HOST_PID=$!
PAPERMANAGER_MATRIX_REPORT="$TASK_ROOT/.build/test-results/inspector-type-matrix/report.json" \
  "$TEST_WORK_DIR/InspectorTypeMatrixAXClient" "$TEST_HOST_PID" "$TEST_WORK_DIR/Fixture"
