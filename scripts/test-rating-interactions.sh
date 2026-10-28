#!/bin/bash
set -euo pipefail

TEST_MODE=${1:---run}
case "$TEST_MODE" in
  --compile-only|--run) ;;
  --help|-h)
    printf '%s\n' 'Usage: test-rating-interactions.sh [--compile-only|--run]' \
      '--run briefly activates its owned native window with local events and a synthetic library; never moves the system pointer.'
    exit 0 ;;
  *) printf '%s\n' "Unknown mode: $TEST_MODE" >&2; exit 2 ;;
esac

TASK_ROOT=$(cd "$(dirname "$0")/.." && pwd)
TEST_WORK_DIR=$(mktemp -d /tmp/papermanager-rating-interactions.XXXXXX)
trap 'rm -rf "$TEST_WORK_DIR"' EXIT
. "$TASK_ROOT/scripts/lib/toolchain.sh"
TEST_APP="$TEST_WORK_DIR/RatingInteractionSmoke.app"
TEST_EXECUTABLE="$TEST_APP/Contents/MacOS/RatingInteractionSmoke"
mkdir -p "$TEST_WORK_DIR/Sources" "$TEST_APP/Contents/MacOS" "$TASK_ROOT/.build/test-module-cache"
cat > "$TEST_APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>tools.papermanager.rating-interactions</string>
<key>CFBundleExecutable</key><string>RatingInteractionSmoke</string>
<key>CFBundleName</key><string>Rating Interaction Fixture</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>LSUIElement</key><true/>
<key>NSPrincipalClass</key><string>NSApplication</string>
<key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
cp "$TASK_ROOT"/Sources/PaperManager/Models/*.swift "$TASK_ROOT"/Sources/PaperManager/Services/*.swift \
  "$TASK_ROOT/Sources/PaperManager/Views/ViewUtilities.swift" \
  "$TASK_ROOT/Sources/PaperManager/Views/PaperDetailView.swift" \
  "$TASK_ROOT/Sources/PaperManager/Views/PaperReadingView.swift" \
  "$TASK_ROOT/Sources/PaperManager/Views/InspectorInlineEditor.swift" \
  "$TASK_ROOT"/Sources/PaperManager/Views/NativeLibrary*.swift \
  "$TASK_ROOT/Tests/RatingInteractionSmoke.swift" "$TEST_WORK_DIR/Sources/"
/usr/bin/xcrun swiftc -swift-version 5 -whole-module-optimization \
  -sdk "$TEST_SDK" -target "$PM_TARGET" \
  -module-cache-path "$TASK_ROOT/.build/test-module-cache" \
  "$TEST_WORK_DIR"/Sources/*.swift -o "$TEST_EXECUTABLE"

if [[ "$TEST_MODE" == --compile-only ]]; then
  printf '%s\n' 'Rating interaction fixture compiled; it was not executed.'
  exit 0
fi
cd "$TASK_ROOT"
"$TEST_EXECUTABLE"
