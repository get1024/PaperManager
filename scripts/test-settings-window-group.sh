#!/bin/bash
set -euo pipefail

TASK_ROOT=$(cd "$(dirname "$0")/.." && pwd)
TEST_WORK_DIR=$(mktemp -d /tmp/papermanager-settings-window.XXXXXX)
trap 'rm -rf "$TEST_WORK_DIR"' EXIT
. "$TASK_ROOT/scripts/lib/toolchain.sh"
REPORT_DIR="$TASK_ROOT/.build/test-results/settings-window"
mkdir -p "$TEST_WORK_DIR/Sources" "$TASK_ROOT/.build/test-module-cache" "$REPORT_DIR"
cp "$TASK_ROOT"/Sources/PaperManager/Models/*.swift "$TASK_ROOT"/Sources/PaperManager/Services/*.swift \
  "$TASK_ROOT/Sources/PaperManager/Views/ViewUtilities.swift" \
  "$TASK_ROOT/Sources/PaperManager/Views/SettingsView.swift" \
  "$TASK_ROOT/Sources/PaperManager/Views/HelpView.swift" \
  "$TASK_ROOT/Sources/PaperManager/Views/PaperDetailView.swift" \
  "$TASK_ROOT/Sources/PaperManager/Views/InspectorInlineEditor.swift" \
  "$TASK_ROOT/Sources/PaperManager/Views/ZoteroImportView.swift" \
  "$TASK_ROOT/Tests/SettingsWindowGroupSmoke.swift" "$TEST_WORK_DIR/Sources/"
/usr/bin/xcrun swiftc -swift-version 5 -whole-module-optimization \
  -sdk "$TEST_SDK" -target "$PM_TARGET" \
  -module-cache-path "$TASK_ROOT/.build/test-module-cache" \
  "$TEST_WORK_DIR"/Sources/*.swift -o "$TEST_WORK_DIR/SettingsWindowGroupSmoke"

PAPERMANAGER_LIBRARY_PATH="$TEST_WORK_DIR/library.json" \
PAPERMANAGER_SETTINGS_REPORT="$REPORT_DIR/report.json" \
  "$TEST_WORK_DIR/SettingsWindowGroupSmoke"
