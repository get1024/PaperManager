#!/bin/bash
set -euo pipefail
TASK_ROOT=$(cd "$(dirname "$0")/.." && pwd)
mkdir -p "$TASK_ROOT/.build"
TEST_WORK_DIR=$(mktemp -d "$TASK_ROOT/.build/native-table-ax-perf.XXXXXX")
trap 'rm -rf "$TEST_WORK_DIR"' EXIT
. "$TASK_ROOT/scripts/lib/toolchain.sh"
export PAPERMANAGER_AX_FIXTURE_DIR="$TEST_WORK_DIR/Fixture"
export PAPERMANAGER_AX_ROWS=${PAPERMANAGER_AX_ROWS:-72}
export PAPERMANAGER_AX_NO_SELECTION=1
export PAPERMANAGER_AX_SERVER_TIMEOUT=120
export PAPERMANAGER_AX_PERF_FINISH="$TEST_WORK_DIR/finished"
mkdir -p "$TEST_WORK_DIR/Sources" "$TASK_ROOT/.build/test-module-cache"
cp "$TASK_ROOT"/Sources/PaperManager/Models/*.swift "$TASK_ROOT"/Sources/PaperManager/Services/*.swift \
    "$TASK_ROOT/Sources/PaperManager/Views/ViewUtilities.swift" \
    "$TASK_ROOT/Sources/PaperManager/Views/PaperDetailView.swift" \
    "$TASK_ROOT/Sources/PaperManager/Views/InspectorInlineEditor.swift" \
    "$TASK_ROOT/Tests/InspectorAccessibilitySmoke.swift" "$TEST_WORK_DIR/Sources/"
cp "$TASK_ROOT"/Sources/PaperManager/Views/NativeLibrary*.swift "$TEST_WORK_DIR/Sources/"
cp "${PAPERMANAGER_AX_NATIVE_SOURCE:-$TASK_ROOT/Sources/PaperManager/Views/NativeLibraryView.swift}" "$TEST_WORK_DIR/Sources/NativeLibraryView.swift"
# Instrument only the disposable copied source, without changing its behavior.
python3 - "$TEST_WORK_DIR/Sources/NativeLibraryCells.swift" <<'PY'
import pathlib,sys
p=pathlib.Path(sys.argv[1]);s=p.read_text();start=s.index('final class NativeTextCell: NSTableCellView {');end=s.index('final class NativeRatingCell:',start)
cell=s[start:end]
cell=cell.replace('super.init(frame: .zero)','super.init(frame: .zero)\n        nativeAXPerfTextCellInitializations += 1',1)
signature='func configure(symbol: String = "", text: String, trailing: String = "") {'
assert cell.count(signature)==1
cell=cell.replace(signature,signature+'\n        nativeAXPerfTextCellConfigurations += 1',1)
cell=cell.replace('textField?.stringValue = text','nativeAXPerfTextCellChanges += 1\n        textField?.stringValue = text',1)
globals='var nativeAXPerfTextCellInitializations = 0\nvar nativeAXPerfTextCellConfigurations = 0\nvar nativeAXPerfTextCellChanges = 0\n\n'
p.write_text(s[:start]+globals+cell+s[end:])
PY
/usr/bin/xcrun swiftc -swift-version 5 -D NATIVE_AX_PERF -sdk "$TEST_SDK" -target "$PM_TARGET" \
    -module-cache-path "$TASK_ROOT/.build/test-module-cache" \
    "$TEST_WORK_DIR"/Sources/*.swift -o "$TEST_WORK_DIR/NativeTableAXHost"
/usr/bin/xcrun swiftc -parse-as-library -sdk "$TEST_SDK" "$TASK_ROOT/Tests/NativeTableAXClient.swift" -o "$TEST_WORK_DIR/NativeTableAXClient"
PAPERMANAGER_AX_SERVE=1 "$TEST_WORK_DIR/NativeTableAXHost" nativeHosted &
TEST_HOST_PID=$!
set +e
"$TEST_WORK_DIR/NativeTableAXClient" "$TEST_HOST_PID"
TEST_RESULT=$?
kill "$TEST_HOST_PID" 2>/dev/null
wait "$TEST_HOST_PID" 2>/dev/null
exit "$TEST_RESULT"
