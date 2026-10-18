#!/bin/bash
set -euo pipefail

TASK_ROOT=$(cd "$(dirname "$0")/.." && pwd)
TEST_WORK_DIR=$(mktemp -d /tmp/papermanager-intents.XXXXXX)
trap 'rm -rf "$TEST_WORK_DIR"' EXIT
. "$TASK_ROOT/scripts/lib/toolchain.sh"

mkdir "$TEST_WORK_DIR/Sources"
cp "$TASK_ROOT"/Sources/PaperManager/Models/*.swift "$TEST_WORK_DIR/Sources/"
cp "$TASK_ROOT"/Sources/PaperManager/Services/*.swift "$TEST_WORK_DIR/Sources/"
cp "$TASK_ROOT"/Sources/PaperManager/Intents/*.swift "$TEST_WORK_DIR/Sources/"
cp "$TASK_ROOT/Sources/PaperManager/Views/ViewUtilities.swift" "$TEST_WORK_DIR/Sources/"
cp "$TASK_ROOT/Tests/MetadataIntentRegression.swift" "$TEST_WORK_DIR/Sources/"
/usr/bin/xcrun swiftc -swift-version 5 -whole-module-optimization -sdk "$TEST_SDK" -target "$PM_TARGET" \
  -module-cache-path "$TASK_ROOT/.build/test-module-cache" \
  "$TEST_WORK_DIR"/Sources/*.swift -o "$TEST_WORK_DIR/MetadataIntentRegression"

"$TEST_WORK_DIR/MetadataIntentRegression"
