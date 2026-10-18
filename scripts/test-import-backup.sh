#!/bin/bash
set -euo pipefail
TASK_ROOT=$(cd "$(dirname "$0")/.." && pwd)
TEST_WORK_DIR=$(mktemp -d /tmp/papermanager-import-backup.XXXXXX)
trap 'rm -rf "$TEST_WORK_DIR"' EXIT
. "$TASK_ROOT/scripts/lib/toolchain.sh"
mkdir -p "$TEST_WORK_DIR/Models" "$TEST_WORK_DIR/Services"
cp "$TASK_ROOT"/Sources/PaperManager/Models/*.swift "$TEST_WORK_DIR/Models/"
cp "$TASK_ROOT"/Sources/PaperManager/Services/*.swift "$TEST_WORK_DIR/Services/"
cp "$TASK_ROOT/Sources/PaperManager/Views/ViewUtilities.swift" "$TEST_WORK_DIR/ViewUtilities.swift"
cp "$TASK_ROOT/Tests/ImportBackupTests.swift" "$TEST_WORK_DIR/ImportBackupTests.swift"
/usr/bin/xcrun swiftc -swift-version 5 -sdk "$TEST_SDK" -target "$PM_TARGET" \
  "$TEST_WORK_DIR"/Models/*.swift "$TEST_WORK_DIR"/Services/*.swift \
  "$TEST_WORK_DIR/ViewUtilities.swift" "$TEST_WORK_DIR/ImportBackupTests.swift" \
  -o "$TEST_WORK_DIR/ImportBackupTests"
"$TEST_WORK_DIR/ImportBackupTests"
