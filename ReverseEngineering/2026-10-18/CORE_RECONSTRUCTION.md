# Native editing, organization, and intent reconstruction

This change uses the reference field and organization contract in `FEATURE_CONTRACT.md` and the actual Lattice 3.0 advanced-fields accessibility capture at `.build/qa-2026-10-18/lattice-advanced-sheet.ax.txt`. It implements behavior in the reconstruction; it does not represent recovered original Swift source.

## Inspector and editing lifecycle

- A `PaperDraftSession` owns the draft and merges only edited fields into the latest stored paper. Binding writes reach the session synchronously. Switching records, clearing selection, SwiftUI disappearance, leaving the application, and normal application termination flush pending edits.
- Flush uses the durable store update and returns success only after the atomic write succeeds. A failed write keeps its original baseline and draft; switching papers defers that draft, and closing its window retains the failed session for retry. A successful later global flush saves and releases it. Application termination is cancelled while any draft remains unsaved; restore and backup callers can use the same Boolean guard before continuing.
- A binding captures its paper identity, so callbacks from an old editor cannot write into the new selection. Async annotation and metadata completions check whether their editor is still current and otherwise update the requested paper in the store.
- DOI, ISBN, and eprint are independent fields. Replacing or clearing one does not clear or hide another. All 15 paper types are available, including distinct `inBook` and `inCollection`; BibTeX recognizes `thesis`, `preprint`, and `incollection`.
- Standard fields appear by paper type. Existing nonempty fields remain available regardless of the selected type. The advanced-fields sheet includes the reference preprint fields and a pin control for each standard field. Standard pins persist globally in the app's UserDefaults under `PaperManager.Inspector.pinnedStandardFields`. Custom-field pins remain per paper and appear in More Fields.
- The native split no longer sets divider positions during its first layout, allowing AppKit autosave to restore widths. Native paper selection uses a stored value snapshot rather than rereading an old SwiftUI Binding when deciding whether to scroll.
- PDF replacement passes `replacePrimary: true` to the shared attachment service; previous attachments and read-only source authority remain managed by that service.

## Collection and tag organization

- `createCollection` is a recoverable throwing API. It rejects missing parents, invalid ancestry, and a fourth level. Production UI uses this API. The old `addCollection` convenience remains only for already-valid internal fixture requests and asserts on an invalid programmer request.
- Moving a collection validates the entire subtree, rejects descendant parents and cycles, and normalizes sibling sort positions. Native outline drag and drop handles reorder and reparent operations. Moving to the root is also available in the context menu.
- Tag drag and drop persists custom ordering. The color menu offers presets and custom hexadecimal input. Three- and six-digit hex values normalize to `#RRGGBB`; invalid values leave the saved color unchanged.
- These operations change organizational metadata only. Regression fixtures verify that paper identities and protected source-file contents survive collection moves and deletion.

## Window commands

`PaperManagerWindowActions` and `FocusedValues.paperManagerWindowActions` route menu actions to the focused scene. Import uses Command-I. Sidebar and inspector actions are in the View menu. Native outline handling owns unmodified Return, Space, and Delete; these keys are no longer global menu shortcuts while text fields are being edited. Native table Quick Look also uses its own current row rather than a process-wide notification.

Independent native windows provide searchable Chinese Help, a three-step welcome guide, and What's New. The welcome guide opens automatically once per UserDefaults profile, and all three windows can be reopened from Help. These texts describe implemented behavior without copying the original application's Help or presenting unverified Shortcuts registration as an available workflow.

## App Intents

`Intents/MetadataIntents.swift` supplies `PaperEntity`, `TemplateEntity`, string queries, `ExportPaperMetadataIntent`, output modes, and an App Shortcuts declaration. Entities resolve current library data at query time; exporting resolves the selected paper ID again rather than trusting a cached entity's text. TemplateEntity exposes the persisted metadata-template list with stable UUID identities and original names/content. Legacy single-string templates use the model's stable compatibility entity. An absent template parameter renders the active template; an explicitly selected deleted or unknown ID throws instead of silently choosing another template. Return Text and Copy to Clipboard produce the same rendered output, with annotations controlled by the requested flag.

The implementation follows Apple's primary documentation for [AppEntity](https://developer.apple.com/documentation/appintents/appentity), [entity queries](https://developer.apple.com/documentation/appintents/entity-queries), and [AppIntent](https://developer.apple.com/documentation/appintents/appintent).

CLT compilation and direct `perform()` invocation are verified. System Shortcuts registration is **not** verified: the installed Command Line Tools cannot locate `appintentsmetadataprocessor` (`xcrun: unable to find utility`). A normal Xcode build with metadata extraction and a real Shortcuts invocation remain separate platform acceptance checks. No installation or registration was claimed.

## Executed regression evidence

- `scripts/test-editing.sh`: **9 passed, 0 failed**. Covers final-keystroke quit flush, selection changes, stale field bindings, automatic save, concurrent native metadata/read-only attachments, deleted records, type-specific field accessibility, independent identifiers, BibTeX type handling, actual persistence failure across selection changes, and failed-window retention followed by a successful disk retry.
- `scripts/test-sidebar.sh`: **7 passed, 0 failed**. Covers level limits, missing parents, cycles, subtree depth, both reorder directions, persistence, paper/source preservation, tag order and color, and malformed preexisting hierarchy.
- `scripts/test-metadata-intents.sh`: **6 passed, 0 failed**. Covers dynamic paper and template queries, multiple persisted templates, active/explicit selection, deleted template IDs, both output modes, annotation inclusion, direct intent execution, missing IDs, and unreadable-library protection. Clipboard behavior uses an injected sink, so these tests do not replace the user's clipboard.

These source and service checks do not establish interactive fidelity. Final acceptance must exercise the current built app's native drag/drop, pin controls and persistence, two-window command routing, and actual Shortcuts registration.

The complete app source snapshot, including Help scenes, FocusedSceneValue commands, App Intents, current import preview, file-library services, and portable backup services, passed the CLT Swift type checker after these changes. A final bundle build and current UI acceptance remain the root task's integration checks.
