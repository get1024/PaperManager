#!/bin/bash
set -euo pipefail

TEST_MODE=${1:---compile-only}
case "$TEST_MODE" in
  --compile-only|--run) ;;
  --help|-h)
    printf '%s\n' 'Usage: test-inspector-direct-editing.sh [--compile-only|--run]' \
      'Default: compile only. --run opens a disposable native UI fixture.'
    exit 0 ;;
  *) printf '%s\n' "Unknown mode: $TEST_MODE" >&2; exit 2 ;;
esac

TASK_ROOT=$(cd "$(dirname "$0")/.." && pwd)
TEST_WORK_DIR=$(mktemp -d /tmp/papermanager-inspector-direct.XXXXXX)
TEST_HOST_PID=""
TEST_AX_HELPER_PID=""
cleanup() {
  if [[ -n "$TEST_AX_HELPER_PID" ]]; then
    kill "$TEST_AX_HELPER_PID" 2>/dev/null || true
    wait "$TEST_AX_HELPER_PID" 2>/dev/null || true
    TEST_AX_HELPER_PID=""
  fi
  if [[ -n "$TEST_HOST_PID" ]]; then
    kill "$TEST_HOST_PID" 2>/dev/null || true
    wait "$TEST_HOST_PID" 2>/dev/null || true
    TEST_HOST_PID=""
  fi
  rm -rf "$TEST_WORK_DIR"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
. "$TASK_ROOT/scripts/lib/toolchain.sh"

TEST_APP="$TEST_WORK_DIR/InspectorDirectEditingSmoke.app"
TEST_EXECUTABLE="$TEST_APP/Contents/MacOS/InspectorDirectEditingSmoke"
TEST_AX_EXECUTABLE="$TEST_WORK_DIR/InspectorDirectEditingAXClient"
TEST_CONTROL_DIR="$TEST_WORK_DIR/Control"
REPORT_PATH=${PAPERMANAGER_INSPECTOR_EDIT_REPORT:-$TASK_ROOT/.build/test-results/inspector-direct-editing/report.json}
mkdir -p "$TEST_WORK_DIR/Sources" "$TEST_WORK_DIR/Fixture" "$TEST_CONTROL_DIR" \
  "$TEST_APP/Contents/MacOS" "$TEST_APP/Contents/Resources" "$TASK_ROOT/.build/test-module-cache"
cp "$TASK_ROOT"/Sources/PaperManager/Models/*.swift "$TASK_ROOT"/Sources/PaperManager/Services/*.swift \
  "$TASK_ROOT/Sources/PaperManager/Views/ViewUtilities.swift" \
  "$TASK_ROOT/Sources/PaperManager/Views/PaperDetailView.swift" \
  "$TASK_ROOT/Sources/PaperManager/Views/InspectorInlineEditor.swift" \
  "$TASK_ROOT/Tests/InspectorDirectEditingSmoke.swift" "$TEST_WORK_DIR/Sources/"
cp "$TASK_ROOT/Tests/InspectorDirectEditingAXClient.swift" "$TEST_WORK_DIR/InspectorDirectEditingAXClient.swift"
cp -R "$TASK_ROOT/Sources/PaperManager/Resources/en.lproj" \
  "$TASK_ROOT/Sources/PaperManager/Resources/zh-Hans.lproj" "$TEST_APP/Contents/Resources/"
cat > "$TEST_APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>tools.papermanager.inspector-direct-editing</string>
<key>CFBundleExecutable</key><string>InspectorDirectEditingSmoke</string>
<key>CFBundleName</key><string>Inspector Direct Editing Fixture</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleDevelopmentRegion</key><string>zh-Hans</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>LSUIElement</key><true/>
<key>NSPrincipalClass</key><string>NSApplication</string>
<key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
/usr/bin/xcrun swiftc -swift-version 5 -whole-module-optimization -D INSPECTOR_DIRECT_EDITING_TEST \
  -sdk "$TEST_SDK" -target "$PM_TARGET" \
  -module-cache-path "$TASK_ROOT/.build/test-module-cache" \
  "$TEST_WORK_DIR"/Sources/*.swift -o "$TEST_EXECUTABLE"
/usr/bin/xcrun swiftc -swift-version 5 -parse-as-library \
  -sdk "$TEST_SDK" -target "$PM_TARGET" \
  -module-cache-path "$TASK_ROOT/.build/test-module-cache" \
  "$TEST_WORK_DIR/InspectorDirectEditingAXClient.swift" -o "$TEST_AX_EXECUTABLE"

if [[ "$TEST_MODE" == --compile-only ]]; then
  printf '%s\n' 'Inspector direct editing host and external AX helper compiled; UI fixture was not executed.'
  exit 0
fi
if [[ "$REPORT_PATH" != /* ]]; then
  printf '%s\n' 'The test report path must be absolute.' >&2
  exit 2
fi
mkdir -p "$(dirname "$REPORT_PATH")"
PAPERMANAGER_LIBRARY_PATH="$TEST_WORK_DIR/Fixture/library.json" \
PAPERMANAGER_INSPECTOR_EDIT_REPORT="$REPORT_PATH" \
PAPERMANAGER_INSPECTOR_EDIT_CONTROL="$TEST_CONTROL_DIR" \
  "$TEST_EXECUTABLE" &
TEST_HOST_PID=$!
"$TEST_AX_EXECUTABLE" "$TEST_HOST_PID" "$TEST_CONTROL_DIR" &
TEST_AX_HELPER_PID=$!
set +e
wait "$TEST_HOST_PID"
TEST_RESULT=$?
set -e
TEST_HOST_PID=""
exit "$TEST_RESULT"
