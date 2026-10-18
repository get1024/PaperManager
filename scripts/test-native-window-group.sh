#!/bin/bash
set -euo pipefail

TASK_ROOT=$(cd "$(dirname "$0")/.." && pwd)
TEST_WORK_DIR=$(mktemp -d /tmp/papermanager-window-group.XXXXXX)
trap 'rm -rf "$TEST_WORK_DIR"' EXIT
. "$TASK_ROOT/scripts/lib/toolchain.sh"
REPORT_DIR="$TASK_ROOT/.build/test-results/window-group"
if [[ "${PAPERMANAGER_GEOMETRY_NEGATIVE_CONTROL:-0}" == 1 ]]; then
  REPORT_DIR="$REPORT_DIR-negative"
fi
mkdir -p "$TEST_WORK_DIR/Sources" "$TASK_ROOT/.build/test-module-cache" "$REPORT_DIR"
cp "$TASK_ROOT"/Sources/PaperManager/Models/*.swift "$TASK_ROOT"/Sources/PaperManager/Services/*.swift \
  "$TASK_ROOT/Sources/PaperManager/Views/ViewUtilities.swift" \
  "$TASK_ROOT/Sources/PaperManager/Views/PaperDetailView.swift" \
  "$TASK_ROOT/Sources/PaperManager/Views/NativeLibraryView.swift" \
  "$TASK_ROOT/Tests/NativeLibraryWindowGroupSmoke.swift" "$TEST_WORK_DIR/Sources/"
if [[ "${PAPERMANAGER_GEOMETRY_NEGATIVE_CONTROL:-0}" == 1 ]]; then
  /usr/bin/python3 - "$TEST_WORK_DIR/Sources/NativeLibraryView.swift" <<'PY'
from pathlib import Path
import sys
source = Path(sys.argv[1])
text = source.read_text()
fix = 'inspector.sizingOptions = []'
assert text.count(fix) == 1, 'The negative control requires the precise inspector sizing fix'
source.write_text(text.replace(fix, '// Negative control: retain default SwiftUI hosting sizing constraints'))
PY
fi
/usr/bin/xcrun swiftc -swift-version 5 -whole-module-optimization \
  -sdk "$TEST_SDK" -target "$PM_TARGET" \
  -module-cache-path "$TASK_ROOT/.build/test-module-cache" \
  "$TEST_WORK_DIR"/Sources/*.swift -o "$TEST_WORK_DIR/NativeLibraryWindowGroupSmoke"

PAPERMANAGER_LIBRARY_PATH="$TEST_WORK_DIR/library.json" \
PAPERMANAGER_GEOMETRY_LOG_PATH="$REPORT_DIR/geometry.json" \
PAPERMANAGER_WINDOW_GROUP_REPORT="$REPORT_DIR/report.json" \
  "$TEST_WORK_DIR/NativeLibraryWindowGroupSmoke"
