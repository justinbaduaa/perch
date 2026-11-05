import Quartz

/// Drives the shared Quick Look panel. Previews zoom out of the thumbnail that was clicked,
/// and the arrow keys step through every photo and video in the conversation.
final class Preview: NSObject, QLPreviewPanelDataSource, QLPreviewPanelDelegate {
    static let shared = Preview()

    /// Media in the open conversation, oldest first.
    var urls: [URL] = []
    /// Where each thumbnail sits, in SwiftUI global space of `window` (top-left origin).
    var frames: [URL: CGRect] = [:]
    var images: [URL: NSImage] = [:]
    weak var window: NSWindow?
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
        guard let window, let url = item.previewItemURL, let r = frames[url] else { return .zero }
        return NSRect(x: window.frame.minX + r.minX, y: window.frame.maxY - r.maxY, width: r.width, height: r.height)
    }

    func previewPanel(_ panel: QLPreviewPanel!, transitionImageFor item: (any QLPreviewItem)!,
                      contentRect: UnsafeMutablePointer<NSRect>!) -> Any! {
        item.previewItemURL.flatMap { images[$0] }
    }
}
