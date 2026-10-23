#!/bin/bash
set -euo pipefail

PROJECT_DIR=$(cd "$(dirname "$0")/.." && pwd)
ICON_SOURCE="$PROJECT_DIR/App/IconSource/folded-field-greige.png"
ICON_OUTPUT_ROOT="$PROJECT_DIR"

usage() {
  cat <<'USAGE'
Usage: scripts/render-app-icon.sh [source-image] [--output-root directory]

Export the square, full-bleed source into the macOS AppIcon asset catalog,
App/PaperManager.icns, a 1024 px source master, the README icon and a manifest.
The optional output root is useful for inspecting an export before replacing
the repository assets. Requires macOS and Xcode Command Line Tools only.
USAGE
}

if [[ ${1:-} == --help || ${1:-} == -h ]]; then
  usage
  exit 0
fi
if [[ $# -gt 0 && $1 != --output-root ]]; then
  ICON_SOURCE=$1
  shift
fi
if [[ $# -gt 0 ]]; then
  if [[ $# != 2 || $1 != --output-root ]]; then
    usage >&2
    exit 1
  fi
  ICON_OUTPUT_ROOT=$2
fi
if [[ ! -f "$ICON_SOURCE" ]]; then
  printf 'Icon source not found: %s\n' "$ICON_SOURCE" >&2
  exit 1
fi
ICON_SOURCE=$(cd "$(dirname "$ICON_SOURCE")" && pwd)/$(basename "$ICON_SOURCE")
mkdir -p "$ICON_OUTPUT_ROOT"
ICON_OUTPUT_ROOT=$(cd "$ICON_OUTPUT_ROOT" && pwd)
. "$PROJECT_DIR/scripts/lib/toolchain.sh"
ICON_WORK_DIR=$(mktemp -d /tmp/papermanager-icon.XXXXXX)
trap 'rm -rf "$ICON_WORK_DIR"' EXIT

/usr/bin/xcrun swiftc -swift-version 5 -O -sdk "$BUILD_SDK" \
  -target "$PM_TARGET" -module-cache-path "$ICON_WORK_DIR/module-cache" \
  "$PROJECT_DIR/scripts/tools/RenderAppIcon.swift" -o "$ICON_WORK_DIR/render-icon"
"$ICON_WORK_DIR/render-icon" "$ICON_SOURCE" "$ICON_WORK_DIR/exports" "$PROJECT_DIR"

# Publish only after every PNG and the compiled icon have been checked.
for ICON_DIRECTORY in \
  Sources/PaperManager/Resources/Assets.xcassets/AppIcon.appiconset \
  docs/images App/IconSource; do
  mkdir -p "$ICON_OUTPUT_ROOT/$ICON_DIRECTORY"
done
cp "$ICON_WORK_DIR/exports"/Sources/PaperManager/Resources/Assets.xcassets/AppIcon.appiconset/*.png \
  "$ICON_OUTPUT_ROOT/Sources/PaperManager/Resources/Assets.xcassets/AppIcon.appiconset/"
cp "$ICON_WORK_DIR/exports/docs/images/app-icon.png" "$ICON_OUTPUT_ROOT/docs/images/app-icon.png"
cp "$ICON_WORK_DIR/exports/App/IconSource/"* "$ICON_OUTPUT_ROOT/App/IconSource/"
cp "$ICON_WORK_DIR/exports/App/PaperManager.icns" "$ICON_OUTPUT_ROOT/App/PaperManager.icns"
printf 'Exported macOS icons to %s\n' "$ICON_OUTPUT_ROOT"
