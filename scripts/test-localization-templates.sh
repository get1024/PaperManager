#!/bin/bash
set -euo pipefail

TASK_ROOT=$(cd "$(dirname "$0")/.." && pwd)
TEST_WORK_DIR=$(mktemp -d /tmp/papermanager-localization-tests.XXXXXX)
trap 'rm -rf "$TEST_WORK_DIR"' EXIT
. "$TASK_ROOT/scripts/lib/toolchain.sh"
TEST_APP="$TEST_WORK_DIR/LocalizationTemplateTests.app"
mkdir -p "$TEST_WORK_DIR/sources" "$TEST_APP/Contents/MacOS" "$TEST_APP/Contents/Resources"
cp "$TASK_ROOT"/Sources/PaperManager/Models/*.swift "$TASK_ROOT"/Sources/PaperManager/Services/*.swift \
  "$TASK_ROOT/Sources/PaperManager/Views/ViewUtilities.swift" "$TASK_ROOT/Tests/LocalizationTemplateTests.swift" "$TEST_WORK_DIR/sources/"
cp -R "$TASK_ROOT/Sources/PaperManager/Resources/en.lproj" "$TASK_ROOT/Sources/PaperManager/Resources/zh-Hans.lproj" "$TEST_APP/Contents/Resources/"
cat > "$TEST_APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict><key>CFBundleIdentifier</key><string>tools.papermanager.localization-tests</string><key>CFBundleExecutable</key><string>LocalizationTemplateTests</string><key>CFBundlePackageType</key><string>APPL</string><key>CFBundleDevelopmentRegion</key><string>zh-Hans</string></dict></plist>
PLIST
/usr/bin/xcrun swiftc -swift-version 5 -sdk "$TEST_SDK" -target "$PM_TARGET" \
  -module-cache-path "$TEST_WORK_DIR/module-cache" \
  "$TEST_WORK_DIR"/sources/*.swift -o "$TEST_APP/Contents/MacOS/LocalizationTemplateTests"
"$TEST_APP/Contents/MacOS/LocalizationTemplateTests"
