import SwiftUI

struct PaperListView: View {
    let title: String
    let papers: [Paper]
    @Binding var selection: Set<UUID>
    @Binding var searchText: String

    var body: some View {
        VStack(spacing: 0) {
            header

            if papers.isEmpty {
                LatticeEmptyState(
                    systemImage: searchText.isEmpty ? "doc.text" : "magnifyingglass",
                    title: searchText.isEmpty ? "暂无文献" : "没有结果",
                    message: searchText.isEmpty ? "导入 PDF、BibTeX 文件，或通过 DOI 添加文献。" : "换一个标题、作者、期刊、年份或 citekey 试试。"
                )
            } else {
                List(papers, selection: $selection) { paper in
                    PaperRowView(paper: paper)
                        .tag(paper.id)
                        .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 4, trailing: 16))
                        .listRowSeparator(.hidden)
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
            }

            footer
        }
        .background(LatticeStyle.contentBackground)
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title)
                .font(.title3)
                .fontWeight(.bold)
                .lineLimit(1)

            Spacer()

            if !searchText.trimmed.isEmpty {
                Button {
                    searchText = ""
                } label: {
                    Label("清除搜索", systemImage: "xmark.circle.fill")
                        .labelStyle(.iconOnly)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("清除搜索")
            }
        }
        .padding(.top, 22)
        .padding(.horizontal, 24)
        .padding(.bottom, 14)
    }

    private var footer: some View {
        HStack(spacing: 8) {
            Text("\(papers.count) 篇文献")
            if !selection.isEmpty {
                Text("-")
                Text("已选择 \(selection.count) 篇")
            }
            Spacer()
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(.bar)
    }
}

private struct PaperRowView: View {
    let paper: Paper

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: paper.hasPDF ? "doc.richtext" : "doc.text")
                .font(.system(size: 19, weight: .regular))
                .foregroundStyle(paper.hasPDF ? Color.accentColor : Color.secondary)
                .frame(width: 28, height: 34)

            VStack(alignment: .leading, spacing: 6) {
                Text(paper.displayTitle)
                    .font(.callout)
                    .fontWeight(.semibold)
                    .lineLimit(2)

                HStack(spacing: 8) {
                    Text(paper.authorsDisplay)
                        .lineLimit(1)

                    if let year = paper.year {
                        Text("\(year)")
                    }

                    if !paper.sourceDisplay.isEmpty {
                        Text(paper.sourceDisplay)
                            .lineLimit(1)
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)

                HStack(spacing: 6) {
                    if !paper.citekey.isEmpty {
                        pill(paper.citekey, systemImage: "number")
                    }
                    if !paper.doi.isEmpty {
                        pill("DOI", systemImage: "link")
                    }
                    if paper.hasPDF {
                        pill("PDF", systemImage: "paperclip")
                    }
                    if paper.rating > 0 {
                        RatingDisplay(rating: paper.rating)
                            .font(.caption2)
                    }
                }
            }

            Spacer(minLength: 8)
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.primary.opacity(0.035))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(LatticeStyle.separator, lineWidth: 0.5)
        )
    }

    private func pill(_ text: String, systemImage: String) -> some View {
        HStack(spacing: 4) {
            Image(systemName: systemImage)
            Text(text)
                .lineLimit(1)
        }
        .font(.caption2)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(
            Capsule()
                .fill(Color.primary.opacity(0.055))
        )
    }
}
