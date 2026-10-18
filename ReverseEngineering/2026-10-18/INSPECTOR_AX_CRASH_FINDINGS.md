# Selected inspector accessibility crash — 2026-10-18

## Confirmed failure and historical reports

Reading accessibility after selecting `vaswani2017` crashed PaperManager with
SIGSEGV / stack overflow. The 17:26 report contains 67,378 original frames and
5,613 repetitions of the same accessibility entry cycle:

```
AccessibilityNode.accessibilityLabel()
→ SwiftUI's platform attribute override callback
→ _NSAccessibilityOverrideValueForAttribute
→ _NSAccessibilityEntryPointValueForAttribute
→ PlatformAccessibilityElementProtocol.valueForAttribute
→ AccessibilityNode.accessibilityLabel()
```

Both earlier exits on October 13 (13:02 and 13:07), and the October 18 16:01
exit, contain the same cycle, with approximately 67,370–67,379 frames and
5,612–5,613 repetitions. They were not ordinary quit events. Compact summaries
without library content are saved in `INSPECTOR_AX_CRASH_SUMMARY.json`.
The reports establish the shared stack; they do not identify the precise
historical UI node from those older binaries.

## Reproduction that distinguishes the actual trigger

`Tests/InspectorAccessibilitySmoke.swift` hosts the real `NativeLibraryView`
inside a real AppKit `NSWindow` / `NSHostingController`. A separate native process,
`InspectorAXClient.swift`, reads every advertised AX attribute through
`AXUIElementCopyAttributeValue` and traverses the accessible hierarchy. The test
window stays behind normal application windows and does not activate the app.

The required sequence is:

1. Begin with no selected paper and read the complete AX hierarchy, activating
   SwiftUI's accessibility bridge.
2. Select the paper and update the hosting root, matching the production
   `NativeLibraryController.configure` lifecycle.
3. Read the rebuilt inspector through the external AX client.

Reading a statically selected inspector before AX had previously been active
did **not** reproduce the issue. In-process legacy getters also missed the
SwiftUI virtual nodes and were insufficient verification.

The complete sequence crashed the isolated host at an `AXStaticText` node whose
`AXValue` was `vaswani2017`, when the client requested `AXDescription`. The new
host report, `InspectorAccessibilitySmoke-2026-10-18-173426.ips`, has the same
label/override cycle (67,292 frames, depth 5,606). A completely synthetic paper
also reproduces it, so real library files are unnecessary for the regression.
Probe report summaries are in `INSPECTOR_AX_REPRO_CRASH_SUMMARY.json`.

## Minimal fix and causal controls

The offending expression in `PaperDetailView.header` was:

```swift
Text(paper.citekey)
    .textSelection(.enabled)
    .accessibilityLabel("引用键")
```

The application-level trigger is the custom SwiftUI accessibility label on
selectable text after an AX-active inspector rebuild. The stack demonstrates
that the label override calls back through the platform accessibility attribute
resolver until the stack is exhausted. The exact private implementation inside
SwiftUI/AppKit is not available as source and is not claimed here.

The fix removes only `.accessibilityLabel("引用键")`. It retains text selection,
the native `AXStaticText` role and citation-key value, the help text and existing
visual layout. The remaining native AX value is still `vaswani2017`.

Causal controls used exact frozen source copies:

| Experiment | Result |
| --- | --- |
| Original label, AX activated before selection, synthetic paper | Host crashed on the citekey's `AXDescription`. |
| Original label, same sequence, copied owned metadata | Same host crash and stack. |
| Add a named containing AX group at the inspector root, retain the citekey label | Still crashed at the citekey. |
| Remove only the citekey label, unchanged hosting replacement and identifiers | Complete synthetic and copied-metadata hierarchies passed. |
| Restore the old label only in a disposable copy of the repaired source | Synthetic host crashed again at phase 1, node 54, `AXStaticText` / `AXDescription`; client returned exit 5. |

Replacing the entire inspector hosting bridge or removing its identifiers is
not required by the observed defect. Settings' hosting bridge is not implicated
by this controlled result.

## Persistent regression and results

Run the native cross-process integration regression:

```sh
scripts/test-inspector-accessibility.sh
```

It uses synthetic metadata, activates AX on an empty inspector, selects the
paper, and reads the rebuilt selected hierarchy three times. It requires the
logged-in macOS GUI session and an already authorized accessibility client;
it does not request new permission. Fixture files live under the runner's own
temporary build directory and are cleaned even if the host crashes.

The no-patch repaired runs completed:

- Synthetic fixture: unselected **114 nodes / 1,925 attribute reads**;
  selected **158 / 2,879**, repeated successfully for all three subsequent
  snapshots (phase 1, 2 and 3). The citekey remains selectable `AXStaticText`.
- Owned metadata copied from the independent acceptance library: unselected
  **300 / 5,379**; selected **361 / 6,630**. Attachment paths/bookmarks were
  replaced with synthetic files inside the fixture; original PDFs were not read.
- Reinstating only the old label in the disposable source copy reproduced the
  failure, confirming that the passing regression is sensitive to the defect.

The optional negative control is:

```sh
PAPERMANAGER_AX_SOURCE_PATCH=restore-citekey-label scripts/test-inspector-accessibility.sh
```

It is expected to fail and crash only its isolated test host. Logs are under
`.build/audit-20261018/inspector-ax-*.log`. The parent task performs the separate
final CUA verification of the packaged application; this report does not
substitute the integration fixture for that workflow check.
