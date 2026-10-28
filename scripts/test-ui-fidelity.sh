#!/bin/bash
set -euo pipefail

TASK_ROOT=$(cd "$(dirname "$0")/.." && pwd)
. "$TASK_ROOT/scripts/lib/toolchain.sh"
TEST_WORK_DIR=$(mktemp -d /tmp/papermanager-ui-fidelity.XXXXXX)
trap 'rm -rf "$TEST_WORK_DIR"' EXIT

SOURCE_LIBRARY=${PAPERMANAGER_UI_FIDELITY_SOURCE:-${1:-}}
OUTPUT_DIR=${PAPERMANAGER_UI_FIDELITY_OUTPUT:-${2:-"$TASK_ROOT/.build/ui-fidelity-20261024/native-host"}}
if [[ "$SOURCE_LIBRARY" != /* || ! -r "$SOURCE_LIBRARY" ]]; then
  printf '%s\n' 'Usage: scripts/test-ui-fidelity.sh /absolute/read-only/source-library.json [/absolute/output-directory]'
  exit 2
fi
if [[ "$OUTPUT_DIR" != /* ]]; then
  printf '%s\n' 'The artifact output directory must be absolute.'
  exit 2
fi

mkdir -p "$TEST_WORK_DIR/Sources" "$TASK_ROOT/.build/test-module-cache" "$OUTPUT_DIR"
cp "$TASK_ROOT"/Sources/PaperManager/Models/*.swift "$TASK_ROOT"/Sources/PaperManager/Services/*.swift \
  "$TASK_ROOT/Sources/PaperManager/Views/ViewUtilities.swift" \
  "$TASK_ROOT/Sources/PaperManager/Views/PaperDetailView.swift" \
  "$TASK_ROOT/Sources/PaperManager/Views/PaperPDFPreview.swift" \
  "$TASK_ROOT/Sources/PaperManager/Views/InspectorInlineEditor.swift" \
  "$TASK_ROOT"/Sources/PaperManager/Views/NativeLibrary*.swift \
  "$TASK_ROOT/Tests/UIFidelitySmoke.swift" "$TEST_WORK_DIR/Sources/"
/usr/bin/xcrun swiftc -swift-version 5 -whole-module-optimization \
  -sdk "$TEST_SDK" -target "$PM_TARGET" \
  -module-cache-path "$TASK_ROOT/.build/test-module-cache" \
  "$TEST_WORK_DIR"/Sources/*.swift -o "$TEST_WORK_DIR/UIFidelitySmoke"

PAPERMANAGER_UI_FIDELITY_SOURCE="$SOURCE_LIBRARY" PAPERMANAGER_UI_FIDELITY_OUTPUT="$OUTPUT_DIR" \
  "$TEST_WORK_DIR/UIFidelitySmoke"
