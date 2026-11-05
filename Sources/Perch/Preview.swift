import Quartz

/// Drives the shared Quick Look panel. Previews zoom out of the thumbnail that was clicked,
/// and the arrow keys step through every photo and video in the conversation.
final class Preview: NSObject, QLPreviewPanelDataSource, QLPreviewPanelDelegate {
    static let shared = Preview()

    /// Media in the open conversation, oldest first.
    var urls: [URL] = []
    /// Where each thumbnail sits in the panel's "panel" coordinate space, which is `host`'s bounds.
    var frames: [URL: CGRect] = [:]
    var images: [URL: NSImage] = [:]
    weak var host: NSView?
    private var start = 0

    func toggle(_ url: URL) {
        guard let panel = QLPreviewPanel.shared() else { return }
        if panel.isVisible { return panel.orderOut(nil) }
        start = urls.firstIndex(of: url) ?? 0
        panel.makeKeyAndOrderFront(nil)  // asks the responder chain for a controller, see KeyablePanel
    }

    /// Called when Quick Look takes us on as its controller.
    func begin(_ panel: QLPreviewPanel) {
        panel.dataSource = self
        panel.delegate = self
        panel.currentPreviewItemIndex = start
    }

    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int { urls.count }

    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> (any QLPreviewItem)! { urls[index] as NSURL }

    func previewPanel(_ panel: QLPreviewPanel!, sourceFrameOnScreenFor item: (any QLPreviewItem)!) -> NSRect {
        guard let host, let window = host.window, let url = item.previewItemURL, let r = frames[url] else { return .zero }
        return window.convertToScreen(host.convert(r, to: nil))  // the hosting view is flipped, like SwiftUI
    }

    func previewPanel(_ panel: QLPreviewPanel!, transitionImageFor item: (any QLPreviewItem)!,
                      contentRect: UnsafeMutablePointer<NSRect>!) -> Any! {
        item.previewItemURL.flatMap { images[$0] }
    }
}
