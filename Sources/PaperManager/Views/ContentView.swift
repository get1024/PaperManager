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
    @State private var showInspector = true

    private var visiblePapers: [Paper] {
        store.filteredPapers(for: selectedFilter, searchText: searchText, includeSubcollections: includeSubcollections)
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
        HStack(spacing: 0) {
            SidebarView(
                selectedFilter: $selectedFilter,
                searchText: $searchText,
                includeSubcollections: $includeSubcollections
            )
            .frame(width: LatticeStyle.sidebarWidth)

            Rectangle()
                .fill(LatticeStyle.separator)
                .frame(width: 0.6)

            PaperListView(
                title: selectedTitle,
                papers: visiblePapers,
                selection: $selectedPaperIDs,
                searchText: $searchText
            )
            .frame(minWidth: 470)

            if showInspector {
                Rectangle()
                    .fill(LatticeStyle.separator)
                    .frame(width: 0.6)

                PaperDetailView(selection: $selectedPaperIDs)
                    .frame(width: LatticeStyle.inspectorWidth)
            }
        }
        .background(LatticeStyle.contentBackground)
        .preferredColorScheme(store.settings.appearance.preferredColorScheme)
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Menu {
                    Button("导入文件...") { showImporter = true }
                    Button("通过 DOI 添加...") { showDOIAdd = true }
                    Button("手动添加...") { showManualAdd = true }
                } label: {
                    Image(systemName: "plus")
                }

                Menu {
                    Button("导出 BibTeX...") { exportBibTeX() }
                    Button("导出 RIS...") { exportRIS() }
                    Button("详细导出...") { exportDetailed() }
                    Divider()
                    Button("复制 BibTeX") { ExportService.copyToPasteboard(ExportService.bibTeX(for: targetPapers)) }
                    Button("复制 RIS") { ExportService.copyToPasteboard(ExportService.ris(for: targetPapers)) }
                } label: {
                    Image(systemName: "square.and.arrow.up")
                }

                Button {
                    showInspector.toggle()
                } label: {
                    Image(systemName: "sidebar.right")
                }
                .help(showInspector ? "隐藏检查器" : "显示检查器")

                Button(role: .destructive) {
                    store.deletePapers(ids: selectedPaperIDs)
                    selectedPaperIDs.removeAll()
                } label: {
                    Image(systemName: "trash")
                }
                .disabled(selectedPaperIDs.isEmpty)
                .help("删除所选文献")
            }
        }
        .fileImporter(
            isPresented: $showImporter,
            allowedContentTypes: [.pdf, .bibTeX, .ris, .folder],
            allowsMultipleSelection: true
        ) { result in
            if case .success(let urls) = result {
                Task { await ImportService.importURLs(urls, into: store, targetFilter: selectedFilter) }
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
        }
        .onChange(of: selectedFilter) { _, _ in
            selectedPaperIDs.removeAll()
        }
        .onChange(of: store.settings) { _, _ in
            localAPI.reconfigure(with: store)
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
