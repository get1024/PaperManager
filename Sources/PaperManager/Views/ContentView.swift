 import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @EnvironmentObject private var store: LibraryStore
    @EnvironmentObject private var localAPI: LocalAPIServer

    @State private var selectedFilter: LibraryFilter = .all
    @State private var selectedPaperIDs: Set<UUID> = []
    @State private var searchText = ""
    @State private var showImporter = false
    @State private var showManualAdd = false
    @State private var showDOIAdd = false
    @State private var includeSubcollections = true
    @State private var showSidebar = true
    @State private var showInspector = true
    @State private var sortDescriptor = PaperSortDescriptor.defaultValue
    @State private var focusSearchToken = 0
    @State private var showAddPopover = false
    @State private var pendingOpenPaperID: UUID?
    @State private var importPlan: ImportPlan?
    @State private var importTargetFilter: LibraryFilter?
    @State private var isPreparingImport = false

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
            onExportDetailed: exportDetailed
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .font(PMTypography.bodyRegular)
        .background(WindowChromeConfigurator { window in
            window.titleVisibility = .hidden
            window.titlebarAppearsTransparent = true
            window.styleMask.insert(.fullSizeContentView)
            window.isMovableByWindowBackground = true
            window.contentMinSize = NSSize(width: 1080, height: 680)
        })
        .preferredColorScheme(store.settings.appearance.preferredColorScheme)
        .environment(\.locale, PMLocalization.locale(for: store.settings.languageIdentifier))
        .navigationTitle(selectedTitle)
        .focusedSceneValue(\.paperManagerWindowActions, windowActions)
        .toolbar(removing: .sidebarToggle)
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Menu {
                    Toggle("文库侧栏", isOn: $showSidebar)
                    Toggle("论文检查器", isOn: $showInspector)
                } label: {
                    Label("面板", systemImage: "rectangle.split.3x1")
                }
                .labelStyle(.iconOnly)
                .help("显示或隐藏文库侧栏和论文检查器")
                .accessibilityIdentifier("main-toolbar-panels")
            }
            ToolbarItemGroup(placement: .primaryAction) {
                Button { showAddPopover.toggle() } label: {
                    Label("添加", systemImage: "plus")
                }
                .labelStyle(.iconOnly)
                .accessibilityIdentifier("main-toolbar-add")
                .disabled(isPreparingImport)
                .popover(isPresented: $showAddPopover, arrowEdge: .bottom) {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("添加文献").font(.headline)
                        Text("导入文件或通过元数据创建文献。")
                            .foregroundStyle(.secondary)
                        addAction("导入文件…", subtitle: "支持 PDF、BibTeX、RIS 或文件夹", icon: "doc.badge.plus") {
                            showImporter = true
                        }
                        addAction("通过标识符添加…", subtitle: "支持 DOI、arXiv、ISBN 或标题", icon: "link") {
                            showDOIAdd = true
                        }
                        addAction("手动添加…", subtitle: "通过输入元数据创建文献", icon: "square.and.pencil") {
                            showManualAdd = true
                        }
                        Divider()
                        addAction("从 Lattice 导入…", subtitle: "只读读取文献、文集、标签和 PDF 引用", icon: "tray.and.arrow.down") {
                            importFromLattice()
                        }
                        .disabled(store.isBusy)
                    }
                    .padding(18)
                    .frame(width: 310)
                }

                Menu {
                    Button("导出 BibTeX...") { exportBibTeX() }
                    Button("导出 RIS...") { exportRIS() }
                    Button("详细导出...") { exportDetailed() }
                    Divider()
                    Button("复制 BibTeX") { ExportService.copyToPasteboard(ExportService.bibTeX(for: targetPapers, settings: store.settings, tags: store.tags)) }
                    Button("复制 RIS") { ExportService.copyToPasteboard(ExportService.ris(for: targetPapers, settings: store.settings, tags: store.tags)) }
                } label: {
                    Label("导出", systemImage: "square.and.arrow.up")
                }
                .labelStyle(.iconOnly)
                .accessibilityIdentifier("main-toolbar-export")

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
            ImportPreviewView(plan: plan, targetFilter: importTargetFilter, onOpenExisting: focusPaper)
                .environmentObject(store)
        }
        .sheet(isPresented: $showDOIAdd) {
            DOISheet(targetFilter: selectedFilter, onOpenExisting: focusPaper)
                .environmentObject(store)
        }
        .onAppear {
            localAPI.reconfigure(with: store)
            showInspector = store.settings.showInspectorByDefault
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
        .onReceive(NotificationCenter.default.publisher(for: .paperManagerImportRequested)) { _ in
            showImporter = true
        }
        .onReceive(NotificationCenter.default.publisher(for: .paperManagerDOIRequested)) { _ in
            showDOIAdd = true
        }
        .onReceive(NotificationCenter.default.publisher(for: .paperManagerManualAddRequested)) { _ in
            showManualAdd = true
        }
        .onReceive(NotificationCenter.default.publisher(for: .paperManagerExportBibTeXRequested)) { _ in
            exportBibTeX()
        }
        .onReceive(NotificationCenter.default.publisher(for: .paperManagerOpenSelectedRequested)) { _ in
            openSelectedPDF()
        }
        .onReceive(NotificationCenter.default.publisher(for: .paperManagerQuickLookRequested)) { _ in
            quickLookSelectedPDF()
        }
        .onReceive(NotificationCenter.default.publisher(for: .paperManagerRevealSelectedRequested)) { _ in
            revealSelectedPDF()
        }
        .onReceive(NotificationCenter.default.publisher(for: .paperManagerDeleteSelectedRequested)) { _ in
            deleteSelectedPapers()
        }
        .onReceive(NotificationCenter.default.publisher(for: .paperManagerFocusSearchRequested)) { _ in
            focusSearchToken += 1
        }
    }

    private var windowActions: PaperManagerWindowActions {
        PaperManagerWindowActions(
            importFiles: { showImporter = true }, addIdentifier: { showDOIAdd = true },
            addManually: { showManualAdd = true }, focusSearch: { focusSearchToken += 1 },
            openSelected: openSelectedPDF, quickLook: quickLookSelectedPDF,
            revealSelected: revealSelectedPDF, deleteSelected: deleteSelectedPapers,
            exportBibTeX: exportBibTeX, toggleSidebar: { showSidebar.toggle() },
            toggleInspector: { showInspector.toggle() }, hasSelection: !selectedPaperIDs.isEmpty,
            sidebarVisible: showSidebar, inspectorVisible: showInspector
        )
    }

    private func openPaperURL(_ url: URL) {
        guard url.scheme == "papermanager", url.host == "paper",
              let id = UUID(uuidString: url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))),
              store.paper(with: id) != nil else { return }
        focusPaper(id)
    }

    private var selectedPapers: [Paper] {
        visiblePapers.filter { selectedPaperIDs.contains($0.id) }
    }

    private func addAction(_ title: String, subtitle: String, icon: String, action: @escaping () -> Void) -> some View {
        Button {
            showAddPopover = false
            action()
        } label: {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: icon).frame(width: 22)
                VStack(alignment: .leading, spacing: 3) {
                    Text(PMLocalization.text(title))
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
                if let readerPath = store.settings.defaultPDFReaderPath.nilIfBlank {
                    let appURL = URL(fileURLWithPath: readerPath)
                    let configuration = NSWorkspace.OpenConfiguration()
                    NSWorkspace.shared.open([url], withApplicationAt: appURL, configuration: configuration) { _, error in
                        if let error {
                            Task { @MainActor in
                                store.statusMessage = "无法使用所选阅读器打开 PDF：\(error.localizedDescription)"
                            }
                        }
                    }
                } else {
                    NSWorkspace.shared.open(url)
                }
                store.markOpened(paper.id)
                if store.settings.autoExtractAnnotationsAfterOpeningPDF {
                    refreshAnnotations(for: paper.id, attachment: attachment)
                }
            }
        } catch {
            store.statusMessage = "无法打开 PDF：\(error.localizedDescription)"
        }
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
        store.deletePapers(ids: selectedPaperIDs)
        selectedPaperIDs.removeAll()
    }

    private func importURLs(_ urls: [URL]) {
        guard !isPreparingImport else { return }
        isPreparingImport = true
        importTargetFilter = selectedFilter
        store.statusMessage = "正在读取待导入文件…"
        Task {
            let plan = await ImportService.prepare(urls, store: store)
            isPreparingImport = false
            importPlan = plan
        }
    }

    private func focusPaper(_ id: UUID) {
        searchText = ""
        if selectedFilter == .all { selectedPaperIDs = [id] }
        else { pendingOpenPaperID = id; selectedFilter = .all }
    }

    private func refreshAnnotations(for paperID: UUID, attachment: Attachment) {
        Task {
            do {
                let annotations = try await ImportService.extractAnnotations(from: attachment, paperID: paperID)
                store.updateAnnotations(annotations, for: paperID)
                store.statusMessage = "标注已刷新。"
            } catch {
                store.statusMessage = "标注提取失败：\(error.localizedDescription)"
            }
        }
    }

    private func refreshMetadataForTargets() {
        let papers = targetPapers
        guard !papers.isEmpty else { return }
        Task {
            store.isBusy = true
            defer { store.isBusy = false }
            var updated = 0
            var failed = 0
            for (index, paper) in papers.enumerated() {
                store.statusMessage = "正在刷新元数据 \(index + 1)/\(papers.count)：\(paper.displayTitle)"
                do {
                    let metadata = try await MetadataLookupClient.lookup(
                        doi: paper.doi.nilIfBlank,
                        arxivID: paper.arxivLookupID,
                        isbn: paper.isbn.nilIfBlank,
                        title: paper.title.nilIfBlank
                    )
                    if let latest = store.paper(with: paper.id) {
                        store.updatePaper(metadata.merged(into: latest, replaceExisting: false))
                        updated += 1
                    }
                } catch {
                    failed += 1
                }
            }
            store.statusMessage = "元数据刷新完成：\(updated) 篇更新，\(failed) 篇失败。"
        }
    }

    private func defaultAscending(for field: PaperSortField) -> Bool {
        switch field {
        case .title, .authors, .source:
            return true
        case .year, .rating, .dateAdded, .lastOpened:
            return false
        }
    }

    private func exportBibTeX() {
        guard let url = DialogService.saveURL(title: "导出 BibTeX", name: "PaperManager.bib", types: [.bibTeX]) else { return }
        do {
            try ExportService.writeBibTeX(targetPapers, to: url, settings: store.settings, tags: store.tags)
            store.statusMessage = "导出完成。"
        } catch {
            store.statusMessage = "导出失败：\(error.localizedDescription)"
        }
    }

    private func exportRIS() {
        guard let url = DialogService.saveURL(title: "导出 RIS", name: "PaperManager.ris", types: [.ris]) else { return }
        do {
            try ExportService.writeRIS(targetPapers, to: url, settings: store.settings, tags: store.tags)
            store.statusMessage = "导出完成。"
        } catch {
            store.statusMessage = "导出失败：\(error.localizedDescription)"
        }
    }

    private func exportDetailed() {
        guard let folder = DialogService.chooseFolder(title: "选择导出文件夹") else { return }
        do {
            try ExportService.writeDetailedMarkdown(targetPapers, snapshot: store.snapshot, to: folder)
            store.statusMessage = "导出完成。"
        } catch {
            store.statusMessage = "导出失败：\(error.localizedDescription)"
        }
    }
}
