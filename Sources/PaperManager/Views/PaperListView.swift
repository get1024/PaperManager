import SwiftUI
import UniformTypeIdentifiers

struct PaperListView: View {
    let title: String
    let papers: [Paper]
    @Binding var selection: Set<UUID>
    @Binding var searchText: String
    var onOpenSelected: () -> Void
    var onRevealSelected: () -> Void
    var onDeleteSelected: () -> Void
    var onImportURLs: ([URL]) -> Void

    var body: some View {
        Group {
            if papers.isEmpty {
                PaperManagerEmptyState(
                    systemImage: "doc.text",
                    title: searchText.isEmpty ? "暂无文献" : "没有结果",
                    message: searchText.isEmpty ? "导入 PDF、BibTeX 文件，或通过 DOI 添加文献。" : "换一个标题、作者、来源、年份或 DOI 试试。"
                )
            } else {
                Table(papers, selection: $selection) {
                    TableColumn("标题") { paper in
                        PaperTitleCell(paper: paper)
                            .onDrag {
                                NSItemProvider(object: dragPayload(for: paper) as NSString)
                            }
                    }
                    .width(min: 240, ideal: 360)

                    TableColumn("作者") { paper in
                        Text(paper.authorsDisplay)
                            .lineLimit(1)
                            .foregroundStyle(paper.authors.isEmpty ? .secondary : .primary)
                    }
                    .width(min: 140, ideal: 220)

                    TableColumn("年份") { paper in
                        Text(paper.year.map(String.init) ?? "")
                            .foregroundStyle(.secondary)
                    }
                    .width(min: 52, ideal: 64, max: 80)

                    TableColumn("来源") { paper in
                        Text(paper.sourceDisplay)
                            .lineLimit(1)
                            .foregroundStyle(.secondary)
                    }
                    .width(min: 120, ideal: 180)

                    TableColumn("评分") { paper in
                        RatingDisplay(rating: paper.rating)
                    }
                    .width(min: 68, ideal: 80, max: 96)

                    TableColumn("添加日期") { paper in
                        Text(Self.dateFormatter.string(from: paper.dateAdded))
                            .foregroundStyle(.secondary)
                    }
                    .width(min: 92, ideal: 110, max: 130)

                    TableColumn("备注") { paper in
                        Text(remarkPreview(for: paper))
                            .lineLimit(1)
                            .foregroundStyle(.secondary)
                    }
                    .width(min: 140, ideal: 220)
                }
                .contextMenu {
                    Button("打开 PDF") { onOpenSelected() }
                        .disabled(selection.isEmpty)
                    Button("在 Finder 中显示") { onRevealSelected() }
                        .disabled(selection.isEmpty)
                    Divider()
                    Button("删除记录", role: .destructive) { onDeleteSelected() }
                        .disabled(selection.isEmpty)
                }
            }
        }
        .onDrop(of: [UTType.fileURL.identifier], isTargeted: nil, perform: importDroppedItems)
        .safeAreaInset(edge: .bottom) {
            footer
        }
    }

    private var footer: some View {
        HStack {
            Text("\(papers.count) 篇文献")
            if !selection.isEmpty {
                Text("已选择 \(selection.count) 篇")
            }
            Spacer()
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal)
        .padding(.vertical, 5)
        .background(.bar)
    }

    private func dragPayload(for paper: Paper) -> String {
        let ids = selection.contains(paper.id) && !selection.isEmpty ? selection : [paper.id]
        return "papermanager-paper-ids:" + ids.map(\.uuidString).joined(separator: ",")
    }

    private func remarkPreview(for paper: Paper) -> String {
        if let notes = paper.notes.nilIfBlank {
            return notes.replacingOccurrences(of: "\n", with: " ")
        }
        if let abstract = paper.abstract.nilIfBlank {
            return abstract.replacingOccurrences(of: "\n", with: " ")
        }
        return ""
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy/M/d"
        return formatter
    }()

    private func importDroppedItems(_ providers: [NSItemProvider]) -> Bool {
        var didFindFileURL = false
        for provider in providers where provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
            didFindFileURL = true
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                let url: URL?
                if let fileURL = item as? URL {
                    url = fileURL
                } else if let data = item as? Data {
                    url = URL(dataRepresentation: data, relativeTo: nil)
                } else {
                    url = nil
                }

                if let url {
                    DispatchQueue.main.async {
                        onImportURLs([url])
                    }
                }
            }
        }
        return didFindFileURL
    }
}

private struct PaperTitleCell: View {
    let paper: Paper

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: "chevron.right")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 12)
            Image(systemName: paper.hasPDF ? "doc.richtext" : "doc.text")
                .foregroundStyle(.secondary)
                .frame(width: 16)
            Text(paper.displayTitle)
                .fontWeight(.semibold)
                .lineLimit(1)
        }
    }
}
