#!/bin/bash
set -euo pipefail
TASK_ROOT=$(cd "$(dirname "$0")/.." && pwd)
PREVIEW_WORK_DIR=$(mktemp -d /tmp/papermanager-documentation.XXXXXX)
trap 'rm -rf "$PREVIEW_WORK_DIR"' EXIT
. "$TASK_ROOT/scripts/lib/toolchain.sh"
PREVIEW_BUNDLE="$PREVIEW_WORK_DIR/DocumentationPreview.app"
PREVIEW_DOMAIN="org.papermanager.documentation-preview.$(/usr/bin/uuidgen | tr '[:upper:]' '[:lower:]')"
PREVIEW_OUTPUT="${PAPERMANAGER_DOCUMENTATION_OUTPUT:-$TASK_ROOT/docs/images}"
mkdir -p "$PREVIEW_BUNDLE/Contents/MacOS" "$PREVIEW_BUNDLE/Contents/Resources" "$PREVIEW_WORK_DIR/module-cache"
cat > "$PREVIEW_BUNDLE/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>$PREVIEW_DOMAIN</string>
<key>CFBundleExecutable</key><string>DocumentationPreview</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>LSUIElement</key><true/>
</dict></plist>
PLIST
cp -R "$TASK_ROOT"/Sources/PaperManager/Resources/*.lproj "$PREVIEW_BUNDLE/Contents/Resources/"
PREVIEW_SOURCES=(
  "$TASK_ROOT"/Sources/PaperManager/Models/*.swift \
  "$TASK_ROOT"/Sources/PaperManager/Services/*.swift \
  "$TASK_ROOT"/Sources/PaperManager/Views/NativeLibrary*.swift \
  "$TASK_ROOT/Sources/PaperManager/Views/PaperDetailView.swift" \
  "$TASK_ROOT/Sources/PaperManager/Views/InspectorInlineEditor.swift" \
  "$TASK_ROOT/Sources/PaperManager/Views/ViewUtilities.swift" \
  "$TASK_ROOT/Sources/PaperManager/Views/AddPaperSheets.swift" \
  "$TASK_ROOT/Sources/PaperManager/Views/ImportPreviewView.swift" \
  "$TASK_ROOT/Sources/PaperManager/Views/SettingsView.swift" \
  "$TASK_ROOT/Sources/PaperManager/Views/HelpView.swift" \
  "$TASK_ROOT/Sources/PaperManager/Views/ZoteroImportView.swift"
)
/usr/bin/xcrun swiftc -swift-version 5 -whole-module-optimization \
  -sdk "$TEST_SDK" -target "$PM_TARGET" -module-cache-path "$PREVIEW_WORK_DIR/module-cache" \
  "${PREVIEW_SOURCES[@]}" \
  "$TASK_ROOT/scripts/tools/DocumentationPreview.swift" \
  -o "$PREVIEW_BUNDLE/Contents/MacOS/DocumentationPreview"
PAPERMANAGER_LIBRARY_PATH="$PREVIEW_WORK_DIR/demo-library.json" \
PAPERMANAGER_DOCUMENTATION_OUTPUT="$PREVIEW_OUTPUT" \
  "$PREVIEW_BUNDLE/Contents/MacOS/DocumentationPreview"
/usr/bin/python3 - "$TASK_ROOT" "$PREVIEW_OUTPUT" "${PREVIEW_SOURCES[@]}" <<'PY'
import hashlib
import json
from pathlib import Path
import platform
import struct
import sys

root, output = map(Path, sys.argv[1:3])
manifest_path = output / "manifest.json"
manifest = json.loads(manifest_path.read_text())
sha256 = lambda path: hashlib.sha256(path.read_bytes()).hexdigest()
manifest["sourceSHA256"] = {str(Path(path).relative_to(root)): sha256(Path(path)) for path in sys.argv[3:]}
manifest["generatorSHA256"] = {str(path.relative_to(root)): sha256(path) for path in [
    root / "scripts/tools/DocumentationPreview.swift", root / "scripts/render-readme-images.sh"]}
manifest["imageSHA256"] = {entry["file"]: sha256(output / entry["file"]) for entry in manifest["images"]}
for entry in manifest["images"]:
    png = (output / entry["file"]).read_bytes()
    if png[:8] != b"\x89PNG\r\n\x1a\n" or list(struct.unpack(">II", png[16:24])) != entry["pixels"]:
        raise SystemExit("Unexpected PNG dimensions: " + entry["file"])
manifest["renderHost"] = {"system": platform.system(), "version": platform.mac_ver()[0], "architecture": platform.machine()}
manifest["validation"] = "All generated image pixels were verified alpha=255 by the renderer. Native descendants use an explicit Aqua drawing appearance for offscreen caching."
manifest_path.write_text(json.dumps(manifest, ensure_ascii=False, indent=2, sort_keys=True) + "\n")
PY
