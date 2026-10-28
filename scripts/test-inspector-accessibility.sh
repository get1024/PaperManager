#!/bin/bash
set -euo pipefail
TASK_ROOT=$(cd "$(dirname "$0")/.." && pwd)
mkdir -p "$TASK_ROOT/.build"
TEST_MODE=${1:-nativeHosted}
TEST_CLIENT=${2:-external}
TEST_PHASE=${3:-two-phase}
TEST_WORK_DIR=$(mktemp -d "$TASK_ROOT/.build/inspector-accessibility.XXXXXX")
export PAPERMANAGER_AX_FIXTURE_DIR="$TEST_WORK_DIR/Fixture"
trap 'rm -rf "$TEST_WORK_DIR"' EXIT
. "$TASK_ROOT/scripts/lib/toolchain.sh"
mkdir -p "$TEST_WORK_DIR/Sources" "$TASK_ROOT/.build/test-module-cache"
cp "$TASK_ROOT"/Sources/PaperManager/Models/*.swift "$TASK_ROOT"/Sources/PaperManager/Services/*.swift \
    "$TASK_ROOT/Sources/PaperManager/Views/ViewUtilities.swift" \
    "$TASK_ROOT/Sources/PaperManager/Views/PaperDetailView.swift" \
  "$TASK_ROOT/Sources/PaperManager/Views/PaperPDFPreview.swift" \
    "$TASK_ROOT/Sources/PaperManager/Views/InspectorInlineEditor.swift" \
    "$TASK_ROOT"/Sources/PaperManager/Views/NativeLibrary*.swift \
    "$TASK_ROOT/Tests/InspectorAccessibilitySmoke.swift" "$TEST_WORK_DIR/Sources/"
# The optional negative control restores the old label only in the disposable
# copied source, never in the working app or the user's library.
if [[ -n "${PAPERMANAGER_AX_SOURCE_PATCH:-}" ]]; then
    python3 - "$TEST_WORK_DIR/Sources/PaperDetailView.swift" "$PAPERMANAGER_AX_SOURCE_PATCH" <<'PY'
import pathlib,sys
p=pathlib.Path(sys.argv[1]);source=p.read_text();mode=sys.argv[2]
if mode=='restore-citekey-label':
    needle='Text(paper.citekey)\n                        .textSelection(.enabled)'; assert source.count(needle)==1
    source=source.replace(needle,needle+'\n                        .accessibilityLabel("引用键")')
else: raise SystemExit('Unknown counterfactual patch')
p.write_text(source)
PY
fi
/usr/bin/xcrun swiftc -swift-version 5 -sdk "$TEST_SDK" -target "$PM_TARGET" \
    -module-cache-path "$TASK_ROOT/.build/test-module-cache" \
    "$TEST_WORK_DIR"/Sources/*.swift -o "$TEST_WORK_DIR/InspectorAccessibilitySmoke"
if [[ "$TEST_CLIENT" == "external" ]]; then
    /usr/bin/xcrun swiftc -parse-as-library -sdk "$TEST_SDK" "$TASK_ROOT/Tests/InspectorAXClient.swift" -o "$TEST_WORK_DIR/InspectorAXClient"
    if [[ "$TEST_PHASE" == "two-phase" ]]; then
        export PAPERMANAGER_AX_PHASE_FILE="$TEST_WORK_DIR/select-phase"
    fi
    PAPERMANAGER_AX_SERVE=1 "$TEST_WORK_DIR/InspectorAccessibilitySmoke" "$TEST_MODE" &
    TEST_HOST_PID=$!
    set +e
    "$TEST_WORK_DIR/InspectorAXClient" "$TEST_HOST_PID"
    TEST_RESULT=$?
    kill "$TEST_HOST_PID" 2>/dev/null
    wait "$TEST_HOST_PID" 2>/dev/null
    exit "$TEST_RESULT"
else
    "$TEST_WORK_DIR/InspectorAccessibilitySmoke" "$TEST_MODE"
fi
