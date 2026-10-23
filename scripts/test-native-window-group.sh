#!/bin/bash
set -euo pipefail

TASK_ROOT=$(cd "$(dirname "$0")/.." && pwd)
TEST_WORK_DIR=$(mktemp -d /tmp/papermanager-window-group.XXXXXX)
trap 'rm -rf "$TEST_WORK_DIR"' EXIT
. "$TASK_ROOT/scripts/lib/toolchain.sh"
# Acceptance runs can retain their exact artifacts instead of overwriting the
# default directory, which represents only the most recent ordinary run.
REPORT_DIR=${PAPERMANAGER_WINDOW_GROUP_REPORT_DIR:-$TASK_ROOT/.build/test-results/window-group}
if [[ "$REPORT_DIR" != /* ]]; then
  printf '%s\n' 'PAPERMANAGER_WINDOW_GROUP_REPORT_DIR must be an absolute path.' >&2
  exit 2
fi
if [[ "${PAPERMANAGER_GEOMETRY_NEGATIVE_CONTROL:-0}" == 1 ]]; then
  REPORT_DIR="$REPORT_DIR-negative"
fi
mkdir -p "$TEST_WORK_DIR/Sources" "$TASK_ROOT/.build/test-module-cache" "$REPORT_DIR"
cp "$TASK_ROOT"/Sources/PaperManager/Models/*.swift "$TASK_ROOT"/Sources/PaperManager/Services/*.swift \
  "$TASK_ROOT/Sources/PaperManager/Views/ViewUtilities.swift" \
  "$TASK_ROOT/Sources/PaperManager/Views/PaperDetailView.swift" \
  "$TASK_ROOT/Sources/PaperManager/Views/InspectorInlineEditor.swift" \
  "$TASK_ROOT"/Sources/PaperManager/Views/NativeLibrary*.swift \
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

# Use the verified foreground/completion contract by default. Explicit zeroes
# retain the old background/fixed-delay mode for diagnostic comparisons.
PAPERMANAGER_LIBRARY_PATH="$TEST_WORK_DIR/library.json" \
PAPERMANAGER_GEOMETRY_LOG_PATH="$REPORT_DIR/geometry.json" \
PAPERMANAGER_WINDOW_GROUP_REPORT="$REPORT_DIR/report.json" \
PAPERMANAGER_WINDOW_GROUP_FRONTMOST="${PAPERMANAGER_WINDOW_GROUP_FRONTMOST:-1}" \
PAPERMANAGER_WINDOW_GROUP_SETTLED="${PAPERMANAGER_WINDOW_GROUP_SETTLED:-1}" \
  "$TEST_WORK_DIR/NativeLibraryWindowGroupSmoke"
