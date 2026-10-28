import AppKit
import PDFKit

struct PDFPreviewResult {
    let image: NSImage
    let pageIndex: Int
    let pageCount: Int
}

enum PDFPreviewService {
    /// Only render one bounded thumbnail. PDF parsing stays off the UI thread.
    static func render(_ attachment: Attachment, pageIndex: Int) throws -> PDFPreviewResult {
        try attachment.withResolvedURL { url in
            guard let document = PDFDocument(url: url), !document.isLocked, document.pageCount > 0 else {
                throw PaperManagerError.message(PMLocalization.text("无法预览 PDF（文件缺失、损坏或已加密）"))
            }
            let index = min(max(0, pageIndex), document.pageCount - 1)
            guard let page = document.page(at: index) else {
                throw PaperManagerError.message(PMLocalization.text("无法读取 PDF 页面"))
            }
            return PDFPreviewResult(image: page.thumbnail(of: NSSize(width: 320, height: 440), for: .cropBox),
                                    pageIndex: index, pageCount: document.pageCount)
        }
    }
}
