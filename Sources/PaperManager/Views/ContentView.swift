 import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @EnvironmentObject private var store: LibraryStore
    @EnvironmentObject private var localAPI: LocalAPIServer
    @Environment(\.openWindow) private var openWindow
    var prepareImport: @MainActor ([URL], LibraryStore) async -> ImportPlan = { urls, store in
        await ImportService.prepare(urls, store: store)
    }

    @State private var selectedFilter: LibraryFilter = .all
    @State private var selectedPaperIDs: Set<UUID> = []
    @State private var searchText = ""
    @State private var showImporter = false
    @State private var showManualAdd = false
    @State private var showDOIAdd = false
    @State private var showWelcomeGuide = false
    @State private var pendingGuideImport = false
    @State private var showWhatsNew = false
    @AppStorage("PaperManager.hasShownWelcome") private var hasShownWelcome = false
    @State private var includeSubcollections = true
    @State private var showSidebar = true
    @State private var showInspector = true
    @AppStorage("PaperManager.Table.sortField") private var savedSortField = PaperSortField.year.rawValue
    @AppStorage("PaperManager.Table.sortAscending") private var savedSortAscending = true
    @State private var sortDescriptor = PaperSortDescriptor(field: .year, ascending: true)
    @State private var focusSearchToken = 0
    @State private var showAddPopover = false
    @State private var showExportPopover = false
    @State private var pendingOpenPaperID: UUID?
    @State private var importPlan: ImportPlan?
    @State private var importTargetFilter: LibraryFilter?
    @State private var isPreparingImport = false
    @State private var importSourceKind: String?
    @StateObject private var selectionCommands = NativePaperSelectionCommands()
    @StateObject private var libraryWindow = PaperManagerLibraryWindowContext()

    private var visiblePapers: [Paper] {
        store.filteredPapers(
            for: selectedFilter,
            searchText: searchText,
            includeSubcollections: includeSubcollections,
            sortDescriptor: sortDescriptor
        )
    }

    private var targetPapers: [Paper] {
        let selected = visiblePapers.filter { selectedPaperIDs.contains($0.id) }
        return selected.isEmpty ? visiblePapers : selected
    }

    private var selectedTitle: String {
        switch selectedFilter {
        case .collection(let id):
            return store.collections.first { $0.id == id }?.name ?? selectedFilter.title
        case .tag(let id):
            return store.tags.first { $0.id == id }?.name ?? selectedFilter.title
        default:
            return selectedFilter.title
        }
    }

    private var libraryView: some View {
        NativeLibraryView(
            store: store,
            papers: visiblePapers,
            selectedFilter: $selectedFilter,
            selection: $selectedPaperIDs,
            searchText: $searchText,
            includeSubcollections: $includeSubcollections,
            sortDescriptor: $sortDescriptor,
            showSidebar: showSidebar,
            showInspector: showInspector,
            focusSearchToken: focusSearchToken,
            onOpenSelected: openSelectedPDF,
            onRevealSelected: revealSelectedPDF,
            onDeleteSelected: deleteSelectedPapers,
            onImportURLs: importURLs,
            onRefreshMetadata: refreshMetadataForTargets,
            onExportBibTeX: exportBibTeX,
            onExportRIS: exportRIS,
            onExportDetailed: exportDetailed,
            onToggleSidebar: { showSidebar.toggle() },
            onPanelVisibilityChanged: { sidebar, inspector in
                showSidebar = sidebar
                showInspector = inspector
            },
            selectionCommands: selectionCommands
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // Let native pane materials continue behind the unified toolbar. Each
        // pane keeps its controls inside the window's content safe area.
        .ignoresSafeArea(.container, edges: .top)
        .font(PMTypography.bodyRegular)
        .background(WindowChromeConfigurator { window in
            if libraryWindow.attach(to: window) { requestFileImport() }
            window.titleVisibility = .visible
            window.titlebarAppearsTransparent = true
            window.toolbarStyle = .unified
            window.styleMask.insert(.fullSizeContentView)
            // Full-size content contains many editable/selectable native views. Let the
            // titlebar own window dragging; background dragging otherwise makes AppKit
            // recalculate opaque drag regions for every accessibility/layout update.
            window.isMovableByWindowBackground = false
            window.contentMinSize = NSSize(width: 1080, height: 680)
        })
        .preferredColorScheme(store.settings.appearance.preferredColorScheme)
        .environment(\.locale, PMLocalization.locale(for: store.settings.languageIdentifier))
        .navigationTitle(selectedTitle)
        .focusedSceneValue(\.paperManagerWindowActions, windowActions)
        .toolbar(removing: .sidebarToggle)
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button { showAddPopover.toggle() } label: {
                    Label("添加", systemImage: "plus")
                }
                .labelStyle(.iconOnly)
                .accessibilityIdentifier("main-toolbar-add")
                .disabled(isPreparingImport)
                .popover(isPresented: $showAddPopover, arrowEdge: .bottom) {
                    VStack(alignment: .leading, spacing: 12) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("添加文献").font(.headline)
                            Text("导入文件或通过元数据创建文献。")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Divider()
                        addAction("导入文件…", subtitle: "支持 PDF、BibTeX、RIS 或文件夹", icon: "doc.text", action: requestFileImport)
                        .disabled(!canPresentFileImporter)
                        .padding(.top, 3)
                        addAction("通过 DOI 添加…", subtitle: "支持 DOI、arXiv、ISBN 或标题", icon: "magnifyingglass") {
                            showDOIAdd = true
                        }
                        addAction("手动添加…", subtitle: "通过输入元数据创建文献", icon: "square.and.pencil") {
                            showManualAdd = true
                        }
                    }
                    .padding(12)
                    .frame(width: 300)
                }

                Button { showExportPopover.toggle() } label: {
                    Label("导出", systemImage: "square.and.arrow.up")
                }
                .labelStyle(.iconOnly)
                .accessibilityIdentifier("main-toolbar-export")
                .popover(isPresented: $showExportPopover, arrowEdge: .bottom) {
                    VStack(alignment: .leading, spacing: 12) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(PMLocalization.text("导出")).font(.headline)
                            Text(PMLocalization.text("为当前文献选择导出格式。"))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Divider()
                        exportAction("导出 BibTeX…", subtitle: "将文献保存为 .bib 文件", icon: "curlybraces", action: exportBibTeX)
                            .padding(.top, 3)
                        exportAction("导出 RIS…", subtitle: "将文献保存为 .ris 文件", icon: "list.bullet.rectangle", action: exportRIS)
                        exportAction("详细导出…", subtitle: "将元数据和标注渲染为 Markdown", icon: "doc.richtext", action: exportDetailed)
                    }
                    .padding(12)
                    .frame(width: 300)
                }

                Button { showInspector.toggle() } label: {
                    Label("切换检查器", systemImage: "sidebar.right")
                }
                .labelStyle(.iconOnly)
                .help(PMLocalization.text(showInspector ? "隐藏论文检查器" : "显示论文检查器"))
                .accessibilityIdentifier("main-toolbar-toggle-inspector")
            }
        }
    }

    var body: some View {
        libraryView
        .fileImporter(
            isPresented: $showImporter,
            allowedContentTypes: [.pdf, .bibTeX, .ris, .folder],
            allowsMultipleSelection: true
        ) { result in
            if case .success(let urls) = result {
                importURLs(urls)
            }
        }
        .sheet(isPresented: $showManualAdd) {
            ManualPaperSheet(targetFilter: selectedFilter, onOpenExisting: focusPaper)
                .environmentObject(store)
        }
        .sheet(item: $importPlan) { plan in
            ImportPreviewView(plan: plan, targetFilter: importTargetFilter, onOpenExisting: focusPaper, sourceKind: importSourceKind)
                .environmentObject(store)
        }
        .sheet(isPresented: $showDOIAdd) {
            DOISheet(targetFilter: selectedFilter, onOpenExisting: focusPaper)
                .environmentObject(store)
        }
        .sheet(isPresented: $showWelcomeGuide, onDismiss: {
            if pendingGuideImport { pendingGuideImport = false; requestFileImport() }
        }) {
            PaperManagerWelcomeView(onImportFirst: {
                pendingGuideImport = true
                showWelcomeGuide = false
            }, onClose: { showWelcomeGuide = false })
            .environmentObject(store)
        }
        .sheet(isPresented: $showWhatsNew) {
            PaperManagerWhatsNewView(onOpenIntegrations: { showSettingsPane("localAPI") },
                                    onOpenFileLayout: { showSettingsPane("general") },
                                    onClose: { showWhatsNew = false })
        }
        .onAppear {
            SettingsWindowCoordinator.shared.configure(store: store, localAPI: localAPI,
                onOpenHelp: { openWindow(id: PaperManagerAuxiliaryWindow.help) })
            if !hasShownWelcome { hasShownWelcome = true; showWelcomeGuide = true }
            localAPI.reconfigure(with: store)
            showInspector = store.settings.showInspectorByDefault
            sortDescriptor = PaperSortDescriptor(field: PaperSortField(rawValue: savedSortField) ?? .year,
                                                 ascending: savedSortAscending)
        }
        .onChange(of: sortDescriptor) { _, value in
            savedSortField = value.field.rawValue
            savedSortAscending = value.ascending
        }
        .onChange(of: selectedFilter) { _, _ in
            if let id = pendingOpenPaperID {
                selectedPaperIDs = [id]
                pendingOpenPaperID = nil
            } else {
                selectedPaperIDs.removeAll()
            }
        }
        .onOpenURL(perform: openPaperURL)
        .onChange(of: visiblePapers.map(\.id)) { _, ids in
            selectedPaperIDs.formIntersection(Set(ids))
        }
        .onChange(of: store.collections.map(\.id)) { _, ids in
            if case .collection(let id) = selectedFilter, !ids.contains(id) { selectedFilter = .all }
        }
        .onChange(of: store.tags.map(\.id)) { _, ids in
            if case .tag(let id) = selectedFilter, !ids.contains(id) { selectedFilter = .all }
        }
        .onChange(of: store.settings) { _, _ in
            localAPI.reconfigure(with: store)
        }
        .onChange(of: store.settings.showInspectorByDefault) { _, _ in
            showInspector = store.settings.showInspectorByDefault
        }
        .onReceive(NotificationCenter.default.publisher(for: .paperManagerImportRequested)) { notification in
            guard libraryWindow.acceptsImportRequest(target: notification.object) else { return }
            requestFileImport()
        }
    }

    private var windowActions: PaperManagerWindowActions {
        PaperManagerWindowActions(
            importFiles: requestFileImport, importLattice: importFromLattice, addIdentifier: { showDOIAdd = true },
            addManually: { showManualAdd = true }, focusSearch: { focusSearchToken += 1 },
            openSelected: { if !selectionCommands.perform(.open) { openSelectedPDF() } },
            quickLook: { if !selectionCommands.perform(.quickLook) { quickLookSelectedPDF() } },
            revealSelected: { if !selectionCommands.perform(.reveal) { revealSelectedPDF() } },
            deleteSelected: { if !selectionCommands.perform(.delete) { deleteSelectedPapers() } },
            exportBibTeX: exportBibTeX, toggleSidebar: { showSidebar.toggle() },
            toggleInspector: { showInspector.toggle() }, hasSelection: !selectedPaperIDs.isEmpty,
            sidebarVisible: showSidebar, inspectorVisible: showInspector,
            showWelcome: { showWelcomeGuide = true }, showWhatsNew: { showWhatsNew = true },
            canExport: !targetPapers.isEmpty, canImportFiles: canPresentFileImporter
        )
    }

    private func openPaperURL(_ url: URL) {
        guard url.scheme == "papermanager", url.host == "paper",
              let id = UUID(uuidString: url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))),
              store.paper(with: id) != nil else { return }
        focusPaper(id)
    }

    private func showSettingsPane(_ pane: String) {
        showWhatsNew = false
        SettingsWindowCoordinator.shared.configure(store: store, localAPI: localAPI,
            onOpenHelp: { openWindow(id: PaperManagerAuxiliaryWindow.help) })
        SettingsWindowCoordinator.shared.show(pane: pane)
    }

    private var selectedPapers: [Paper] {
        visiblePapers.filter { selectedPaperIDs.contains($0.id) }
    }

    private func addAction(_ title: String, subtitle: String, icon: String, action: @escaping () -> Void) -> some View {
        Button {
            showAddPopover = false
            action()
        } label: {
            HStack(spacing: 8) {
                Image(systemName: icon).font(.system(size: 14)).frame(width: 24)
                VStack(alignment: .leading, spacing: 2) {
                    Text(PMLocalization.text(title)).font(.system(size: 13, weight: .semibold))
                    Text(PMLocalization.text(subtitle)).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func exportAction(_ title: String, subtitle: String, icon: String, action: @escaping () -> Void) -> some View {
        Button {
            showExportPopover = false
            action()
        } label: {
            HStack(spacing: 8) {
                Image(systemName: icon).font(.system(size: 14)).frame(width: 24)
                VStack(alignment: .leading, spacing: 2) {
                    Text(PMLocalization.text(title)).font(.system(size: 13, weight: .semibold))
                    Text(PMLocalization.text(subtitle)).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func importFromLattice() {
        guard !store.isBusy else { return }
        store.isBusy = true
        store.statusMessage = "正在只读读取 Lattice 文库…"
        Task {
            defer { store.isBusy = false }
            do {
                let summary = try await LatticeImportService.importFromRunningLattice(into: store)
                store.statusMessage = ([summary.text] + summary.warnings).joined(separator: " ")
            } catch {
                store.statusMessage = "Lattice 导入失败：\(error.localizedDescription)"
            }
        }
    }

    private func openSelectedPDF() {
        guard PaperDraftSession.flushAll(), let paper = selectedPapers.first else { return }
        PaperReaderActions.openPDF(paper, store: store)
    }

    private func quickLookSelectedPDF() {
        guard let paper = selectedPapers.first else { return }
        guard let attachment = paper.primaryPDF else {
            store.statusMessage = "这篇文献尚未关联 PDF，无法快速预览。"
            return
        }

        do {
            try attachment.withResolvedURL { url in
                guard FileManager.default.fileExists(atPath: url.path) else {
                    throw PaperManagerError.message("PDF 文件不存在，可能已在 Finder 中移动或删除。")
                }
                QuickLookService.shared.preview(url: url)
                store.markOpened(paper.id)
            }
        } catch {
            store.statusMessage = "无法快速预览 PDF：\(error.localizedDescription)"
        }
    }

    private func revealSelectedPDF() {
        guard let paper = selectedPapers.first else { return }
        guard let attachment = paper.primaryPDF else {
            store.statusMessage = "这篇文献尚未关联 PDF。"
            return
        }

        do {
            try attachment.withResolvedURL { url in
                guard FileManager.default.fileExists(atPath: url.path) else {
                    throw PaperManagerError.message("PDF 文件不存在，可能已在 Finder 中移动或删除。")
                }
                NSWorkspace.shared.activateFileViewerSelecting([url])
            }
        } catch {
            store.statusMessage = "无法在 Finder 中显示 PDF：\(error.localizedDescription)"
        }
    }

    private func deleteSelectedPapers() {
        guard !selectedPaperIDs.isEmpty else { return }
        if store.deletePapers(ids: selectedPaperIDs) { selectedPaperIDs.removeAll() }
    }

    private var canPresentFileImporter: Bool {
        !isPreparingImport && importPlan == nil && !showImporter
    }

    private func requestFileImport() {
        guard canPresentFileImporter else {
            store.statusMessage = PMLocalization.text("请先完成或取消当前导入。")
            return
        }
        showImporter = true
    }

    private func importURLs(_ urls: [URL]) {
        guard !isPreparingImport, importPlan == nil else {
            store.statusMessage = PMLocalization.text("请先完成或取消当前导入。")
            return
        }
        isPreparingImport = true
        importTargetFilter = selectedFilter
        let extensions = Set(urls.map { $0.pathExtension.lowercased() })
        importSourceKind = extensions.count == 1 ? ["bib": "BibTeX", "ris": "RIS", "pdf": "PDF"][extensions.first ?? ""] : nil
        store.statusMessage = "正在读取待导入文件…"
        Task {
            let plan = await prepareImport(urls, store)
            isPreparingImport = false
            importPlan = plan
        }
    }

    private func focusPaper(_ id: UUID) {
        searchText = ""
        if selectedFilter == .all { selectedPaperIDs = [id] }
        else { pendingOpenPaperID = id; selectedFilter = .all }
    }

    private func refreshMetadataForTargets() {
        guard PaperDraftSession.flushAll() else { return }
        store.enqueueMetadataRefresh(paperIDs: targetPapers.map(\.id))
    }

    private func exportBibTeX() {
        guard PaperDraftSession.flushAll() else { return }
        guard let url = DialogService.saveURL(title: "导出 BibTeX", name: "PaperManager.bib", types: [.bibTeX]) else { return }
        do {
            try ExportService.writeBibTeX(targetPapers, to: url, settings: store.settings, tags: store.tags)
            store.statusMessage = "导出完成。"
        } catch {
            store.statusMessage = "导出失败：\(error.localizedDescription)"
        }
    }

    private func exportRIS() {
        guard PaperDraftSession.flushAll() else { return }
        guard let url = DialogService.saveURL(title: "导出 RIS", name: "PaperManager.ris", types: [.ris]) else { return }
        do {
            try ExportService.writeRIS(targetPapers, to: url, settings: store.settings, tags: store.tags)
            store.statusMessage = "导出完成。"
        } catch {
            store.statusMessage = "导出失败：\(error.localizedDescription)"
        }
    }

    private func exportDetailed() {
        guard PaperDraftSession.flushAll() else { return }
        guard let folder = DialogService.chooseFolder(title: "选择导出文件夹") else { return }
        do {
            try ExportService.writeDetailedMarkdown(targetPapers, snapshot: store.snapshot, to: folder)
            store.statusMessage = "导出完成。"
        } catch {
            store.statusMessage = "导出失败：\(error.localizedDescription)"
        }
    }
}
