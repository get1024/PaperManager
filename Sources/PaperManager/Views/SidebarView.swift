import SwiftUI

struct SidebarView: View {
    @EnvironmentObject private var store: LibraryStore
    @Binding var selectedFilter: LibraryFilter
    @Binding var searchText: String
    @Binding var includeSubcollections: Bool
    @FocusState private var searchFocused: Bool

    private var flattenedCollections: [FlattenedCollection] {
        flatten(parentID: nil, depth: 0)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            topBar
                .padding(.top, 18)
                .padding(.horizontal, 18)

            searchField
                .padding(.horizontal, 16)
                .padding(.top, 18)

            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    sidebarSection("文库") {
                        sidebarButton("全部文献", systemImage: "books.vertical", count: store.papers.count, filter: .all)
                        sidebarButton("未归类", systemImage: "tray", count: store.papers.filter(\.collectionIDs.isEmpty).count, filter: .unfiled)
                        sidebarButton("缺少标识符", systemImage: "magnifyingglass.circle", count: store.papers.filter { !$0.hasIdentifier }.count, filter: .missingIDs)
                        sidebarButton("缺少 PDF", systemImage: "paperclip", count: store.papers.filter { !$0.hasPDF }.count, filter: .missingPDF)
                    }

                    sidebarSection("文集") {
                        if flattenedCollections.isEmpty {
                            emptySidebarLine("暂无文集")
                        } else {
                            ForEach(flattenedCollections) { item in
                                sidebarButton(
                                    item.collection.name,
                                    systemImage: "folder",
                                    count: paperCount(collectionID: item.collection.id),
                                    filter: .collection(item.collection.id),
                                    depth: item.depth
                                )
                                .contextMenu {
                                    Toggle("显示子文集文献", isOn: $includeSubcollections)
                                    Button("新建子文集") { store.addCollection(name: "新建子文集", parentID: item.collection.id) }
                                    Button("重命名") { renameCollection(item.collection) }
                                    Button("删除", role: .destructive) { store.deleteCollection(id: item.collection.id) }
                                }
                            }
                        }
                    } trailing: {
                        Button {
                            store.addCollection(name: "新建文集")
                        } label: {
                            Image(systemName: "plus")
                        }
                        .buttonStyle(.plain)
                        .help("新建文集")
                    }

                    sidebarSection("标签") {
                        if store.tags.isEmpty {
                            emptySidebarLine("暂无标签")
                        } else {
                            ForEach(store.tags) { tag in
                                tagButton(tag)
                                    .contextMenu {
                                        Button("重命名") { renameTag(tag) }
                                        Button("更改颜色") { recolorTag(tag) }
                                        Button("删除", role: .destructive) { store.deleteTag(id: tag.id) }
                                    }
                            }
                        }
                    } trailing: {
                        Button {
                            store.addTag(name: "新建标签")
                        } label: {
                            Image(systemName: "plus")
                        }
                        .buttonStyle(.plain)
                        .help("新建标签")
                    }
                }
                .padding(.horizontal, 12)
                .padding(.top, 18)
                .padding(.bottom, 16)
            }

            if let message = store.statusMessage {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.bar)
            }
        }
        .background(LatticeStyle.sidebarBackground)
    }

    private var topBar: some View {
        HStack {
            Text("PaperManager")
                .font(.headline)
                .fontWeight(.semibold)
                .lineLimit(1)
            Spacer()
            Image(systemName: "sidebar.left")
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(.secondary)
        }
    }

    private var searchField: some View {
        HStack(spacing: 7) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField("搜索文献", text: $searchText)
                .textFieldStyle(.plain)
                .focused($searchFocused)
        }
        .font(.callout)
        .padding(.horizontal, 10)
        .frame(height: 34)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.primary.opacity(0.055))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(searchFocused ? Color.accentColor.opacity(0.75) : Color.clear, lineWidth: 2)
        )
    }

    private func sidebarSection<Content: View, Trailing: View>(
        _ title: String,
        @ViewBuilder content: () -> Content,
        @ViewBuilder trailing: () -> Trailing
    ) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                Text(title)
                    .font(.caption)
                    .fontWeight(.semibold)
                    .foregroundStyle(.secondary)
                Spacer()
                trailing()
            }
            .padding(.horizontal, 10)
            content()
        }
    }

    private func sidebarSection<Content: View>(
        _ title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        sidebarSection(title, content: content) {
            EmptyView()
        }
    }

    private func sidebarButton(
        _ title: String,
        systemImage: String,
        count: Int,
        filter: LibraryFilter,
        depth: Int = 0
    ) -> some View {
        Button {
            selectedFilter = filter
        } label: {
            HStack(spacing: 9) {
                Image(systemName: systemImage)
                    .font(.system(size: 15, weight: .medium))
                    .frame(width: 18)
                Text(title)
                    .font(.callout)
                    .fontWeight(selectedFilter == filter ? .semibold : .medium)
                    .lineLimit(1)
                Spacer(minLength: 8)
                if count > 0 {
                    Text("\(count)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .foregroundStyle(selectedFilter == filter ? Color.accentColor : Color.primary)
            .padding(.leading, 10 + CGFloat(depth * 14))
            .padding(.trailing, 10)
            .frame(height: 36)
            .background(
                RoundedRectangle(cornerRadius: LatticeStyle.rowRadius, style: .continuous)
                    .fill(selectedFilter == filter ? LatticeStyle.selectedFill : Color.clear)
            )
        }
        .buttonStyle(.plain)
    }

    private func tagButton(_ tag: PaperTag) -> some View {
        Button {
            selectedFilter = .tag(tag.id)
        } label: {
            HStack(spacing: 9) {
                Circle()
                    .fill(Color(hex: tag.colorHex))
                    .frame(width: 10, height: 10)
                    .frame(width: 18)
                Text(tag.name)
                    .font(.callout)
                    .fontWeight(selectedFilter == .tag(tag.id) ? .semibold : .medium)
                    .lineLimit(1)
                Spacer(minLength: 8)
                let count = paperCount(tagID: tag.id)
                if count > 0 {
                    Text("\(count)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .foregroundStyle(selectedFilter == .tag(tag.id) ? Color.accentColor : Color.primary)
            .padding(.horizontal, 10)
            .frame(height: 36)
            .background(
                RoundedRectangle(cornerRadius: LatticeStyle.rowRadius, style: .continuous)
                    .fill(selectedFilter == .tag(tag.id) ? LatticeStyle.selectedFill : Color.clear)
            )
        }
        .buttonStyle(.plain)
    }

    private func emptySidebarLine(_ title: String) -> some View {
        Text(title)
            .font(.callout)
            .foregroundStyle(.tertiary)
            .padding(.horizontal, 10)
            .frame(height: 32, alignment: .leading)
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
