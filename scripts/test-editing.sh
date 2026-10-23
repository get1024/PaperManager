#!/bin/bash
set -euo pipefail

TASK_ROOT=$(cd "$(dirname "$0")/.." && pwd)
TEST_WORK_DIR=$(mktemp -d /tmp/papermanager-editing.XXXXXX)
trap 'rm -rf "$TEST_WORK_DIR"' EXIT
. "$TASK_ROOT/scripts/lib/toolchain.sh"

mkdir -p "$TEST_WORK_DIR/source"
cp "$TASK_ROOT"/Sources/PaperManager/Models/*.swift "$TASK_ROOT"/Sources/PaperManager/Services/*.swift \
  "$TASK_ROOT/Sources/PaperManager/Views/ViewUtilities.swift" \
  "$TASK_ROOT/Sources/PaperManager/Views/PaperDetailView.swift" \
  "$TASK_ROOT/Sources/PaperManager/Views/InspectorInlineEditor.swift" \
  "$TASK_ROOT/Tests/EditingRegression.swift" "$TEST_WORK_DIR/source/"
mkdir -p "$TASK_ROOT/.build/test-module-cache"
/usr/bin/xcrun swiftc -swift-version 5 -sdk "$TEST_SDK" -target "$PM_TARGET" \
  -whole-module-optimization -module-cache-path "$TASK_ROOT/.build/test-module-cache" \
  "$TEST_WORK_DIR"/source/*.swift -o "$TEST_WORK_DIR/EditingRegression"

"$TEST_WORK_DIR/EditingRegression"
