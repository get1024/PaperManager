#!/bin/zsh
set -euo pipefail

PROJECT_DIR="${0:A:h:h}"
cd "$PROJECT_DIR"
. "$PROJECT_DIR/scripts/lib/toolchain.sh"
. "$PROJECT_DIR/scripts/lib/build-configuration.sh"
BUILD_DIR="${PAPERMANAGER_BUILD_DIR:-$PROJECT_DIR/dist}"
BUILD_DIR="${BUILD_DIR:A}"
FINAL_APP_DIR="$BUILD_DIR/PaperManager.app"
mkdir -p "$BUILD_DIR"
# Build and sign a complete bundle before replacing an existing installation.
# In particular, never truncate a binary through dist/PaperManager.app's symlink.
STAGING_DIR="$(/usr/bin/mktemp -d "$BUILD_DIR/.papermanager-build.XXXXXX")"
APP_DIR="$STAGING_DIR/PaperManager.app"
BUILD_COMPLETE=0
PREVIOUS_APP="$STAGING_DIR/previous/PaperManager.app"
cleanup() {
  if [[ "$BUILD_COMPLETE" == 0 && -d "$PREVIOUS_APP" ]]; then
    [[ ! -e "$FINAL_APP_DIR" ]] || /bin/rm -rf "$FINAL_APP_DIR"
    /bin/mv "$PREVIOUS_APP" "$FINAL_APP_DIR"
  fi
  /bin/rm -rf "$STAGING_DIR"
}
trap cleanup EXIT
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Helpers" "$APP_DIR/Contents/Resources"
SOURCE_FILES=(Sources/PaperManager/**/*.swift)
/usr/bin/xcrun swiftc -parse-as-library -swift-version 5 -sdk "$BUILD_SDK" \
  -target "$PM_TARGET" "${PM_OPTIMIZATION_FLAGS[@]}" "${SOURCE_FILES[@]}" \
  -o "$APP_DIR/Contents/MacOS/PaperManager"
PAPERMANAGER_CLI_BUILD_DIR="$APP_DIR/Contents/Helpers" "$PROJECT_DIR/scripts/build-cli.sh" >/dev/null
cp App/Info.plist "$APP_DIR/Contents/Info.plist"
for PAIR in CFBundleExecutable:PaperManager CFBundleIdentifier:com.aurelian.PaperManager \
  CFBundleDevelopmentRegion:zh-Hans CFBundleShortVersionString:0.3.1 \
  CFBundleVersion:20261023.32 LSMinimumSystemVersion:14.0; do
  /usr/bin/plutil -replace "${PAIR%%:*}" -string "${PAIR#*:}" "$APP_DIR/Contents/Info.plist"
done
ICON_SET="$STAGING_DIR/PaperManager.iconset"
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
if [[ -L "$FINAL_APP_DIR" ]]; then
  if [[ "$BUILD_DIR" != "$PROJECT_DIR/dist" ]]; then
    print -u2 -- "A custom build output must not be a symlink: $FINAL_APP_DIR"
    exit 1
  fi
  "$PROJECT_DIR/scripts/install-app.sh" "$APP_DIR" --link-dist >/dev/null
else
  if [[ -e "$FINAL_APP_DIR" ]]; then
    mkdir -p "$STAGING_DIR/previous"
    /bin/mv "$FINAL_APP_DIR" "$PREVIOUS_APP"
  fi
  /bin/mv "$APP_DIR" "$FINAL_APP_DIR"
fi
BUILD_COMPLETE=1
print -r -- "$FINAL_APP_DIR"
