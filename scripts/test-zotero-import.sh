#!/bin/bash
set -euo pipefail
TASK_ROOT=$(cd "$(dirname "$0")/.." && pwd)
mkdir -p "$TASK_ROOT/.build"
TASK_WORK_DIR=$(mktemp -d "$TASK_ROOT/.build/zotero-import-tests.XXXXXX")
trap 'rm -rf "$TASK_WORK_DIR"' EXIT
. "$TASK_ROOT/scripts/lib/toolchain.sh"
# Freeze the complete shared model/service dependency set before compiling.
cp "$TASK_ROOT"/Sources/PaperManager/Models/*.swift "$TASK_ROOT"/Sources/PaperManager/Services/*.swift \
    "$TASK_ROOT/Sources/PaperManager/Views/ViewUtilities.swift" "$TASK_ROOT/Tests/ZoteroImportTests.swift" "$TASK_WORK_DIR/"
/usr/bin/xcrun swiftc -swift-version 5 -sdk "$TEST_SDK" \
    "$TASK_WORK_DIR"/*.swift -o "$TASK_WORK_DIR/ZoteroImportTests"
"$TASK_WORK_DIR/ZoteroImportTests" "$TASK_WORK_DIR"
