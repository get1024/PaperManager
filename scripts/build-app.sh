#!/bin/zsh
set -euo pipefail

PROJECT_DIR="${0:A:h:h}"
cd "$PROJECT_DIR"
. "$PROJECT_DIR/scripts/lib/toolchain.sh"
BUILD_DIR="${PAPERMANAGER_BUILD_DIR:-$PROJECT_DIR/dist}"
BUILD_DIR="${BUILD_DIR:A}"
APP_DIR="$BUILD_DIR/PaperManager.app"
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Helpers" "$APP_DIR/Contents/Resources"
SOURCE_FILES=(Sources/PaperManager/**/*.swift)
/usr/bin/xcrun swiftc -parse-as-library -swift-version 5 -sdk "$BUILD_SDK" \
  -target "$PM_TARGET" "${SOURCE_FILES[@]}" \
  -o "$APP_DIR/Contents/MacOS/PaperManager"
/usr/bin/xcrun swiftc -parse-as-library -swift-version 5 -whole-module-optimization -sdk "$BUILD_SDK" \
  -target "$PM_TARGET" Sources/PaperManagerCLI/*.swift \
  -o "$APP_DIR/Contents/Helpers/PaperManagerCLI"
/usr/bin/codesign --force --sign - "$APP_DIR/Contents/Helpers/PaperManagerCLI"
/usr/bin/codesign --verify --strict "$APP_DIR/Contents/Helpers/PaperManagerCLI"
cp App/Info.plist "$APP_DIR/Contents/Info.plist"
for PAIR in CFBundleExecutable:PaperManager CFBundleIdentifier:com.aurelian.PaperManager \
  CFBundleDevelopmentRegion:zh-Hans CFBundleShortVersionString:0.2.0 \
  CFBundleVersion:20261018 LSMinimumSystemVersion:14.0; do
  /usr/bin/plutil -replace "${PAIR%%:*}" -string "${PAIR#*:}" "$APP_DIR/Contents/Info.plist"
done
ICON_SET="$BUILD_DIR/PaperManager.iconset"
mkdir -p "$ICON_SET"
for SIZE in 16 32 128 256 512; do
  cp "Sources/PaperManager/Resources/Assets.xcassets/AppIcon.appiconset/AppIcon-$SIZE.png" "$ICON_SET/icon_${SIZE}x${SIZE}.png"
  cp "Sources/PaperManager/Resources/Assets.xcassets/AppIcon.appiconset/AppIcon-$SIZE@2x.png" "$ICON_SET/icon_${SIZE}x${SIZE}@2x.png"
done
/usr/bin/iconutil --convert icns "$ICON_SET" --output "$APP_DIR/Contents/Resources/PaperManager.icns"
# The icon source folder is temporary; the .app contains the compiled icon.
rm -r "$ICON_SET"
/usr/bin/plutil -replace CFBundleIconFile -string PaperManager.icns "$APP_DIR/Contents/Info.plist"
cp Sources/PaperManager/Resources/PrivacyInfo.xcprivacy "$APP_DIR/Contents/Resources/"
for LOCALIZATION in Sources/PaperManager/Resources/*.lproj(N); do
  cp -R "$LOCALIZATION" "$APP_DIR/Contents/Resources/"
done
# Ship the unpacked connector for manual loading; copying is not installation.
mkdir -p "$APP_DIR/Contents/Resources/BrowserExtension"
cp -R BrowserExtension/. "$APP_DIR/Contents/Resources/BrowserExtension/"
/usr/bin/codesign --force --sign - "$APP_DIR"
/usr/bin/codesign --verify --deep --strict "$APP_DIR"
print -r -- "$APP_DIR"
