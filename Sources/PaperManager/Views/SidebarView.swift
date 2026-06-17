import SwiftUI
import UniformTypeIdentifiers

struct SidebarView: View {
    @EnvironmentObject private var store: LibraryStore
    @Binding var selectedFilter: LibraryFilter
    @Binding var searchText: String
    @Binding var includeSubcollections: Bool
    let focusSearchToken: Int

    private var flattenedCollections: [FlattenedCollection] {
        flatten(parentID: nil, depth: 0)
    }

    var body: some View {
        VStack(spacing: 0) {
            LatticeSidebarSearchField(text: $searchText, focusToken: focusSearchToken)
                .padding(.horizontal, 20)
                .padding(.top, 8)
                .padding(.bottom, 14)

            ScrollView {
                VStack(alignment: .leading, spacing: 13.5) {
                    VStack(alignment: .leading, spacing: 2) {
                        SidebarSectionHeader(title: "文库")
                        libraryRow("全部文献", systemImage: "books.vertical", count: store.papers.count, filter: .all)
                        libraryRow("最近添加", systemImage: "clock", count: recentAddedCount, filter: .recentlyAdded)
                        libraryRow("最近打开", systemImage: "clock.arrow.circlepath", count: recentOpenedCount, filter: .recentlyOpened)
                        libraryRow("未归类", systemImage: "archivebox", count: store.papers.filter(\.collectionIDs.isEmpty).count, filter: .unfiled)
                        libraryRow("缺少标识符", systemImage: "magnifyingglass.circle", count: store.papers.filter { !$0.hasIdentifier }.count, filter: .missingIDs)
                        libraryRow("缺少 PDF", systemImage: "paperclip", count: store.papers.filter { !$0.hasPDF }.count, filter: .missingPDF)
                        libraryRow("无标签", systemImage: "tag", count: store.papers.filter(\.tagIDs.isEmpty).count, filter: .noTags)
                    }

                    VStack(alignment: .leading, spacing: 2) {
                        SidebarSectionHeader(title: "评分")
                        ForEach((0...5).reversed(), id: \.self) { rating in
                            libraryRow(ratingTitle(rating), systemImage: rating == 0 ? "star.slash" : "star", count: ratingCount(rating), filter: .rating(rating))
                        }
                    }

                    VStack(alignment: .leading, spacing: 2) {
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

                    VStack(alignment: .leading, spacing: 2) {
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
                            .font(PMTypography.captionRegular)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 16)
                    }
                }
                .padding(.horizontal, 20)
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
            .font(PMTypography.caption)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 32)
            .frame(height: 28, alignment: .leading)
    }

    private var recentAddedCount: Int {
        store.papers.filter { Date().timeIntervalSince($0.dateAdded) <= 60 * 60 * 24 * 30 }.count
    }

    private var recentOpenedCount: Int {
        store.papers.filter { $0.lastOpenedAt != nil }.count
    }

    private func ratingCount(_ rating: Int) -> Int {
        store.papers.filter { $0.rating == rating }.count
    }

    private func ratingTitle(_ rating: Int) -> String {
        rating == 0 ? "未评分" : "\(rating) 星"
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

struct SidebarSectionHeader: View {
    let title: String
    var action: (() -> Void)?

    init(title: String, action: (() -> Void)? = nil) {
        self.title = title
        self.action = action
    }

    var body: some View {
        HStack {
            Text(title)
                .font(PMTypography.font(size: 11.25, weight: .bold))
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
        .padding(.horizontal, 10)
        .frame(height: 17)
    }
}

struct SidebarNavigationRow<Leading: View>: View {
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
                    .font(.system(size: 13.5, weight: .medium))
                    .frame(width: 17)
                    .foregroundStyle(isSelected ? Color.accentColor : Color.primary.opacity(0.72))

                Text(title)
                    .font(PMTypography.font(size: 12, weight: .semibold))
                    .lineLimit(1)
                    .foregroundStyle(isSelected ? Color.accentColor : Color.primary.opacity(0.88))

                Spacer(minLength: 8)

                if let count {
                    Text("\(count)")
                        .font(PMTypography.font(size: 9.75, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }
            .padding(.leading, 10 + CGFloat(depth * 12))
            .padding(.trailing, 10)
            .frame(maxWidth: .infinity, minHeight: 30, alignment: .leading)
            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .background {
                if isSelected {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color.primary.opacity(0.07))
                        .overlay {
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .strokeBorder(Color.white.opacity(0.16), lineWidth: 0.6)
                        }
                }
            }
        }
        .buttonStyle(.plain)
        .help(title)
    }
}

private struct LatticeSidebarSearchField: View {
    @Binding var text: String
    let focusToken: Int
    @FocusState private var isFocused: Bool

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
                .font(.system(size: 10, weight: .medium))
            TextField("搜索文献", text: $text)
                .textFieldStyle(.plain)
                .font(PMTypography.font(size: 12, weight: .semibold))
                .focused($isFocused)
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
        .padding(.horizontal, 10)
        .frame(height: 30)
        .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 15, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 15, style: .continuous)
                .strokeBorder(Color.white.opacity(0.18), lineWidth: 0.6)
        }
        .onChange(of: focusToken) { _, _ in
            isFocused = true
        }
    }
}
