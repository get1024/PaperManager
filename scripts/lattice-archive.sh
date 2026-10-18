#!/bin/bash
set -euo pipefail
TASK_ROOT=$(cd "$(dirname "$0")/.." && pwd)
. "$TASK_ROOT/scripts/lib/toolchain.sh"
TASK_TOOL_DIR="$TASK_ROOT/.build/helpers"
mkdir -p "$TASK_TOOL_DIR"
/usr/bin/xcrun swiftc -swift-version 5 -sdk "$BUILD_SDK" \
    "$TASK_ROOT"/Sources/PaperManager/Models/*.swift \
    "$TASK_ROOT"/Sources/PaperManager/Services/*.swift \
    "$TASK_ROOT/Sources/PaperManager/Views/ViewUtilities.swift" \
    "$TASK_ROOT/scripts/tools/LatticeArchiveMain.swift" -o "$TASK_TOOL_DIR/LatticeArchive"
exec "$TASK_TOOL_DIR/LatticeArchive" "$@"
