import Quartz

/// Drives the shared Quick Look panel. Previews zoom out of the thumbnail that was clicked,
/// and the arrow keys step through every photo and video in the conversation.
final class Preview: NSObject, QLPreviewPanelDataSource, QLPreviewPanelDelegate {
    static let shared = Preview()

    /// Media in the open conversation, oldest first. Setting it lets go of other chats' thumbnails.
    var urls: [URL] = [] {
        didSet {
            let keep = Set(urls)
            frames = frames.filter { keep.contains($0.key) }
            images = images.filter { keep.contains($0.key) }
        }
    }
    /// Where each thumbnail sits in the panel's "panel" coordinate space, which is `host`'s bounds.
    var frames: [URL: CGRect] = [:]
    var images: [URL: NSImage] = [:]
    weak var host: NSView?
    private var start = 0

    func toggle(_ url: URL) {
        guard let panel = QLPreviewPanel.shared() else { return }
        if panel.isVisible { return panel.orderOut(nil) }
        guard let i = urls.firstIndex(of: url) else { return }  // a send on its way isn't in the thread yet
        start = i
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
