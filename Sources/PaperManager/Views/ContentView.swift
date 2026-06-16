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
    @State private var columnVisibility: NavigationSplitViewVisibility = .all
    @State private var sortDescriptor = PaperSortDescriptor.defaultValue
    @State private var focusSearchToken = 0

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

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            SidebarView(
                selectedFilter: $selectedFilter,
                searchText: $searchText,
                includeSubcollections: $includeSubcollections,
                focusSearchToken: focusSearchToken
            )
            .navigationSplitViewColumnWidth(min: 200, ideal: 226, max: 260)
        } content: {
            PaperListView(
                title: selectedTitle,
                papers: visiblePapers,
                selection: $selectedPaperIDs,
                searchText: $searchText,
                onOpenSelected: openSelectedPDF,
                onRevealSelected: revealSelectedPDF,
                onDeleteSelected: deleteSelectedPapers,
                onImportURLs: importURLs,
                density: store.settings.tableDensity
            )
            .navigationTitle(selectedTitle)
        } detail: {
            PaperDetailView(selection: $selectedPaperIDs)
                .navigationSplitViewColumnWidth(min: 300, ideal: 340, max: 400)
        }
        .font(PMTypography.bodyRegular)
        .preferredColorScheme(store.settings.appearance.preferredColorScheme)
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Menu {
                    Button("导入文件...") { showImporter = true }
                    Button("通过标识符添加...") { showDOIAdd = true }
                    Button("手动添加...") { showManualAdd = true }
                    Divider()
                    Button("刷新元数据") { refreshMetadataForTargets() }
                        .disabled(targetPapers.isEmpty || store.isBusy)
                } label: {
                    Label("添加", systemImage: "plus")
                }
                .labelStyle(.iconOnly)

                Menu {
                    Button("导出 BibTeX...") { exportBibTeX() }
                    Button("导出 RIS...") { exportRIS() }
                    Button("详细导出...") { exportDetailed() }
                    Divider()
                    Button("复制 BibTeX") { ExportService.copyToPasteboard(ExportService.bibTeX(for: targetPapers)) }
                    Button("复制 RIS") { ExportService.copyToPasteboard(ExportService.ris(for: targetPapers)) }
                } label: {
                    Label("导出", systemImage: "square.and.arrow.up")
                }
                .labelStyle(.iconOnly)

                Menu {
                    ForEach(PaperSortField.allCases) { field in
                        Button {
                            if sortDescriptor.field == field {
                                sortDescriptor.ascending.toggle()
                            } else {
                                sortDescriptor = PaperSortDescriptor(field: field, ascending: defaultAscending(for: field))
                            }
                        } label: {
                            if sortDescriptor.field == field {
                                Label(field.label, systemImage: sortDescriptor.ascending ? "arrow.up" : "arrow.down")
                            } else {
                                Text(field.label)
                            }
                        }
                    }
                } label: {
                    Label("排序", systemImage: "arrow.up.arrow.down")
                }
                .labelStyle(.iconOnly)

                Button {
                    columnVisibility = columnVisibility == .all ? .doubleColumn : .all
                } label: {
                    Label("切换检查器", systemImage: "sidebar.right")
                }
                .labelStyle(.iconOnly)
                .help("显示或隐藏检查器")
            }
        }
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
            ManualPaperSheet(targetFilter: selectedFilter)
                .environmentObject(store)
        }
        .sheet(isPresented: $showDOIAdd) {
            DOISheet(targetFilter: selectedFilter)
                .environmentObject(store)
        }
        .onAppear {
            localAPI.reconfigure(with: store)
            columnVisibility = store.settings.showInspectorByDefault ? .all : .doubleColumn
        }
        .onChange(of: selectedFilter) { _, _ in
            selectedPaperIDs.removeAll()
        }
        .onChange(of: store.settings) { _, _ in
            localAPI.reconfigure(with: store)
            columnVisibility = store.settings.showInspectorByDefault ? .all : .doubleColumn
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

    private var selectedPapers: [Paper] {
        visiblePapers.filter { selectedPaperIDs.contains($0.id) }
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
        Task { await ImportService.importURLs(urls, into: store, targetFilter: selectedFilter) }
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
                    store.updatePaper(metadata.merged(into: paper, replaceExisting: false))
                    updated += 1
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
            try ExportService.writeBibTeX(targetPapers, to: url)
            store.statusMessage = "导出完成。"
        } catch {
            store.statusMessage = "导出失败：\(error.localizedDescription)"
        }
    }

    private func exportRIS() {
        guard let url = DialogService.saveURL(title: "导出 RIS", name: "PaperManager.ris", types: [.ris]) else { return }
        do {
            try ExportService.writeRIS(targetPapers, to: url)
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
