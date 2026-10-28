import SwiftUI

struct PaperPDFPreview<Title: View>: View {
    let attachment: Attachment
    @ViewBuilder var title: Title
    @State private var pageIndex = 0
    @State private var pageCount = 0
    @State private var image: NSImage?
    @State private var error: String?
    @State private var loading = true

    private struct Request: Hashable { let attachment: Attachment; let page: Int }

    var body: some View {
        VStack(spacing: 7) {
            InspectorTitlePreviewLayout {
                title
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                previewImage
            }
            HStack(spacing: 12) {
                Color.clear.frame(height: 1).frame(maxWidth: .infinity).accessibilityHidden(true)
                navigation.frame(maxWidth: .infinity)
            }
        }
        .frame(maxWidth: .infinity)
        .task(id: Request(attachment: attachment, page: pageIndex)) {
            loading = true; error = nil; image = nil
            let request = Request(attachment: attachment, page: pageIndex)
            let result = await Task.detached(priority: .userInitiated) {
                Result { try PDFPreviewService.render(request.attachment, pageIndex: request.page) }
            }.value
            guard !Task.isCancelled else { return }
            switch result {
            case .success(let preview):
                image = preview.image; pageCount = preview.pageCount; pageIndex = preview.pageIndex
            case .failure(let failure):
                error = failure.localizedDescription; pageCount = 0
            }
            loading = false
        }
    }

    private var previewImage: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 5).fill(Color(nsColor: .controlBackgroundColor))
            if let image {
                Image(nsImage: image).resizable().scaledToFit().padding(3)
            } else if let error {
                Image(systemName: "doc.questionmark").foregroundStyle(.secondary).help(error)
            } else { ProgressView().controlSize(.small) }
        }
        .frame(minHeight: 142, maxHeight: .infinity)
        .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(.quaternary))
        .accessibilityLabel(PMLocalization.text("PDF 页面预览"))
    }

    private var navigation: some View {
        HStack(spacing: 6) {
            Button { pageIndex -= 1 } label: { Image(systemName: "chevron.left") }
                .disabled(loading || pageIndex <= 0)
                .help("上一页").accessibilityLabel("上一页")
                .accessibilityIdentifier("pdf-preview-previous")
            Text(pageCount > 0 ? "\(pageIndex + 1) / \(pageCount)" : "—")
                .font(.system(size: 9).monospacedDigit()).foregroundStyle(.secondary)
                .fixedSize()
            Button { pageIndex += 1 } label: { Image(systemName: "chevron.right") }
                .disabled(loading || pageIndex + 1 >= pageCount)
                .help("下一页").accessibilityLabel("下一页")
                .accessibilityIdentifier("pdf-preview-next")
        }
        .buttonStyle(.bordered).controlSize(.mini)
    }

}

/// Equal columns and a shared height, expanding for a long title without truncation.
/// Authors and citekey are deliberately outside this two-component layout.
struct InspectorTitlePreviewLayout: Layout {
    var spacing: CGFloat = 12

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 280
        let columnWidth = max(0, (width - spacing) / 2)
        let contentHeight = subviews.map {
            $0.sizeThatFits(ProposedViewSize(width: columnWidth, height: nil)).height
        }.max() ?? 0
        return CGSize(width: width, height: max(columnWidth * 1.27, contentHeight))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let columnWidth = max(0, (bounds.width - spacing) / 2)
        for (index, view) in subviews.enumerated() {
            view.place(at: CGPoint(x: bounds.minX + CGFloat(index) * (columnWidth + spacing), y: bounds.minY),
                       anchor: .topLeading,
                       proposal: ProposedViewSize(width: columnWidth, height: bounds.height))
        }
    }
}
