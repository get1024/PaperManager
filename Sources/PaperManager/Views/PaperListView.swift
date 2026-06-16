import SwiftUI

struct PaperListView: View {
    let title: String
    let papers: [Paper]
    @Binding var selection: Set<UUID>
    @Binding var searchText: String
    var onOpenSelected: () -> Void
    var onRevealSelected: () -> Void
    var onDeleteSelected: () -> Void

    var body: some View {
        Group {
            if papers.isEmpty {
                PaperManagerEmptyState(
                    systemImage: searchText.isEmpty ? "doc.text" : "magnifyingglass",
                    title: searchText.isEmpty ? "暂无文献" : "没有结果",
                    message: searchText.isEmpty ? "导入 PDF、BibTeX 文件，或通过 DOI、arXiv、ISBN 添加文献。" : "换一个标题、作者、期刊、年份或 citekey 试试。"
                )
            } else {
                Table(papers, selection: $selection) {
                    TableColumn("Title") { paper in
                        PaperTitleCell(paper: paper)
                    }
                    .width(min: 240, ideal: 360)

                    TableColumn("Authors") { paper in
                        Text(paper.authorsDisplay)
                            .lineLimit(1)
                            .foregroundStyle(paper.authors.isEmpty ? .secondary : .primary)
                    }
                    .width(min: 140, ideal: 220)

                    TableColumn("Year") { paper in
                        Text(paper.year.map(String.init) ?? "")
                            .foregroundStyle(.secondary)
                    }
                    .width(min: 52, ideal: 64, max: 80)

                    TableColumn("Source") { paper in
                        Text(paper.sourceDisplay)
                            .lineLimit(1)
                            .foregroundStyle(.secondary)
                    }
                    .width(min: 120, ideal: 180)

                    TableColumn("DOI") { paper in
                        Text(paper.doi)
                            .lineLimit(1)
                            .foregroundStyle(paper.doi.isEmpty ? .secondary : .primary)
                    }
                    .width(min: 120, ideal: 180)

                    TableColumn("Rating") { paper in
                        RatingDisplay(rating: paper.rating)
                    }
                    .width(min: 68, ideal: 80, max: 96)

                    TableColumn("Added") { paper in
                        Text(paper.dateAdded, format: .dateTime.year().month().day())
                            .foregroundStyle(.secondary)
                    }
                    .width(min: 92, ideal: 110, max: 130)
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
}

private struct PaperTitleCell: View {
    let paper: Paper

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: paper.hasPDF ? "doc.richtext" : "doc.text")
                .foregroundStyle(.secondary)
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 2) {
                Text(paper.displayTitle)
                    .lineLimit(1)
                if !paper.citekey.isEmpty {
                    Text(paper.citekey)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
        }
    }
}
