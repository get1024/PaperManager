# Native table accessibility traversal — 2026-10-18

The slow whole-library inspection has an independently reproduced cell-level
cause. An external AX client needed **46.04 seconds** to inspect a synthetic
72-paper library with the original text-cell accessibility descendants. Exposing
one readable static-text value per native text cell, and avoiding redundant
content/style assignments, reduced the measured production-source traversal to
**22.02 seconds**. Every paper, every one of its seven column values, and all 72
rating sliders remained available.

After the production geometry bridge was frozen, a separate correctly sized
1420 × 900 host completed the full scan in **11.89 seconds**, again retaining all
72 × 7 values and 72 sliders. This is a background native host measurement, not a
claim that the final app's complete CUA inspection has passed.

## Method

`scripts/test-native-table-accessibility.sh` freezes production model/service/view
sources in its own temporary build directory. It compiles a native AppKit host
and the separate `Tests/NativeTableAXClient.swift` process. The client uses public
`AXUIElement` calls, reads every advertised attribute and calls
`AXUIElementIsAttributeSettable` for each advertised attribute. It walks children,
navigation-order children, visible children and contents, plus the table's full
`AXRows` and `AXColumns`, deduplicating elements by CFHash/CFEqual. It does not
truncate the library to visible rows.

All 72 synthetic records have distinct title, author, source, note and rating
values. The client verifies those values in their row/column contexts, checks the
year and date cells, and requires exactly 72 accessible rating sliders. No real
library, original Lattice file, or PDF is used. The host stays in the background;
the test does not activate or control another app. The already trusted local AX
client was used without requesting another permission.

The disposable source copy adds counters to `NativeTextCell` initialization,
configuration and content assignment. It does not change production behavior.
The present runner fails if the traversal exceeds 30 seconds, loses any row or
column value, loses a rating slider, or encounters an invalid/cannot-complete AX
element. It removes its own fixture and terminates its own host after the run.

## Controlled measurements

These four runs used the same background-host fixture and 175-point constrained
host variant. The first three compare a frozen source with changes limited to
the text-cell implementation. The fourth checks the accepted production cell
implementation without an experimental source transformation.

| Text cell variant | Seconds | AX nodes | Attribute reads | Settable checks | Verified rows × columns | Rating sliders |
| --- | ---: | ---: | ---: | ---: | --- | ---: |
| Original descendants | 46.044 | 1,676 | 43,831 | 32,097 | 72 × 7 | 72 |
| Static-text cell, hidden decorative descendants | 23.773 | 1,156 | 27,619 | 19,525 | 72 × 7 | 72 |
| Above plus unchanged content/style guards, experimental copy | 19.135 | 1,156 | 27,619 | 19,525 | 72 × 7 | 72 |
| Accepted production cell implementation | 22.022 | 1,156 | 27,619 | 19,525 | 72 × 7 | 72 |

Wall times are individual runs and vary with load. The stable evidence is the
removal of 520 redundant AX nodes and 16,212 attribute reads, with all 504 table
values retained. Compared with the original run, the production run was about
52% faster; it is not an estimate for every machine or every AX client.

The original run initialized only 14 text cells but configured them **306,776**
times. This shows repeated AppKit materialization/reconfiguration, rather than
hundreds of thousands of newly allocated views. The production run made
**135,789** configuration calls but changed content only **883** times. Making
unchanged calls inexpensive matters even after simplifying the AX tree.

The original descendant tree contained 885 static-text and 78 image elements;
the accepted version contained 444 static-text elements and no decorative image
elements. Native row and column wrappers are retained. Rating uses its existing
native slider control and is not replaced with static text.

## Production change

The change is confined to the `NativeCellLabel` / `NativeTextCell` region of
`Sources/PaperManager/Views/NativeLibraryView.swift`:

- A text cell is itself an accessible static-text element. Its `AXValue` joins
  its main label and optional trailing count; this also preserves sidebar counts.
- Its internal rendering labels and image are decorative AX descendants. They
  continue drawing normally.
- Repeated identical `(symbol, text, trailing)` configuration does not rewrite
  labels or invalidate layout.
- The label subclass skips identical font and color assignments requested by
  AppKit while materializing offscreen cells.

The production change does not remove offscreen rows, alter the native table
hierarchy, change selection, or replace the rating control. No geometry/hosting
bridge implementation was changed as part of this cell fix.

## Regression results and remaining boundary

After the cell change, `scripts/test-native-table.sh` passed all **9** native
table checks, including input, focus, lifecycle and 72-row accessibility values.
`scripts/test-inspector-accessibility.sh` also passed its empty-selection AX
snapshot followed by all three selected-inspector snapshots. These checks cover
the separate citekey-label stack overflow documented in
`INSPECTOR_AX_CRASH_FINDINGS.md`.

The four controlled background hosts reported `visibleRect.height == 0` despite
their 175-point scroll/clip bounds. This is an entirely offscreen traversal
stress case. It does **not** establish that exactly a few rows were visible, or
that a 175-point viewport caused the cost. Later geometry candidate measurements
are not mixed into this controlled comparison.

### Final frozen geometry source

The accepted production bridge is the ordinary `NSViewControllerRepresentable`
with the inspector's `sizingOptions = []`. A separate test-harness issue initially
left its outer `NSHostingController` at zero size: assigning a content controller
replaced the initial NSWindow content size. The isolated host now explicitly
sets its requested content size after assigning that controller. This changes
only the test and prevents measuring a zero-size parent. No production geometry
or cell code was changed for the final run.

The final result, `table-ax-final-900.json` / `.log`, was:

| Measurement | Result |
| --- | --- |
| Host / window content size | 1420 × 900 |
| Table scroll and clip bounds | 919 × 900 |
| Visible table height / rows | 900 points / 35 rows |
| Full rows / columns / verified values | 72 / 7 / all 504 |
| Rating sliders | 72 |
| Nodes / attribute reads / settable checks | 1,152 / 27,556 / 19,490 |
| External scan time | 11.892 seconds |
| Text-cell configuration calls / actual content changes | 78,909 / 1,079 |

The remaining 37 offscreen papers are included in the traversal and value
verification. The final source hash for `NativeLibraryView.swift` is
`52f4547820b8e191101f586c93fc7a5a08baa3e6cdede8f4ad388d47e2acee7b`.
The final run is **not** a controlled timing comparison with the older 175-point
hosts because its viewport and bridge differ. Root's complete foreground CUA
workflow remains a separate acceptance check.

With the same final native source and the corrected explicit-size test host,
`scripts/test-inspector-accessibility.sh` passed the empty-selection phase and
all three post-selection external AX phases. Each selected phase read 132 nodes
and 2,379 attributes and found the selectable citekey as native `AXStaticText`.
The log is `inspector-ax-final-frozen.log` in the same evidence directory.

This client exercises the public external AX attribute and writability paths
seen in the slow app sample. It is not a reimplementation of CUA's entire
inspection protocol, and an 11.89-second result does not guarantee every CUA call
finishes within its timeout.

## Reproduction and retained evidence

```sh
PAPERMANAGER_AX_TABLE_HEIGHT=175 \
PAPERMANAGER_AX_RESULT_JSON="$PWD/.build/table-ax-result.json" \
  scripts/test-native-table-accessibility.sh
```

Omit `PAPERMANAGER_AX_TABLE_HEIGHT` to reproduce the final natural 900-point
viewport. The runner uses the installed Command Line Tools SDK; it does not change global
developer settings. `PAPERMANAGER_TEST_SDK` can select another installed SDK.
`PAPERMANAGER_AX_NATIVE_SOURCE` can select an explicitly frozen native-view source
for comparison. No performance source patch is applied by the current runner.

Raw measured results and logs are in `.build/audit-20261018/`:
`table-ax-baseline-175`, `table-ax-flat-175`, `table-ax-cached-175`, and
`table-ax-production-175` (`.json` and `.log` each). The historical original cell
source is `NativeLibrary.performance-baseline.swift` in that directory. A compact
durable copy of the measured counts is `NATIVE_TABLE_AX_MEASUREMENTS.json` beside
this report. Follow-up test logs are
`native-table-after-ax-cell.log` and `inspector-ax-after-text-cell.log`.
