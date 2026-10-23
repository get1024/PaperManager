#!/bin/bash
set -euo pipefail
TASK_ROOT=$(cd "$(dirname "$0")/.." && pwd)
. "$TASK_ROOT/scripts/lib/toolchain.sh"
TEST_WORK_DIR="$TASK_ROOT/.build/inspector-title-selection"
mkdir -p "$TEST_WORK_DIR" "$TASK_ROOT/.build/test-module-cache"
# A never-shown NSView does not retain its needsDisplay flag. Only remove
# final in this disposable copy so the test can record full invalidation calls.
sed 's/^final class InspectorTitleFieldEditor:/class InspectorTitleFieldEditor:/' \
  "$TASK_ROOT/Sources/PaperManager/Views/InspectorInlineEditor.swift" > "$TEST_WORK_DIR/InspectorInlineEditor.swift"
/usr/bin/xcrun swiftc -swift-version 5 -sdk "$TEST_SDK" -target "$PM_TARGET" \
  -module-cache-path "$TASK_ROOT/.build/test-module-cache" \
  "$TEST_WORK_DIR/InspectorInlineEditor.swift" \
  "$TASK_ROOT/Tests/InspectorTitleSelectionSmoke.swift" -o "$TEST_WORK_DIR/InspectorTitleSelectionSmoke"
cd "$TASK_ROOT"
"$TEST_WORK_DIR/InspectorTitleSelectionSmoke"
