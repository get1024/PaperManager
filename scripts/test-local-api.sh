#!/bin/bash
set -euo pipefail

TASK_ROOT=$(cd "$(dirname "$0")/.." && pwd)
TEST_WORK_DIR=$(mktemp -d /tmp/papermanager-api-tests.XXXXXX)
trap 'rm -rf "$TEST_WORK_DIR"' EXIT
. "$TASK_ROOT/scripts/lib/toolchain.sh"

SOURCES=("$TASK_ROOT"/Sources/PaperManager/Models/*.swift "$TASK_ROOT"/Sources/PaperManager/Services/*.swift)
mkdir "$TEST_WORK_DIR/sources"
cp "${SOURCES[@]}" "$TASK_ROOT/Sources/PaperManager/Views/ViewUtilities.swift" "$TASK_ROOT/Tests/LocalAPITests.swift" "$TEST_WORK_DIR/sources/"
/usr/bin/xcrun swiftc -swift-version 5 -sdk "$TEST_SDK" -target "$PM_TARGET" \
  -module-cache-path "$TEST_WORK_DIR/module-cache" \
  "$TEST_WORK_DIR"/sources/*.swift -o "$TEST_WORK_DIR/LocalAPITests"

"$TEST_WORK_DIR/LocalAPITests"
