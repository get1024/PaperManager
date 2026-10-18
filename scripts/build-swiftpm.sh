#!/bin/bash
set -euo pipefail

TASK_ROOT=$(cd "$(dirname "$0")/.." && pwd)
. "$TASK_ROOT/scripts/lib/toolchain.sh"
BUILD_DIR=${PAPERMANAGER_SWIFTPM_BUILD_DIR:-"$TASK_ROOT/.build/swiftpm-native"}
BUILD_JOBS=${PAPERMANAGER_BUILD_JOBS:-2}
# Swift 6.4 defaults to swiftbuild. Select the native SwiftPM engine explicitly
# for the documented CLT-only path; this does not invoke xcodebuild.
/usr/bin/xcrun swift build --build-system native --package-path "$TASK_ROOT" \
  --scratch-path "$BUILD_DIR" --sdk "$BUILD_SDK" \
  --triple "$PM_TARGET" --jobs "$BUILD_JOBS" "$@"
