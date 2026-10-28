import SwiftUI

struct PaperPDFPreview: View {
    let attachment: Attachment
    @State private var pageIndex = 0
    @State private var pageCount = 0
    @State private var image: NSImage?
    @State private var error: String?
    @State private var loading = true

    private struct Request: Hashable { let attachment: Attachment; let page: Int }

    var body: some View {
        VStack(spacing: 9) {
            if let error {
                Label(error, systemImage: "doc.questionmark")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 8)
            } else {
                previewImage
                    .frame(width: 180, height: 234)
                navigation
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
            } else { ProgressView().controlSize(.small) }
        }
        .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(.quaternary))
        .shadow(color: .black.opacity(0.06), radius: 4, y: 2)
        .accessibilityLabel(PMLocalization.text("PDF 页面预览"))
    }

    private var navigation: some View {
        HStack(spacing: 10) {
            Button { pageIndex -= 1 } label: { Image(systemName: "chevron.left") }
                .disabled(loading || pageIndex <= 0)
                .help("上一页").accessibilityLabel("上一页")
                .accessibilityIdentifier("pdf-preview-previous")
            Text(pageCount > 0 ? "\(pageIndex + 1) / \(pageCount)" : "—")
                .font(.system(size: 10).monospacedDigit()).foregroundStyle(.secondary)
                .fixedSize()
            Button { pageIndex += 1 } label: { Image(systemName: "chevron.right") }
                .disabled(loading || pageIndex + 1 >= pageCount)
                .help("下一页").accessibilityLabel("下一页")
                .accessibilityIdentifier("pdf-preview-next")
        }
        .buttonStyle(.bordered).controlSize(.small)
    }
}
