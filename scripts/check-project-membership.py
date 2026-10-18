#!/usr/bin/env python3
"""Check the manually maintained Xcode project without requiring full Xcode.

This is a project membership/plist check, not an xcodebuild result.
"""
import json
from pathlib import Path
import plistlib
import re
import subprocess

root = Path(__file__).resolve().parent.parent
project_path = root / "PaperManager.xcodeproj/project.pbxproj"
raw = project_path.read_text()
ids = re.findall(r"^\t\t([A-Z0-9]{24})(?: /\*.*?\*/)? = \{", raw, re.MULTILINE)
assert len(ids) == len(set(ids)), "Duplicate Xcode object IDs"
project = json.loads(subprocess.check_output([
    "/usr/bin/plutil", "-convert", "json", "-o", "-", str(project_path)
]))
objects = project["objects"]
main_group = objects[project["rootObject"]]["mainGroup"]
paths = {}


def walk(identifier, parent, ancestors=()):
    assert identifier not in ancestors, "Cycle in Xcode groups"
    item = objects[identifier]
    if item.get("sourceTree", "<group>") == "BUILT_PRODUCTS_DIR":
        return
    path = parent / item.get("path", "")
    paths[identifier] = path
    for child in item.get("children", []):
        walk(child, path, ancestors + (identifier,))


walk(main_group, root)
targets = [item for item in objects.values()
           if item.get("isa") == "PBXNativeTarget" and item.get("name") == "PaperManager"]
assert len(targets) == 1, "Expected one PaperManager app target"
source_paths = []
resource_paths = []
for phase_id in targets[0]["buildPhases"]:
    phase = objects[phase_id]
    for build_id in phase.get("files", []):
        reference = objects[build_id]["fileRef"]
        if phase["isa"] == "PBXSourcesBuildPhase":
            source_paths.append(paths[reference])
        elif phase["isa"] == "PBXResourcesBuildPhase":
            resource_paths.append(paths[reference])
            resource_paths += [paths[child] for child in objects[reference].get("children", [])]

actual = set((root / "Sources/PaperManager").rglob("*.swift"))
assert len(source_paths) == len(set(source_paths)), "Duplicate Swift compile entries"
assert set(source_paths) == actual, (
    "Xcode Swift membership differs from disk",
    sorted(str(p.relative_to(root)) for p in actual - set(source_paths)),
    sorted(str(p.relative_to(root)) for p in set(source_paths) - actual),
)
for source in source_paths:
    assert source.is_file(), source

# The app's exporting UI needs a genuine built CLI product, not a source file
# copied by an unverified shell phase. Check the entire native-target graph.
project_target_ids = objects[project["rootObject"]]["targets"]
cli_target_ids = [identifier for identifier in project_target_ids
                  if objects[identifier].get("name") == "PaperManagerCLI"]
assert len(cli_target_ids) == 1, "Expected one PaperManagerCLI target in the project"
cli_target_id = cli_target_ids[0]
cli = objects[cli_target_id]
assert cli["isa"] == "PBXNativeTarget"
assert cli["productType"] == "com.apple.product-type.tool", "CLI must be a command-line executable target"
cli_product_id = cli["productReference"]
cli_product = objects[cli_product_id]
assert cli_product["sourceTree"] == "BUILT_PRODUCTS_DIR"
assert cli_product["path"] == "PaperManagerCLI"
assert cli_product["explicitFileType"] == "compiled.mach-o.executable"
cli_sources = []
for phase_id in cli["buildPhases"]:
    phase = objects[phase_id]
    assert phase["isa"] != "PBXShellScriptBuildPhase", "CLI must use native compile/link phases"
    if phase["isa"] == "PBXSourcesBuildPhase":
        cli_sources += [paths[objects[build_id]["fileRef"]] for build_id in phase["files"]]
actual_cli = set((root / "Sources/PaperManagerCLI").glob("*.swift"))
assert len(actual_cli) == 4, "Review the expected CLI source inventory when adding files"
assert len(cli_sources) == len(set(cli_sources)) == 4, "CLI compile entries must occur exactly once"
assert set(cli_sources) == actual_cli, "CLI source membership differs from disk or includes Tests"
assert set(source_paths).isdisjoint(cli_sources), "App and CLI must compile separate entry points"
dependencies = [objects[identifier] for identifier in targets[0]["dependencies"]]
cli_dependencies = [item for item in dependencies if item.get("target") == cli_target_id]
assert len(cli_dependencies) == 1, "App must depend on the CLI native target"
proxy = objects[cli_dependencies[0]["targetProxy"]]
assert proxy["isa"] == "PBXContainerItemProxy"
assert proxy["containerPortal"] == project["rootObject"]
assert str(proxy["proxyType"]) == "1" and proxy["remoteGlobalIDString"] == cli_target_id
copies = []
for phase_id in targets[0]["buildPhases"]:
    phase = objects[phase_id]
    if phase["isa"] != "PBXCopyFilesBuildPhase":
        continue
    for build_id in phase.get("files", []):
        build = objects[build_id]
        if build.get("fileRef") == cli_product_id:
            copies.append((phase, build))
assert len(copies) == 1, "CLI product must be embedded exactly once"
copy_phase, copied_product = copies[0]
# Wrapper (1) starts at PaperManager.app, unlike Products Directory (16).
# Apple's Copy Files destination plus subpath semantics therefore produce
# PaperManager.app/Contents/Helpers/PaperManagerCLI.
assert str(copy_phase["dstSubfolderSpec"]) == "1", "Helpers must be relative to the app wrapper"
assert copy_phase["dstPath"] == "Contents/Helpers", "CLI must be copied to Contents/Helpers"
assert str(copy_phase["runOnlyForDeploymentPostprocessing"]) == "0", "Debug builds must also embed the CLI"
assert "CodeSignOnCopy" in copied_product.get("settings", {}).get("ATTRIBUTES", []), "Embedded CLI needs CodeSignOnCopy"
for configuration_id in objects[cli["buildConfigurationList"]]["buildConfigurations"]:
    settings = objects[configuration_id]["buildSettings"]
    assert str(settings["MACOSX_DEPLOYMENT_TARGET"]) == "14.0"
    assert str(settings["SWIFT_VERSION"]) == "5.0"
    assert settings["CODE_SIGN_STYLE"] == "Automatic"
    assert settings["ENABLE_HARDENED_RUNTIME"] == "YES"
    assert settings["SKIP_INSTALL"] == "YES", "Archive must embed the CLI, not install it separately"
for language in ["en", "zh-Hans"]:
    strings = root / f"Sources/PaperManager/Resources/{language}.lproj/Localizable.strings"
    assert strings in resource_paths and strings.is_file(), f"Missing {language} strings resource"
assert root / "BrowserExtension" in resource_paths, "Missing unpacked browser connector resource"
regions = objects[project["rootObject"]]["knownRegions"]
assert "en" in regions and "zh-Hans" in regions, "Missing localization region"
assert "PaperListView.swift" not in raw and "SidebarView.swift" not in raw, "Deleted source still referenced"
info = plistlib.loads((root / "App/Info.plist").read_bytes())
backup = next(item for item in info["UTExportedTypeDeclarations"]
              if item["UTTypeIdentifier"] == "com.aurelian.papermanager.library-backup")
assert "public.zip-archive" in backup["UTTypeConformsTo"]
assert "application/vnd.aurelian.papermanager+zip" in backup["UTTypeTagSpecification"]["public.mime-type"]
print(f"PASS Xcode plist and complete app source membership: {len(actual)} Swift files")
print("PASS native CLI target: 4 exact sources, app dependency, signed Wrapper/Contents/Helpers copy")
print("PASS English/Chinese strings, unpacked browser resources, regions, and backup ZIP UTI")
print("Full Xcode build is not checked by this script.")
