# Lattice Recovery Notes

Recovered from `/Applications/Lattice.app` on 2026-06-16.

## Bottom line

The installed app is a native macOS Swift app, not an Electron or script bundle. The main binaries are stripped: `nm` exposes only `__mh_execute_header`, so the original Swift source cannot be mechanically restored line-for-line from this app bundle.

Useful recoverable material is still present:

- Swift/ObjC runtime metadata with 53 main-app classes and ivars.
- SwiftData/Core Data SQLite schema from the local sandbox store.
- Local API and Safari extension protocol.
- Reformatted Safari Web Extension JS/CSS/HTML.
- Localized strings, StoreKit config, App Intents metadata, PrivacyInfo, asset catalog info.
- 69 likely original Swift source file names recovered from embedded strings.

## App fingerprint

- Bundle id: `com.aurelian.Lattice`
- Version: `2.4` build `20`
- Main executable: `Contents/MacOS/Lattice`
- Helper executable: `Contents/MacOS/LatticePicker`
- Safari extension: `Lattice Safari Extension Extension.appex`
- Minimum macOS: `14.0`
- Built with Xcode `17E202`, SDK `macosx26.4`
- Main frameworks include SwiftUI, SwiftData, PDFKit, AppKit, StoreKit, Vision, QuickLookUI, Network, SQLite.

## Folder guide

- `original-metadata/`
  - Info.plist, entitlements, linked frameworks, bundle file list, recovered URLs/API paths.
- `main-app/`
  - `classes-and-ivars.md`: readable Swift runtime class report.
  - `classes-and-ivars.json`: same data as JSON.
  - `Lattice.arm64.otool-objc-swift-metadata.txt`: raw `otool -ov` output.
  - `Lattice.strings.txt`: raw binary strings.
  - `recovered-source-file-names.txt`: likely original Swift file names.
- `database/`
  - `default-store-schema.sql`: schema only, extracted from the app sandbox SQLite store.
  - `default-store-entity-counts.tsv`: entity names and max primary keys from `Z_PRIMARYKEY`.
- `safari-extension/`
  - `dist/`: original packaged extension resources.
  - `reformatted/`: stable filenames and Prettier-formatted JS/CSS/HTML.
- `resources/`
  - Localizations, App Intents metadata, StoreKit config, PrivacyInfo, asset catalog dump, icon.
- `reconstructed-source/`
  - Hand-written reconstruction notes and starting-point source sketches.
  - `ReconstructedModels.swift` keeps the likely SwiftData shape.
  - `PlainModels.swift` is a compiler-checkable non-SwiftData version for migration logic.

## Key recovered architecture

Data model classes:

- `Paper`
- `PaperAttachment`
- `PaperCollection`
- `PDFAnnotationItem`
- `Tag`
- `MetadataTemplate`

Important service/controller classes:

- `LocalCitationBridgeServer`
- `PaperRefreshCoordinator`
- `PDFStructuredMetadataExtractor`
- `LibraryRestoreCoordinator`
- `ProUnlockController`
- `ZoteroImportService`
- `PaperTableViewController`
- `SidebarOutlineViewController`
- `MainSplitViewController`

Local browser-extension API:

- Default base URL: `http://127.0.0.1:29467`
- Connector prefix: `/connector`
- Endpoints include `/status`, `/metadata`, `/papers`, `/papers/{id}/pdf`, `/collections`, `/tags`

External metadata services visible in strings:

- Crossref
- OpenAlex
- Semantic Scholar
- arXiv
- OpenLibrary
- NCBI PMC id converter

## Best path for second development

Use this package as a reconstruction guide rather than as literal source:

1. Start from `reconstructed-source/ReconstructedModels.swift` for the SwiftData schema.
2. Rebuild `LocalCitationBridgeServer` from `reconstructed-source/ConnectorAPI.md` and the formatted extension client.
3. Port or rewrite the Safari extension from `safari-extension/reformatted/`.
4. Use `main-app/recovered-source-file-names.txt` as the module/file roadmap.
5. Use `main-app/classes-and-ivars.md` to recover class responsibilities and stored properties.

If a dSYM or old Xcode archive is found later, rerun symbol extraction with that dSYM first; it will substantially improve the recovery quality.

## Verification

- `safari-extension/reformatted/*` passes Prettier check.
- `reconstructed-source/PlainModels.swift` passes `xcrun swiftc -typecheck`.
- `reconstructed-source/ReconstructedModels.swift` was not typechecked in this shell because the installed CommandLineTools `swiftc` cannot load `SwiftDataMacros` outside a full Xcode macro-enabled target.
