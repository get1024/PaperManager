import SwiftUI

struct PaperListView: View {
    let title: String
    let papers: [Paper]
    @Binding var selection: Set<UUID>
    @Binding var searchText: String

    var body: some View {
        Group {
            if papers.isEmpty {
                PaperManagerEmptyState(
                    systemImage: searchText.isEmpty ? "doc.text" : "magnifyingglass",
                    title: searchText.isEmpty ? "暂无文献" : "没有结果",
                    message: searchText.isEmpty ? "导入 PDF、BibTeX 文件，或通过 DOI、arXiv、ISBN 添加文献。" : "换一个标题、作者、期刊、年份或 citekey 试试。"
                )
            } else {
                List(papers, selection: $selection) { paper in
                    PaperRowView(paper: paper)
                        .tag(paper.id)
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

private struct PaperRowView: View {
    let paper: Paper

    private var metadata: String {
        [
            paper.authorsDisplay,
            paper.year.map(String.init) ?? "",
            paper.sourceDisplay
        ]
        .filter { !$0.isEmpty }
        .joined(separator: " · ")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text(paper.displayTitle)
                    .lineLimit(2)
                Spacer()
                if paper.hasPDF {
                    Image(systemName: "paperclip")
                        .foregroundStyle(.secondary)
                }
            }

            if !metadata.isEmpty {
                Text(metadata)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            HStack(spacing: 8) {
                if !paper.citekey.isEmpty {
                    Text(paper.citekey)
                }
                if !paper.doi.isEmpty {
                    Text("DOI")
                }
                if paper.rating > 0 {
                    RatingDisplay(rating: paper.rating)
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 3)
    }
}
