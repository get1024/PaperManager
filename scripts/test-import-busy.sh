#!/bin/bash
set -euo pipefail

TEST_MODE=${1:---compile-only}
case "$TEST_MODE" in
  --compile-only) ;;
  --run) printf '%s\n' 'Launch through CUA; this runner only compiles and stages the fixture.' >&2; exit 2 ;;
  --help|-h)
    printf '%s\n' 'Usage: test-import-busy.sh [--compile-only]' \
      'Default: compile and stage only. Launch the disposable Import Busy Fixture through CUA.'
    exit 0 ;;
  *) printf '%s\n' "Unknown mode: $TEST_MODE" >&2; exit 2 ;;
esac
if [[ $# -gt 1 ]]; then
  printf '%s\n' 'Only one mode argument is accepted.' >&2
  exit 2
fi

TASK_ROOT=$(cd "$(dirname "$0")/.." && pwd)
REPORT_PATH=${PAPERMANAGER_IMPORT_BUSY_REPORT:-$TASK_ROOT/.build/test-results/import-busy/report.json}
if [[ "$REPORT_PATH" != /* ]]; then
  printf '%s\n' 'The import busy report path must be absolute.' >&2
  exit 2
fi
TEST_WORK_DIR=$(mktemp -d /private/tmp/papermanager-import-busy.XXXXXX)
KEEP_TEST_WORK_DIR=0
cleanup() {
  if [[ "$KEEP_TEST_WORK_DIR" == 0 ]]; then
    rm -rf "$TEST_WORK_DIR"
  fi
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
. "$TASK_ROOT/scripts/lib/toolchain.sh"

TEST_APP="$TEST_WORK_DIR/ImportBusySmoke.app"
TEST_EXECUTABLE="$TEST_APP/Contents/MacOS/ImportBusySmoke"
TEST_STAGE_APP="$TEST_APP"
TEST_STAGE_ROOT="$TEST_WORK_DIR"
if [[ -n "${PAPERMANAGER_IMPORT_BUSY_STAGE_APP:-}" ]]; then
  TEST_STAGE_REQUEST="$PAPERMANAGER_IMPORT_BUSY_STAGE_APP"
  if [[ "$TEST_STAGE_REQUEST" != /* || "$TEST_STAGE_REQUEST" != *.app || ! -d "$(dirname "$TEST_STAGE_REQUEST")" ]]; then
    printf '%s\n' 'The staged App must be an absolute .app path in an existing owned temporary directory.' >&2
    exit 2
  fi
  TEST_STAGE_ROOT=$(cd "$(dirname "$TEST_STAGE_REQUEST")" && pwd -P)
  case "$TEST_STAGE_ROOT" in
    /private/tmp/papermanager-import-busy.*|/private/tmp/papermanager-import-busy-*) ;;
    *) printf '%s\n' 'The staged App directory must be an owned /private/tmp/papermanager-import-busy* directory.' >&2; exit 2 ;;
  esac
  TEST_STAGE_APP="$TEST_STAGE_ROOT/$(basename "$TEST_STAGE_REQUEST")"
  if [[ -e "$TEST_STAGE_APP" || -L "$TEST_STAGE_APP" || -e "$TEST_STAGE_ROOT/Fixture" || -L "$TEST_STAGE_ROOT/Fixture" ]]; then
    printf '%s\n' 'Refusing to replace a staged App or reuse fixture data.' >&2
    exit 2
  fi
fi
mkdir -p "$TEST_WORK_DIR/Sources" "$TEST_WORK_DIR/Fixture" \
  "$TEST_APP/Contents/MacOS" "$TEST_APP/Contents/Resources" "$TASK_ROOT/.build/test-module-cache" \
  "$TEST_STAGE_ROOT/Fixture" "$(dirname "$REPORT_PATH")"
cp "$TASK_ROOT"/Sources/PaperManager/Models/*.swift "$TASK_ROOT"/Sources/PaperManager/Services/*.swift \
  "$TASK_ROOT"/Sources/PaperManager/Views/*.swift \
  "$TASK_ROOT/Tests/ImportBusySmoke.swift" "$TEST_WORK_DIR/Sources/"
# Retain the production App, commands and delegate, but let the owned test App
# supply the executable entry point. Remove only the first standalone @main.
awk '!removed && $0 ~ /^[[:space:]]*@main[[:space:]]*$/ { removed=1; next } { print }' \
  "$TASK_ROOT/Sources/PaperManager/PaperManagerApp.swift" > "$TEST_WORK_DIR/Sources/PaperManagerApp.swift"
cp -R "$TASK_ROOT/Sources/PaperManager/Resources/en.lproj" \
  "$TASK_ROOT/Sources/PaperManager/Resources/zh-Hans.lproj" "$TEST_APP/Contents/Resources/"
cat > "$TEST_APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>tests.import-busy</string>
<key>CFBundleExecutable</key><string>ImportBusySmoke</string>
<key>CFBundleName</key><string>Import Busy Fixture</string>
<key>CFBundleDisplayName</key><string>Import Busy Fixture</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleDevelopmentRegion</key><string>zh-Hans</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>LSUIElement</key><false/>
<key>NSPrincipalClass</key><string>NSApplication</string>
<key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
# Finder/CUA launches do not inherit shell variables. Keep every fixture path
# inside the owned temporary root. Compilation never launches the App.
/usr/bin/plutil -insert LSEnvironment -xml '<dict/>' "$TEST_APP/Contents/Info.plist"
/usr/bin/plutil -insert LSEnvironment.PAPERMANAGER_LIBRARY_PATH -string "$TEST_STAGE_ROOT/Fixture/library.json" "$TEST_APP/Contents/Info.plist"
/usr/bin/plutil -insert LSEnvironment.PAPERMANAGER_IMPORT_BUSY_REPORT -string "$REPORT_PATH" "$TEST_APP/Contents/Info.plist"
/usr/bin/xcrun swiftc -swift-version 5 -whole-module-optimization -D IMPORT_BUSY_TEST \
  -sdk "$TEST_SDK" -target "$PM_TARGET" \
  -module-cache-path "$TASK_ROOT/.build/test-module-cache" \
  "$TEST_WORK_DIR"/Sources/*.swift -o "$TEST_EXECUTABLE"
if [[ "$TEST_STAGE_APP" != "$TEST_APP" ]]; then
  /usr/bin/ditto "$TEST_APP" "$TEST_STAGE_APP"
fi

if [[ "$TEST_MODE" == --compile-only ]]; then
  if [[ "$TEST_STAGE_APP" == "$TEST_APP" ]]; then
    KEEP_TEST_WORK_DIR=1
  fi
  printf '%s\n' 'Import busy host compiled and staged; UI fixture was not executed.'
  printf '%s\n' "Staged fixture App: $TEST_STAGE_APP" \
    "Owned fixture root: $TEST_STAGE_ROOT" "Report: $REPORT_PATH" \
    'Launch the staged App through CUA when authorized. Remove its owned temporary root after collecting results.'
  exit 0
fi
