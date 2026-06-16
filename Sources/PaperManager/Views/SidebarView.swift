import SwiftUI
import UniformTypeIdentifiers

struct SidebarView: View {
    @EnvironmentObject private var store: LibraryStore
    @Binding var selectedFilter: LibraryFilter
    @Binding var searchText: String
    @Binding var includeSubcollections: Bool

    private var flattenedCollections: [FlattenedCollection] {
        flatten(parentID: nil, depth: 0)
    }

    var body: some View {
        VStack(spacing: 0) {
            LatticeSidebarSearchField(text: $searchText)
                .padding(.horizontal, 12)
                .padding(.top, 14)
                .padding(.bottom, 12)

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    VStack(alignment: .leading, spacing: 3) {
                        SidebarSectionHeader(title: "文库")
                        libraryRow("全部文献", systemImage: "books.vertical", count: store.papers.count, filter: .all)
                        libraryRow("未归类", systemImage: "archivebox", count: store.papers.filter(\.collectionIDs.isEmpty).count, filter: .unfiled)
                        libraryRow("缺少标识符", systemImage: "magnifyingglass.circle", count: store.papers.filter { !$0.hasIdentifier }.count, filter: .missingIDs)
                        libraryRow("缺少 PDF", systemImage: "paperclip", count: store.papers.filter { !$0.hasPDF }.count, filter: .missingPDF)
                        libraryRow("无标签", systemImage: "tag", count: store.papers.filter(\.tagIDs.isEmpty).count, filter: .noTags)
                    }

                    VStack(alignment: .leading, spacing: 3) {
                        SidebarSectionHeader(title: "文集", action: {
                            store.addCollection(name: "新建文集")
                        })

                        if flattenedCollections.isEmpty {
                            emptySidebarText("暂无文集")
                        } else {
                            ForEach(flattenedCollections) { item in
                                collectionRow(item)
                            }
                        }
                    }

                    VStack(alignment: .leading, spacing: 3) {
                        SidebarSectionHeader(title: "标签", action: {
                            store.addTag(name: "新建标签")
                        })

                        if store.tags.isEmpty {
                            emptySidebarText("暂无标签")
                        } else {
                            ForEach(store.tags) { tag in
                                tagRow(tag)
                            }
                        }
                    }

                    if let message = store.statusMessage {
                        Text(message)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 18)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 18)
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }
        }
        .navigationTitle("PaperManager")
    }

    @ViewBuilder
    private func libraryRow(_ title: String, systemImage: String, count: Int, filter: LibraryFilter) -> some View {
        SidebarNavigationRow(
            title: title,
            systemImage: systemImage,
            count: count > 0 ? count : nil,
            depth: 0,
            isSelected: selectedFilter == filter
        ) {
            selectedFilter = filter
        }
    }

    @ViewBuilder
    private func collectionRow(_ item: FlattenedCollection) -> some View {
        let filter = LibraryFilter.collection(item.collection.id)
        let count = paperCount(collectionID: item.collection.id)
        SidebarNavigationRow(
            title: item.collection.name,
            systemImage: "folder",
            count: count > 0 ? count : nil,
            depth: item.depth,
            isSelected: selectedFilter == filter
        ) {
            selectedFilter = filter
        }
            .onDrop(of: [UTType.plainText.identifier], isTargeted: nil) { providers in
                acceptDroppedPapers(providers) { ids in
                    store.addPapers(ids: ids, toCollection: item.collection.id)
                    store.statusMessage = "已加入文集：\(item.collection.name)"
                }
            }
            .contextMenu {
                Toggle("显示子文集文献", isOn: $includeSubcollections)
                Button("新建子文集") { store.addCollection(name: "新建子文集", parentID: item.collection.id) }
                Button("重命名") { renameCollection(item.collection) }
                Button("删除", role: .destructive) { store.deleteCollection(id: item.collection.id) }
            }
    }

    @ViewBuilder
    private func tagRow(_ tag: PaperTag) -> some View {
        let filter = LibraryFilter.tag(tag.id)
        let count = paperCount(tagID: tag.id)
        SidebarNavigationRow(
            title: tag.name,
            count: count > 0 ? count : nil,
            isSelected: selectedFilter == filter
        ) {
            selectedFilter = filter
        } leading: {
            ZStack {
                Image(systemName: "tag")
                    .opacity(0.7)
                Circle()
                    .fill(Color(hex: tag.colorHex))
                    .frame(width: 7, height: 7)
                    .offset(x: 7, y: 7)
            }
        }
        .onDrop(of: [UTType.plainText.identifier], isTargeted: nil) { providers in
            acceptDroppedPapers(providers) { ids in
                store.addPapers(ids: ids, toTag: tag.id)
                store.statusMessage = "已加入标签：\(tag.name)"
            }
        }
        .contextMenu {
            Button("重命名") { renameTag(tag) }
            Button("更改颜色") { recolorTag(tag) }
            Button("删除", role: .destructive) { store.deleteTag(id: tag.id) }
        }
    }

    private func emptySidebarText(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 15, weight: .semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 36)
            .frame(height: 34, alignment: .leading)
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

    private func acceptDroppedPapers(_ providers: [NSItemProvider], apply: @escaping (Set<UUID>) -> Void) -> Bool {
        var didFindPaperIDs = false
        for provider in providers where provider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier) {
            didFindPaperIDs = true
            provider.loadItem(forTypeIdentifier: UTType.plainText.identifier, options: nil) { item, _ in
                let text: String?
                if let value = item as? String {
                    text = value
                } else if let data = item as? Data {
                    text = String(data: data, encoding: .utf8)
                } else {
                    text = nil
                }

                guard let ids = parsePaperIDs(text), !ids.isEmpty else { return }
                DispatchQueue.main.async {
                    apply(ids)
                }
            }
        }
        return didFindPaperIDs
    }

    private func parsePaperIDs(_ text: String?) -> Set<UUID>? {
        guard let text, text.hasPrefix("papermanager-paper-ids:") else { return nil }
        let suffix = text.replacingOccurrences(of: "papermanager-paper-ids:", with: "")
        let ids = suffix
            .split(separator: ",")
            .compactMap { UUID(uuidString: String($0)) }
        return Set(ids)
    }
}

private struct FlattenedCollection: Identifiable {
    let collection: PaperCollection
    let depth: Int
    var id: UUID { collection.id }
}

private struct SidebarSectionHeader: View {
    let title: String
    var action: (() -> Void)?

    init(title: String, action: (() -> Void)? = nil) {
        self.title = title
        self.action = action
    }

    var body: some View {
        HStack {
            Text(title)
                .font(.system(size: 15, weight: .bold))
                .foregroundStyle(.secondary)
            Spacer()
            if let action {
                Button(action: action) {
                    Image(systemName: "plus")
                }
                .buttonStyle(.borderless)
                .help("新建\(title)")
            }
        }
        .padding(.horizontal, 18)
        .frame(height: 24)
    }
}

private struct SidebarNavigationRow<Leading: View>: View {
    let title: String
    let count: Int?
    let depth: Int
    let isSelected: Bool
    let action: () -> Void
    let leading: Leading

    init(
        title: String,
        systemImage: String,
        count: Int? = nil,
        depth: Int = 0,
        isSelected: Bool,
        action: @escaping () -> Void
    ) where Leading == Image {
        self.title = title
        self.count = count
        self.depth = depth
        self.isSelected = isSelected
        self.action = action
        self.leading = Image(systemName: systemImage)
    }

    init(
        title: String,
        count: Int? = nil,
        depth: Int = 0,
        isSelected: Bool,
        action: @escaping () -> Void,
        @ViewBuilder leading: () -> Leading
    ) {
        self.title = title
        self.count = count
        self.depth = depth
        self.isSelected = isSelected
        self.action = action
        self.leading = leading()
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                leading
                    .font(.system(size: 20, weight: .medium))
                    .frame(width: 24)
                    .foregroundStyle(isSelected ? Color.accentColor : Color.primary.opacity(0.86))

                Text(title)
                    .font(.system(size: 18, weight: .semibold))
                    .lineLimit(1)
                    .foregroundStyle(isSelected ? Color.accentColor : Color.primary)

                Spacer(minLength: 8)

                if let count {
                    Text("\(count)")
                        .font(.system(size: 18, weight: .medium))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }
            .padding(.leading, 18 + CGFloat(depth * 14))
            .padding(.trailing, 14)
            .frame(maxWidth: .infinity, minHeight: 38, alignment: .leading)
            .contentShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
            .background {
                if isSelected {
                    RoundedRectangle(cornerRadius: 11, style: .continuous)
                        .fill(Color(nsColor: .selectedContentBackgroundColor).opacity(0.24))
                }
            }
        }
        .buttonStyle(.plain)
        .help(title)
    }
}

private struct LatticeSidebarSearchField: View {
    @Binding var text: String

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
                .font(.system(size: 17, weight: .medium))
            TextField("搜索文献", text: $text)
                .textFieldStyle(.plain)
                .font(.system(size: 18, weight: .semibold))
            if !text.isEmpty {
                Button {
                    text = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 14)
        .frame(height: 38)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }
}
