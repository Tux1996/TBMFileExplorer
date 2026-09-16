import AppKit
import Quartz

/// Minimal Quick Look integration: sets the shared `QLPreviewPanel`'s data
/// source/delegate to itself and brings it forward. This is the pragmatic v1
/// version — it doesn't implement the full `QLPreviewPanelController` responder
/// chain protocol (panel state won't survive app deactivation/reactivation),
/// which is an acceptable gap for a first pass per `ROADMAP.md`.
final class QuickLookCoordinator: NSObject, QLPreviewPanelDataSource, QLPreviewPanelDelegate {
    static let shared = QuickLookCoordinator()

    private var url: URL?

    func show(_ url: URL) {
        self.url = url
        guard let panel = QLPreviewPanel.shared() else { return }
        panel.dataSource = self
        panel.delegate = self
        panel.reloadData()
        panel.makeKeyAndOrderFront(nil)
    }

    func toggle(_ url: URL) {
        if let panel = QLPreviewPanel.shared(), panel.isVisible, self.url == url {
            panel.orderOut(nil)
            return
        }
        show(url)
    }

    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int {
        url == nil ? 0 : 1
    }

    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> QLPreviewItem! {
        url as NSURL?
    }
}
