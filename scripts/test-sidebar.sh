#!/bin/bash
set -euo pipefail

TASK_ROOT=$(cd "$(dirname "$0")/.." && pwd)
TEST_WORK_DIR=$(mktemp -d /tmp/papermanager-sidebar.XXXXXX)
trap 'rm -rf "$TEST_WORK_DIR"' EXIT
. "$TASK_ROOT/scripts/lib/toolchain.sh"

# Compile a fixed source snapshot so another editor cannot invalidate a running
# regression build while unrelated app work continues in the shared workspace.
mkdir "$TEST_WORK_DIR/Sources"
cp "$TASK_ROOT"/Sources/PaperManager/Models/*.swift "$TEST_WORK_DIR/Sources/"
cp "$TASK_ROOT"/Sources/PaperManager/Services/*.swift "$TEST_WORK_DIR/Sources/"
cp "$TASK_ROOT/Sources/PaperManager/Views/ViewUtilities.swift" "$TEST_WORK_DIR/Sources/"
cp "$TASK_ROOT/Tests/SidebarRegression.swift" "$TEST_WORK_DIR/Sources/"
/usr/bin/xcrun swiftc -swift-version 5 -whole-module-optimization -sdk "$TEST_SDK" -target "$PM_TARGET" \
  -module-cache-path "$TASK_ROOT/.build/test-module-cache" \
  "$TEST_WORK_DIR"/Sources/*.swift -o "$TEST_WORK_DIR/SidebarRegression"

"$TEST_WORK_DIR/SidebarRegression"
