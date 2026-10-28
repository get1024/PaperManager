#!/bin/bash
set -euo pipefail

TASK_ROOT=$(cd "$(dirname "$0")/.." && pwd)
TEST_WORK_DIR=$(mktemp -d /tmp/papermanager-settings-coordinator.XXXXXX)
trap 'rm -rf "$TEST_WORK_DIR"' EXIT
. "$TASK_ROOT/scripts/lib/toolchain.sh"
REPORT_DIR="$TASK_ROOT/.build/test-results/settings-coordinator"
mkdir -p "$TEST_WORK_DIR/Sources" "$TASK_ROOT/.build/test-module-cache" "$REPORT_DIR"
cp "$TASK_ROOT"/Sources/PaperManager/Models/*.swift "$TASK_ROOT"/Sources/PaperManager/Services/*.swift \
  "$TASK_ROOT/Sources/PaperManager/Views/ViewUtilities.swift" \
  "$TASK_ROOT/Sources/PaperManager/Views/SettingsView.swift" \
  "$TASK_ROOT/Sources/PaperManager/Views/HelpView.swift" \
  "$TASK_ROOT/Sources/PaperManager/Views/PaperDetailView.swift" \
  "$TASK_ROOT/Sources/PaperManager/Views/PaperReadingView.swift" \
  "$TASK_ROOT/Sources/PaperManager/Views/InspectorInlineEditor.swift" \
  "$TASK_ROOT/Sources/PaperManager/Views/ZoteroImportView.swift" \
  "$TASK_ROOT/Tests/SettingsWindowCoordinatorSmoke.swift" "$TEST_WORK_DIR/Sources/"
/usr/bin/xcrun swiftc -swift-version 5 -whole-module-optimization -D SETTINGS_WINDOW_GEOMETRY_TEST \
  -sdk "$TEST_SDK" -target "$PM_TARGET" \
  -module-cache-path "$TASK_ROOT/.build/test-module-cache" \
  "$TEST_WORK_DIR"/Sources/*.swift -o "$TEST_WORK_DIR/SettingsWindowCoordinatorSmoke"

: > "$REPORT_DIR/geometry.jsonl"
PAPERMANAGER_LIBRARY_PATH="$TEST_WORK_DIR/library.json" \
PAPERMANAGER_SETTINGS_REPORT="$REPORT_DIR/report.json" \
PAPERMANAGER_UI_DIAGNOSTICS="$REPORT_DIR/geometry.jsonl" \
  "$TEST_WORK_DIR/SettingsWindowCoordinatorSmoke"
