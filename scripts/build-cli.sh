#!/bin/bash
set -euo pipefail

TASK_ROOT=$(cd "$(dirname "$0")/.." && pwd)
. "$TASK_ROOT/scripts/lib/toolchain.sh"
BUILD_DIR=${PAPERMANAGER_CLI_BUILD_DIR:-"$TASK_ROOT/.build/cli"}
mkdir -p "$BUILD_DIR"
/usr/bin/xcrun swiftc -parse-as-library -swift-version 5 -whole-module-optimization \
  -sdk "$BUILD_SDK" -target "$PM_TARGET" \
  -module-cache-path "$TASK_ROOT/.build/test-module-cache" \
  "$TASK_ROOT"/Sources/PaperManagerCLI/*.swift -o "$BUILD_DIR/PaperManagerCLI"
/usr/bin/codesign --force --sign - "$BUILD_DIR/PaperManagerCLI"
/usr/bin/codesign --verify --strict "$BUILD_DIR/PaperManagerCLI"
printf '%s\n' "$BUILD_DIR/PaperManagerCLI"
