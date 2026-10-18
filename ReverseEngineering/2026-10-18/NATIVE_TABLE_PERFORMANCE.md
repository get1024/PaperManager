# Native table and AX performance repair

## Runtime evidence

The existing running PaperManager process (PID 54632) became expensive to inspect through accessibility. The captured sample at `.build/qa-2026-10-18/papermanager-unresponsive.sample.txt`, timestamp 2026-10-18 17:03:43, contains this main-thread path:

`NSTableViewCellMockElement accessibilityDescriptionAttribute` → `viewAtColumn:row:makeIfNecessary:` → `NativePaperTableController.outlineView(viewFor:)` → `NativeRatingCell.init` → `NSButton(image:target:action:)` → `NSControl sizeToFit` → `NSButtonCell cellSizeForBounds` → SwiftUI `ViewGraphRootValueUpdater._sizeThatFits`.

The old delegate created every cell from scratch, including five image buttons and a stack for each rating. Accessibility descriptions can materialize offscreen rows. Both sidebar and paper controller also rebuilt item identities and called `reloadData()` on every SwiftUI configuration update, including selection/status/focus-only updates. Together these paths amplified expensive macOS 27 button sizing. The sample demonstrates repeated expensive work; it does not by itself prove an infinite algorithmic loop.

## Change

- Rating uses one custom `NSControl`, with five vector-drawn stars, direct hit testing, same-star clearing, keyboard input, and a single labeled AX slider supporting value/increment/decrement. It creates no `NSButton`, `NSStackView`, hosting view, or per-star constraints.
- Text and rating cells are `NSTableCellView` instances with reusable identifiers retrieved through `makeView(withIdentifier:owner:)`. Text layout uses fixed frames, with cached symbol images.
- Paper and attachment node identities survive nonstructural updates. Changed metadata reloads affected rows; unchanged, selection, focus, and status configurations do not reload data. Insertions/removals/order or attachment-identity changes retain the full reload path and restore expanded parents.
- Sidebar preserves its existing nodes when titles/counts/colors/hierarchy are unchanged, and changes native selection only when needed.
- Smoke-only reload counters compile under `NATIVE_TABLE_SMOKE`; production builds do not include these counters.

## Executed native smoke

`scripts/test-native-table.sh` compiles an isolated source snapshot and creates an actual hidden AppKit window/controller with 72 synthetic papers. No CUA, real library, visible app activation, original source files, or external accessibility permission change is involved.

The focused performance smoke passed its four checks. Measured first run:

- 100 unchanged configurations: **0 full or row reloads**, **0.038 seconds**; the original native cell remains identical.
- A metadata edit: affected-row reload only. External paper selection reaches the expected row without a content reload.
- Eight traversals covering **4,032 native AX cell descriptions**, including offscreen rows: **0.180 seconds**, with no full reload. The test deliberately invokes the legacy AX description/value entry points implicated in the runtime sample. It uses the untyped rows entry point because the macOS 27 private `NSOutlineRow` objects do not satisfy the SDK's typed `NSAccessibilityRow` array bridge.
- Rating draws natively and supports persisted mouse, keyboard, AX increment/value changes and same-star clearing, with no button descendants.

The AX smoke exercises AppKit's in-process objects and description materialization. The root task still needs to rebuild the current app and verify its cross-process CUA/VoiceOver inspection and visible window behavior; these measurements do not claim that acceptance was already performed.

## SwiftUI hosting height

The root task's real WindowGroup screenshots and geometry captures exposed a separate controller-bridge defect. In `/private/tmp/PaperManagerAcceptance-20261018/geometry.json`, the controller root NSView fills 1420×808, but its internal NSSplitView and all three panes remain 1420×175 three seconds after appearance. Bounds origins are zero. Basic NSHostingController fixtures did not reproduce that scene behavior and were not sufficient acceptance evidence.

Real follow-up captures (`geometry-fixed.json`, `geometry-final.json`, `geometry-latest.json`) showed that load-time pinning, later active required edge constraints, and a one-time layout/frame repair did not stick. A direct-split NSViewRepresentable made the split fill the window but left its panes at 175pt. Those intermediate workarounds were removed.

The actual cause was recovered with the new **true SwiftUI App/WindowGroup** subprocess fixture, rather than an NSHostingController-only fixture. `constraintsAffectingLayout(for: .vertical)` showed `NSHostingView.maxHeight ... height <= 175 priority:999.9` on the empty inspector. NSSplitView's native top/bottom constraints connect that hosting view to every sibling pane. The hosting view's sizing constraint could therefore compress the entire managed split. The negative capture is `.build/qa-2026-10-18/window-group-fixture/geometry-max-height-negative.json`.

The final fix sets the embedded inspector's `NSHostingController.sizingOptions = []`: the NSSplitViewItem now determines its geometry, without intrinsic/minimum/maximum constraints exported by changing SwiftUI content. The bridge remains **NSViewControllerRepresentable**, preserves NSSplitViewController's original root hierarchy and normal controller containment, and returns finite proposed sizes. There are no custom split subclasses, late pinning, size observers, manual pane frames, adjustSubviews calls or frame-repair loops. The inspector also receives the selected app language explicitly across its new hosting boundary.

`scripts/test-native-window-group.sh` creates an actual `@main App`/`WindowGroup` with the production toolbar/frame/chrome modifier ordering and an isolated 72-paper library. Nine runtime stages passed: initial full window, smaller/larger resize, four sidebar/inspector collapse/reopen configurations, paper selection, and clearing the selection. Every visible native pane has the same height as its split and the window content area. Reports with PID/timestamp are retained at `.build/qa-2026-10-18/window-group-fixture/report.json` and `geometry.json`. This fixture does not activate or inspect the user's applications.

An executed same-source negative control, `PAPERMANAGER_GEOMETRY_NEGATIVE_CONTROL=1 scripts/test-native-window-group.sh`, removes only the inspector sizing fix from the temporary source copy. It exits 1 with six geometry failures: the split again stays at 175pt at the initial 808pt content height, the two resized windows, visible inspector configurations and after clearing the selection. Its separate report directory is `window-group-fixture-negative`. This proves the regression catches the actual hosting-size constraint independently of the discarded bridge experiments.

`scripts/test-native-table.sh` also passes its eight behavior groups: unchanged configurations cause no reload, affected-row reload/external selection, AX materialization, persisted star input, three hosted sizes, pane collapse/reopen, native Coordinator ownership and durable draft flushing on dismantle, and two-way selection/focused-window search routing. A rebuild and visual check of the full product remain the parent task's separate acceptance step.

## Opt-in real-scene diagnostics

Explicitly set `PAPERMANAGER_GEOMETRY_LOG_PATH` to an absolute local JSON path when launching a diagnostic build. The recorder is disabled otherwise. It takes at most 32 coalesced snapshots during configuration/layout/attachment and shortly after attachment, including window/content geometry, native and split ancestors, bounds origins, visible rectangles, safe areas, autoresizing settings, arranged panes, nested scroll/table geometry, layout ambiguity and vertical constraints. It reads no paper text or file paths, changes no frames or preferences, and sends nothing over the network.
