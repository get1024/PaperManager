# PaperManager

![macOS](https://img.shields.io/badge/platform-macOS%2014%2B-black)
![Swift](https://img.shields.io/badge/Swift-5.9-orange)
![SwiftUI](https://img.shields.io/badge/UI-SwiftUI-blue)

![PaperManager icon](assets/icon.PNG)

## 1. What does this do?

PaperManager is a native macOS reference manager for collecting, organizing, reading, and exporting academic papers.

- Import PDF, BibTeX, RIS, folders, and DOI metadata.
- Organize papers with collections, tags, ratings, citekeys, and custom fields.
- Attach PDFs, extract PDF metadata and annotations, and open papers in a preferred PDF reader.
- Export BibTeX, RIS, and Markdown metadata using editable templates.
- Provide a local connector API for browser-extension or automation workflows.
- Use a Lattice-inspired macOS interface: compact sidebar, rounded grouped settings, right-side inspector, and lightweight document list.

## 2. Recent Updates

- [June 16, 2026] Added the custom PaperManager app icon and wired it through the macOS `AppIcon` asset catalog.
- [June 16, 2026] Reworked the main SwiftUI shell to mirror Lattice-style navigation: sidebar search, document filters, centered empty states, compact toolbar menus, and inspector toggling.
- [June 16, 2026] Rebuilt Settings with a Lattice-style sidebar and grouped controls for General, Citation, Local API, Backup, and Templates.
- [June 16, 2026] Added preferred PDF reader configuration while preserving existing PDF organization, rename, copy/move, export, and Local API logic.

## 3. Use

### 3.1 Local Development

Open the Xcode project:

```bash
open PaperManager.xcodeproj
```

Select the `PaperManager` scheme and run it. The native app bundle uses:

- Bundle identifier: `com.aurelian.PaperManager`
- Minimum OS: macOS 14
- App icon: `Sources/PaperManager/Resources/Assets.xcassets/AppIcon.appiconset`

The Swift Package executable can be built for quick checks:

```bash
swift build
```

### 3.2 Import Papers

Use the `+` menu or `Command-I` to import local files:

```text
PDF, BibTeX, RIS, or folders containing supported files
```

Use `Shift-Command-D` to add a paper by DOI through Crossref metadata lookup.

### 3.3 Export

Use the share menu or `Command-E` to export the current selection or the visible filtered library:

```text
BibTeX, RIS, or detailed Markdown
```

If no rows are selected, export commands operate on the visible filter result.

### 3.4 GitHub Release

The repository includes a GitHub Actions workflow at `.github/workflows/release.yml`.

- Pushes to `main` build a macOS DMG and upload it as a workflow artifact.
- Pushing a tag such as `v1.0.0` builds `PaperManager-v1.0.0.dmg` and publishes a GitHub Release.
- Manual workflow runs can create a release by filling the `release_tag` input.

The DMG contains `PaperManager.app` and an `/Applications` shortcut for drag-to-install distribution. CI ad-hoc signs the app bundle, but it does not notarize it.

## 4. Technical Details

### 4.1 Storage

PaperManager stores the library as JSON:

```text
~/Library/Application Support/PaperManager/library.json
```

The snapshot contains papers, collections, tags, settings, attachments, annotations, custom fields, and templates.

### 4.2 Import Pipeline

- PDF metadata and annotation extraction use PDFKit.
- DOI enrichment uses Crossref.
- BibTeX and RIS imports use local parsers.
- Duplicate detection checks DOI, ISBN, and title/year.
- PDF organization can copy or move attachments into a chosen folder, grouped by year, author initial, or collection.

### 4.3 Local API

When enabled in Settings, PaperManager listens on:

```text
http://127.0.0.1:29467
```

Implemented endpoints include:

| Endpoint | Purpose |
| --- | --- |
| `GET /connector/status` | Connector status and capabilities |
| `GET /connector/collections` | Collection list |
| `GET /connector/tags` | Tag list |
| `GET /connector/metadata?doi=...` | Crossref DOI lookup |
| `POST /connector/papers` | Create a paper |
| `PUT /connector/papers/{id}/pdf` | Attach/upload a PDF |
| `GET /api/v1/papers` | Public API paper list |
| `GET /api/v1/papers/{id}` | Public API paper detail |

## 5. Project Information

### 5.1 Acknowledgement

PaperManager's current interface is inspired by Lattice's macOS layout and interaction model. It is not affiliated with Lattice.

The README structure follows the public README organization of [PDFMathTranslate/PDFMathTranslate](https://github.com/PDFMathTranslate/PDFMathTranslate).

### 5.2 Development Notes

This repository is a native SwiftUI macOS app. Use the Xcode target for app-bundle validation, signing, archive, and release work. Use SwiftPM for fast compile checks.
