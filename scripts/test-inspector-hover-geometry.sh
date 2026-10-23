#!/bin/bash
set -euo pipefail
TASK_ROOT=$(cd "$(dirname "$0")/.." && pwd)
. "$TASK_ROOT/scripts/lib/toolchain.sh"
TEST_WORK_DIR="$TASK_ROOT/.build/inspector-hover-geometry"
mkdir -p "$TEST_WORK_DIR" "$TASK_ROOT/.build/test-module-cache"
# Only access control changes in this disposable copy, so the CPU-only test
# can exercise lifecycle handlers without activating or creating a window.
sed 's/private func activityDidChange(/func activityDidChange(/' \
  "$TASK_ROOT/Sources/PaperManager/Views/InspectorInlineEditor.swift" > "$TEST_WORK_DIR/InspectorInlineEditor.swift"
/usr/bin/xcrun swiftc -swift-version 5 -sdk "$TEST_SDK" -target "$PM_TARGET" \
  -module-cache-path "$TASK_ROOT/.build/test-module-cache" \
  "$TEST_WORK_DIR/InspectorInlineEditor.swift" "$TASK_ROOT/Tests/InspectorHoverGeometrySmoke.swift" \
  -o "$TEST_WORK_DIR/InspectorHoverGeometrySmoke"
cd "$TASK_ROOT"
"$TEST_WORK_DIR/InspectorHoverGeometrySmoke"
