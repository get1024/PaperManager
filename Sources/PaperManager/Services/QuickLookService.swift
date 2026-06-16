import Foundation
import Quartz

final class QuickLookService: NSObject, QLPreviewPanelDataSource, QLPreviewPanelDelegate {
    static let shared = QuickLookService()

    private var previewURL: URL?
    private var didAccessSecurityScope = false

    func preview(url: URL) {
        stopAccessingPreviewURL()
        previewURL = url
        didAccessSecurityScope = url.startAccessingSecurityScopedResource()
        guard let panel = QLPreviewPanel.shared() else { return }
        panel.dataSource = self
        panel.delegate = self
        panel.reloadData()
        panel.makeKeyAndOrderFront(nil)
    }

    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int {
        previewURL == nil ? 0 : 1
    }

    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> QLPreviewItem! {
        previewURL as NSURL?
    }

    func previewPanelWillClose(_ panel: QLPreviewPanel!) {
        stopAccessingPreviewURL()
    }

    private func stopAccessingPreviewURL() {
        if didAccessSecurityScope {
            previewURL?.stopAccessingSecurityScopedResource()
        }
        didAccessSecurityScope = false
    }
}
