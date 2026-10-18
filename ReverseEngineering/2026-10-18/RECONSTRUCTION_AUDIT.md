# Reconstruction integrity review — 2026-10-18

Scope: `ImportService`, `ImportPreviewView`, `AddPaperSheets`, `ContentView`,
`PortableBackupService`, `BackupService`, their `LibraryStore` / `FileLibraryService`
boundaries, Lattice's fifteen paper types, and template standard-key preservation.
This is a source and synthetic-fixture review, not a claim of complete original-app
equivalence or completed UI verification. No original Lattice data, real Zotero
database, system Trash, or external network service was changed by these fixtures.

The original failing frozen-source reproducer is
`.build/audit-20261018/ReconstructionRepro.swift`; its captured output is
`.build/audit-20261018/result.log`. Durable regressions live in
`Tests/ImportBackupTests.swift`, run by `scripts/test-import-backup.sh`. The runner
copies model/service sources before compilation, avoiding inconsistent builds
when other reconstruction work continues. It uses temporary libraries and ZIP
archives; deletion tests inject a fake Trash function.

Final completed runs: **ImportBackup 27 passed / 0 failed**, **Zotero 14 / 0**,
and **LatticeArchive 14 / 0**. Logs are
`.build/audit-20261018/import-backup-regressions.log`,
`.build/tools/zotero-import-tests.log`, and
`.build/audit-20261018/lattice-archive-regressions.log`.

A subsequent real accessibility traversal exposed a separate inspector stack
overflow which the earlier static/service tests did not cover. It is now
reproduced and fixed with a native cross-process AX regression; the exact trigger,
negative control and historical crash comparison are documented in
`INSPECTOR_AX_CRASH_FINDINGS.md`.

A separate full-table external AX regression confirmed excessive decorative-cell
traversal and repeated configuration. The accepted cell repair reduced a
synthetic 72-paper traversal from 46.04 to 22.02 seconds while retaining all
72 × 7 column values and 72 rating sliders. Its controlled measurements,
background-host limitations, subsequent 11.89-second final 900-point-host run,
and pending final whole-app verification are in
`NATIVE_TABLE_AX_PERFORMANCE.md`.

## Confirmed findings repaired and covered

| Priority | Trigger and previous result | Current repair and regression |
| --- | --- | --- |
| P1 | Repeating the same `Paper.id` twice in one prepared batch inserted two rows with one UUID. Frozen reproducer: `same_uuid_imported=2,rows=2,unique_ids=1`. | `ImportService.commit` first resolves `store.paper(with: incoming.id)`, then metadata duplicates. `testBatchIdentity` tests both a repeated batch item and replaying the whole plan. **Resolved; verified.** |
| P1 | Replacing a duplicate from a PDF with automatic annotation extraction enabled retained the old primary PDF, then re-extracted it and erased hand-maintained annotations. Reproducer: `replaced=1,primary=old.pdf,annotations_after=0`. | Replacement skips automatic annotation refresh. New-import refresh also checks the current primary attachment and unchanged annotation baseline after its await. `testReplacementAnnotations` verifies identity, manual annotations and source bytes. **Resolved; verified.** The asynchronous edit race guard was source-reviewed; no deterministic suspended-worker hook exists in this test suite. |
| P1 | A manifest member `files/*` invoked `unzip -p` glob matching. Files `A` and `B` were concatenated and accepted with the digest of `AB`. Reproducer: `glob_accepted=true,payload=AB`. | Manifest accepts only the exact paper UUID / role / item UUID filename with a short alphanumeric extension, before extraction. `testArchiveWildcard` uses the previously accepted combined checksum. **Resolved; verified.** |
| P1 | Metadata-only archives accepted repeated collection/attachment UUIDs. Reproducer: `duplicate_ids_accepted=true,collections=2,unique_collection_ids=1,attachments=2`. | Shared snapshot validation rejects repeated paper/collection/tag/template IDs, repeated per-paper attachment/annotation/custom-field IDs, dangling memberships/parents, collection cycles, depth above three and future snapshot schemas. `testArchiveIdentities` applies thirteen invalid variants to both portable and legacy JSON formats. **Resolved; verified.** |
| P1 | Deleting one record could Trash a PDF referenced by a surviving record, including a symlink alias; deleting a batch could handle one path repeatedly. | `LibraryStore.deletePapers` computes canonical retained/read-only protected paths and deduplicates actions. `testSharedDeletion` injects fake Trash and verifies shared aliases, read-only references and repeated attachment paths. **Resolved; verified without actual Trash use.** |
| P2 | A collection or tag deleted after preview preparation could become a dangling imported membership and hide the paper from Unfiled/No Tags. | `LibraryStore.apply(targetFilter:)` checks current entity existence; commit adds a recoverable message. `testDeletedTarget` deletes both targets between prepare and commit, then checks smart-filter membership. **Resolved; verified.** |
| P2 | The selected sidebar filter could change during asynchronous file preparation, changing the eventual preview's target collection. | `ContentView.importURLs` now captures `importTargetFilter = selectedFilter` before starting preparation, and passes the captured value to the sheet. **Resolved by source inspection; no live multiwindow UI claim.** |
| P2 | Lattice `inCollection` imported `container-title` only into journal, losing the chapter's `bookTitle`. Reproducer: `lattice_inCollection_journal=Edited Volume,bookTitle=`. | `.inCollection` joins `.inBook` and `.inProceedings` in the chapter container mapping. `testLatticeTypes` verifies every one of the fifteen raw types and all three chapter container cases. **Resolved; verified.** |
| P2 | An arbitrary custom field named `title`, `doi` or `pdfURL` could replace a standard template context value, including an intentionally empty value. | `TemplateRenderer.context` adds custom keys only when a standard key is absent. `testTemplateKeys` checks rendered values and an independent user extension. **Resolved; verified.** |

## Additional findings repaired during review

### P1 — Equal file counts do not prove exact manifest coverage

`PortableBackupService.read`, originally lines 106–109 and 127–128, checks total
record count and whether an annotation ID exists. A snapshot can declare image A
on annotation A, plus a second annotation B without an image. A correctly named,
correctly checksummed image record for B substitutes for A while retaining the
expected total count. Restore accepts it, leaves A pointing at the old machine's
image path, and assigns unrelated bytes to B.

**Confirmed before repair:** `testArchiveCoverage` failed with “Equal record count hid a missing
image and redirected bytes to an annotation without an image.” The malformed
archive was created entirely in the fixture directory. Repair by comparing the
exact expected `(paperID, itemID, role)` set to the manifest's set whenever
`includesFiles` is true, rather than only their cardinality. Metadata-only archives
must continue to contain no file records. **Resolved and verified:** the latest
reader compares `declaredItemKeys == expectedItemKeys`; the exact fixture now
passes.

### P1 — Persistence errors can be counted as successful imports

`LibraryStore.addPaper` mutates the in-memory array then calls the nonthrowing
`save`; `ImportService.commit` subsequently increments success and replaces the
error status with its successful summary. A regular file used as the prospective
library parent deterministically prevents persistence, even under a privileged
test user. The import needs a throwing durable commit/rollback boundary so a
metadata-only import is not acknowledged before its snapshot is saved.

`testImportPersistenceFailure` uses that temporary blocking-file fixture and
checks failed count, no inserted in-memory row, and preserved blocking bytes.
**Confirmed:** observed `imported=1, failed=0, in-memory rows=1, status=已导入 1`.
**Resolved; verified:** `ImportService.commit` now uses throwing durable paper
insertion/update APIs. `testImportPersistenceFailure` verifies a real failed write
is counted as failure and leaves memory/other bytes unchanged. PDF attachment
placement retains its own receipt rollback; a failed attachment reverses only its
own metadata row, rather than restoring a stale whole-library snapshot.

### P2 — Legacy JSON bypasses the portable snapshot integrity validator

`BackupService.readBackup`'s non-ZIP branch decodes and returns a snapshot without
the validation applied to portable v2 archives. Duplicate entity IDs and broken
memberships/collection parents can therefore enter the same restore path through
the older supported format. The collection traversal helpers have cycle guards;
this review does **not** claim an observed crash. The confirmed concern is
inconsistent identity and relationship integrity across supported formats.
**Resolved; verified:** `BackupService` calls the shared
`PortableBackupService.validateSnapshot`; `testArchiveIdentities` applies the same
invalid variants to both formats. Valid legacy JSON remains readable.

### P1 — Restore preparation can race with edits in another window

Source-level interleaving: `SettingsView.restoreBackup` captures `previous` before
awaiting background backup/extraction, then replaces the shared store afterward.
Another window can edit the library during that await. Those changes are absent
both from the captured BeforeRestore backup and the replacement. `store.isBusy`
currently disables some controls, not every editor/mutation entry point. The
Lattice archive preparation path has the same asynchronous replacement boundary.
**Resolved:** both Settings restore paths capture a lossless snapshot token before
background preparation and supply it at the final durable commit. Both flush
drafts before and after preparation, stop on a failed flush, and remove only the
new restoration UUID directory if preparation/commit fails. The store's stale
revision guard is covered by `testRestoreRevision`, including preservation of the
other window's persisted notes. A real two-window UI race was not induced.

### Persistence failure boundary shared by snapshot restorers

These paths previously used nonthrowing `replaceSnapshot` and verified the saved
file afterward. **Resolved:** Settings' backup restore,
`LatticeArchiveService.persist`, `ZoteroImportService.persist`,
`LatticeImportService.merge`, and template CRUD now use throwing durable writes.
The store commits published state only after the atomic disk write succeeds.
`testDurableFailure` checks failed paper update, snapshot replacement and template
mutation with a real directory blocking the file target. `testUnreadableRecovery`
checks ordinary mutations cannot overwrite an unreadable library and an explicit
recovery first preserves its exact bytes. Zotero's fourteenth check confirms
failure leaves the current library and unrelated sentinel intact and removes
only its new provenance directory. Lattice provenance keeps historical source
records and restores the latest projection on a failed commit.

Durable interfaces in `LibraryStore.swift`:

```swift
try store.performDurableMutation { (snapshot: inout LibrarySnapshot) in /* edit copy */ }
try store.addPaperDurably(paper, targetFilter: filter)
try store.updatePaperDurably(paper, targetFilter: filter)
let revision = try store.snapshotRevisionToken()
try store.replaceSnapshotDurably(snapshot, expectedRevision: revision)
```

### Bookmark protection review correction

An initial suspicion treated `Attachment.url` as a literal `filePath`. Inspection
confirmed it already resolves its bookmark, so this was **not an original
protection bug**. The new `resolvedCanonicalURL(for:)` makes the common comparison
explicit. `testResolvedProtection` creates and moves only its own temporary file,
then checks both read-only and shared-bookmark rename protection and attachment
move refusal. The test compares canonical paths because macOS `/var` and
`/private/var` aliases differ textually.

## Reviewed behavior and boundaries

- Preparation/deselection, duplicate replacement, batch duplicate detection,
  invalid PDF rejection, portable attachment/image round trip, metadata-only
  ownership, checksum cleanup, traversal rejection, file count/flag validation,
  legacy JSON readability, future-version rejection and unsafe destination
  rejection have persistent tests in the same runner.
- The reviewed file-placement path uses no-overwrite creation and exclusive
  rename, source/destination identity receipts and rollback; the previous
  copy-overwrite concern does not apply to the current implementation.
- File placement cancellation is confirmed before the first placement, so that
  early return does not abandon receipts from earlier operations in the same run.
- Portable v2 snapshots now use deferred date encoding to preserve fractional
  timestamps. The separate legacy JSON format intentionally retains its existing
  ISO-8601 representation. The timestamp issue was already known to the parent
  reviewer and is not counted as an independent finding here.
- This review does not claim protected original-source recovery. Native REA
  evidence and its Swift ABI limits are documented separately in
  `NATIVE_ANALYSIS_PLAN.md`; Zotero migration coverage is in
  `ZOTERO_IMPORT_FINDINGS.md`.
