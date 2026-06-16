import SwiftUI

struct SidebarView: View {
    @EnvironmentObject private var store: LibraryStore
    @Binding var selectedFilter: LibraryFilter
    @Binding var includeSubcollections: Bool

    private var flattenedCollections: [FlattenedCollection] {
        flatten(parentID: nil, depth: 0)
    }

    var body: some View {
        List(selection: $selectedFilter) {
            Section("文库") {
                libraryRow("全部文献", systemImage: "books.vertical", count: store.papers.count, filter: .all)
                libraryRow("未归类", systemImage: "tray", count: store.papers.filter(\.collectionIDs.isEmpty).count, filter: .unfiled)
                libraryRow("缺少 DOI", systemImage: "magnifyingglass.circle", count: store.papers.filter { $0.doi.trimmed.isEmpty }.count, filter: .missingIDs)
                libraryRow("缺少 PDF", systemImage: "paperclip", count: store.papers.filter { !$0.hasPDF }.count, filter: .missingPDF)
            }

            Section {
                if flattenedCollections.isEmpty {
                    Text("暂无文集")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(flattenedCollections) { item in
                        collectionRow(item)
                    }
                }
            } header: {
                sectionHeader("文集") {
                    store.addCollection(name: "新建文集")
                }
            }

            Section {
                if store.tags.isEmpty {
                    Text("暂无标签")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(store.tags) { tag in
                        tagRow(tag)
                    }
                }
            } header: {
                sectionHeader("标签") {
                    store.addTag(name: "新建标签")
                }
            }

            if let message = store.statusMessage {
                Section {
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle("PaperManager")
    }

    @ViewBuilder
    private func libraryRow(_ title: String, systemImage: String, count: Int, filter: LibraryFilter) -> some View {
        let row = Label(title, systemImage: systemImage)
            .tag(filter)

        if count > 0 {
            row.badge(count)
        } else {
            row
        }
    }

    @ViewBuilder
    private func collectionRow(_ item: FlattenedCollection) -> some View {
        let filter = LibraryFilter.collection(item.collection.id)
        let count = paperCount(collectionID: item.collection.id)
        let row = Label(item.collection.name, systemImage: "folder")
            .padding(.leading, CGFloat(item.depth * 12))
            .tag(filter)
            .contextMenu {
                Toggle("显示子文集文献", isOn: $includeSubcollections)
                Button("新建子文集") { store.addCollection(name: "新建子文集", parentID: item.collection.id) }
                Button("重命名") { renameCollection(item.collection) }
                Button("删除", role: .destructive) { store.deleteCollection(id: item.collection.id) }
            }

        if count > 0 {
            row.badge(count)
        } else {
            row
        }
    }

    @ViewBuilder
    private func tagRow(_ tag: PaperTag) -> some View {
        let count = paperCount(tagID: tag.id)
        let row = HStack {
            Circle()
                .fill(Color(hex: tag.colorHex))
                .frame(width: 8, height: 8)
            Text(tag.name)
        }
        .tag(LibraryFilter.tag(tag.id))
        .contextMenu {
            Button("重命名") { renameTag(tag) }
            Button("更改颜色") { recolorTag(tag) }
            Button("删除", role: .destructive) { store.deleteTag(id: tag.id) }
        }

        if count > 0 {
            row.badge(count)
        } else {
            row
        }
    }

    private func sectionHeader(_ title: String, action: @escaping () -> Void) -> some View {
        HStack {
            Text(title)
            Spacer()
            Button(action: action) {
                Image(systemName: "plus")
            }
            .buttonStyle(.borderless)
            .help("新建\(title)")
        }
    }

    private func flatten(parentID: UUID?, depth: Int) -> [FlattenedCollection] {
        store.collections.children(of: parentID).flatMap { collection -> [FlattenedCollection] in
            [FlattenedCollection(collection: collection, depth: depth)] + flatten(parentID: collection.id, depth: depth + 1)
        }
    }

    private func paperCount(collectionID: UUID) -> Int {
        let ids = includeSubcollections ? store.collections.descendantIDs(of: collectionID) : [collectionID]
        return store.papers.filter { paper in
            paper.collectionIDs.contains { ids.contains($0) }
        }.count
    }

    private func paperCount(tagID: UUID) -> Int {
        store.papers.filter { $0.tagIDs.contains(tagID) }.count
    }

    private func renameCollection(_ collection: PaperCollection) {
        guard let name = DialogService.requestText(title: "重命名文集", defaultValue: collection.name), !name.isEmpty else { return }
        store.renameCollection(id: collection.id, name: name)
    }

    private func renameTag(_ tag: PaperTag) {
        guard let name = DialogService.requestText(title: "重命名标签", defaultValue: tag.name), !name.isEmpty else { return }
        store.renameTag(id: tag.id, name: name)
    }

    private func recolorTag(_ tag: PaperTag) {
        guard let color = DialogService.requestText(title: "标签颜色", message: "输入十六进制颜色。", defaultValue: tag.colorHex), !color.isEmpty else { return }
        store.updateTagColor(id: tag.id, colorHex: color)
    }
}

private struct FlattenedCollection: Identifiable {
    let collection: PaperCollection
    let depth: Int
    var id: UUID { collection.id }
}
