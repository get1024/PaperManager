import SwiftUI

struct PaperPDFPreview: View {
    let attachment: Attachment
    @Binding var pageIndex: Int
    @Binding var pageCount: Int
    @State private var image: NSImage?
    @State private var error: String?
    @State private var loading = true

    private struct Request: Hashable { let attachment: Attachment; let page: Int }

    var body: some View {
        VStack(spacing: 7) {
            ZStack {
                RoundedRectangle(cornerRadius: 5).fill(Color(nsColor: .controlBackgroundColor))
                if let image {
                    Image(nsImage: image).resizable().scaledToFit().padding(3)
                } else if let error {
                    Image(systemName: "doc.questionmark").foregroundStyle(.secondary).help(error)
                } else { ProgressView().controlSize(.small) }
            }
            .frame(height: 142)
            .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(.quaternary))
            .accessibilityLabel(PMLocalization.text("PDF 页面预览"))
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
        .frame(width: 112)
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
}

struct PaperReadingView: View {
    @ObservedObject var store: LibraryStore
    @ObservedObject var session: ReadingSessionService
    let paperID: UUID
    let previewPage: Int
    let pageCount: Int
    @State private var error: String?
    @State private var pendingProgress: Double?

    private var record: ReadingRecord { store.paper(with: paperID)?.reading ?? ReadingRecord() }
    private var isRunning: Bool { session.activePaperID == paperID }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("阅读").font(.system(size: 10, weight: .bold)).foregroundStyle(.secondary)
                Spacer()
                Text(record.durationText).font(.system(size: 11).monospacedDigit())
                    .accessibilityLabel("论文阅读时间").accessibilityValue(record.durationText)
                Button(isRunning ? "暂停计时" : "开始计时") {
                    if isRunning { session.pause() } else { session.start(paperID) }
                }
                .controlSize(.small).accessibilityIdentifier("reading-toggle")
            }
            if let active = session.activePaperID, active != paperID {
                Text(PMLocalization.format("正在计时：%@", store.paper(with: active)?.displayTitle ?? ""))
                    .font(.caption).foregroundStyle(.secondary).lineLimit(2)
                Button("暂停计时") { session.pause() }.controlSize(.small)
            }
            HStack {
                Text("阅读进度").font(.caption)
                Slider(value: Binding(get: { record.progress }, set: { setProgress($0) }), in: 0...1, step: 0.01)
                    .accessibilityLabel("阅读进度").accessibilityIdentifier("reading-progress")
                Text("\(Int(record.progress * 100))%").font(.caption.monospacedDigit()).frame(width: 33)
            }
            if pageCount > 0 {
                Button("标记已读至当前预览页") { setProgress(Double(previewPage + 1) / Double(pageCount)) }
                    .controlSize(.small).accessibilityIdentifier("reading-mark-page")
            }
            Text("手动计时，可在外部阅读器阅读；结束后请暂停。进度由你确认，预览翻页不计入。休眠时自动暂停。")
                .font(.system(size: 10)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if let message = error ?? session.errorMessage {
                Text(message).font(.caption).foregroundStyle(.red)
                Button("重试保存") {
                    if let pendingProgress { setProgress(pendingProgress) } else { session.pause() }
                }.controlSize(.small)
            }
        }
        .padding(.vertical, 3)
    }

    private func setProgress(_ value: Double) {
        do { try store.updateReading(paperID) { $0.setProgress(value) }; error = nil; pendingProgress = nil }
        catch { self.error = error.localizedDescription; pendingProgress = value }
    }
}
