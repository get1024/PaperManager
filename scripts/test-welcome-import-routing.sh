#!/bin/bash
set -euo pipefail

TEST_MODE=${1:---compile-only}
case "$TEST_MODE" in
  --compile-only|--run) ;;
  --help|-h)
    printf '%s\n' 'Usage: test-welcome-import-routing.sh [--compile-only|--run]' \
      'Default: compile only. --run opens a disposable Welcome Import Routing Fixture.'
    exit 0 ;;
  *) printf '%s\n' "Unknown mode: $TEST_MODE" >&2; exit 2 ;;
esac
if [[ $# -gt 1 ]]; then
  printf '%s\n' 'Only one mode argument is accepted.' >&2
  exit 2
fi

TASK_ROOT=$(cd "$(dirname "$0")/.." && pwd)
REPORT_PATH=${PAPERMANAGER_WELCOME_ROUTE_REPORT:-$TASK_ROOT/.build/test-results/welcome-import-routing/report.json}
if [[ "$REPORT_PATH" != /* ]]; then
  printf '%s\n' 'The welcome routing report path must be absolute.' >&2
  exit 2
fi
TEST_WORK_DIR=$(mktemp -d /tmp/papermanager-welcome-import-routing.XXXXXX)
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

TEST_APP="$TEST_WORK_DIR/WelcomeImportRoutingSmoke.app"
TEST_EXECUTABLE="$TEST_APP/Contents/MacOS/WelcomeImportRoutingSmoke"
TEST_AX_EXECUTABLE="$TEST_WORK_DIR/SettingsInteractionAXClient"
TEST_CONTROL_DIR="$TEST_WORK_DIR/Control"
mkdir -p "$TEST_WORK_DIR/Sources" "$TEST_WORK_DIR/Fixture" "$TEST_CONTROL_DIR" \
  "$TEST_APP/Contents/MacOS" "$TEST_APP/Contents/Resources" "$TASK_ROOT/.build/test-module-cache"
cp "$TASK_ROOT"/Sources/PaperManager/Models/*.swift "$TASK_ROOT"/Sources/PaperManager/Services/*.swift \
  "$TASK_ROOT"/Sources/PaperManager/Views/*.swift \
  "$TASK_ROOT/Tests/WelcomeImportRoutingSmoke.swift" "$TEST_WORK_DIR/Sources/"
# Retain the production App, commands and delegate, but let the owned test App
# supply the executable entry point. Remove only the first standalone @main.
awk '!removed && $0 ~ /^[[:space:]]*@main[[:space:]]*$/ { removed=1; next } { print }' \
  "$TASK_ROOT/Sources/PaperManager/PaperManagerApp.swift" > "$TEST_WORK_DIR/Sources/PaperManagerApp.swift"
cp "$TASK_ROOT/Tests/SettingsInteractionAXClient.swift" "$TEST_WORK_DIR/SettingsInteractionAXClient.swift"
cp -R "$TASK_ROOT/Sources/PaperManager/Resources/en.lproj" \
  "$TASK_ROOT/Sources/PaperManager/Resources/zh-Hans.lproj" "$TEST_APP/Contents/Resources/"
cat > "$TEST_APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>tests.welcome-import-routing</string>
<key>CFBundleExecutable</key><string>WelcomeImportRoutingSmoke</string>
<key>CFBundleName</key><string>Welcome Import Routing Fixture</string>
<key>CFBundleDisplayName</key><string>Welcome Import Routing Fixture</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleDevelopmentRegion</key><string>zh-Hans</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>LSUIElement</key><true/>
<key>NSPrincipalClass</key><string>NSApplication</string>
<key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
/usr/bin/xcrun swiftc -swift-version 5 -whole-module-optimization -D WELCOME_IMPORT_ROUTING_TEST \
  -sdk "$TEST_SDK" -target "$PM_TARGET" \
  -module-cache-path "$TASK_ROOT/.build/test-module-cache" \
  "$TEST_WORK_DIR"/Sources/*.swift -o "$TEST_EXECUTABLE"
/usr/bin/xcrun swiftc -swift-version 5 -parse-as-library \
  -sdk "$TEST_SDK" -target "$PM_TARGET" \
  -module-cache-path "$TASK_ROOT/.build/test-module-cache" \
  "$TEST_WORK_DIR/SettingsInteractionAXClient.swift" -o "$TEST_AX_EXECUTABLE"

if [[ "$TEST_MODE" == --compile-only ]]; then
  printf '%s\n' 'Welcome routing host and external AX helper compiled; UI fixture was not executed.'
  exit 0
fi

mkdir -p "$(dirname "$REPORT_PATH")"
# Always override inherited library/control/diagnostic paths with this owned tmp.
# The report is the only caller-selected output; the host owns the final result.
PAPERMANAGER_LIBRARY_PATH="$TEST_WORK_DIR/Fixture/library.json" \
PAPERMANAGER_WELCOME_ROUTE_REPORT="$REPORT_PATH" \
PAPERMANAGER_SETTINGS_INTERACTION_CONTROL="$TEST_CONTROL_DIR" \
PAPERMANAGER_UI_DIAGNOSTICS="$TEST_WORK_DIR/Fixture/settings-geometry.jsonl" \
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
