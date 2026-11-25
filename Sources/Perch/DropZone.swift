import AppKit
import SwiftUI

/// Dragging files near the menu bar drops a glass pill under the nearest face, "Drop to Ashley", which follows the
/// pointer from face to face. Dropping there puts the files in that chat's message box and opens it.
///
/// A drag belongs to the app it started in, and macOS doesn't tell other apps where it goes. So from every press
/// until it's let go, Perch checks where the pointer is. Once a press has moved and comes near the faces, a clear
/// window goes up over the strip and the room under it. Only a real drag reaches that window, so a press that isn't
/// one (dragging a window, selecting text) shows nothing. The drag pasteboard can't tell the two apart: the Dock's
/// stacks drag without writing it.
final class DropZone: NSPanel {
    var onDrop: (Chat, [URL]) -> Void = { _, _ in }

    private let strip: AvatarStrip
    private let store: Store
    private let target = Target()
    private let pill = NSGlassEffectView()
    private let label = NSHostingView(rootView: DropPill(name: "", pointer: nil))
    private var slot: Int?
    private var watch: Task<Void, Never>?

    static let pillSize = NSSize(width: 300, height: 110)
    /// How far below the menu bar a drag still counts as near the faces.
    private static let reach: CGFloat = pillSize.height + 30
    /// Files, files another app writes on drop (Photos, Mail), and pictures (a browser's, a screenshot thumbnail's).
    fileprivate static let types: [NSPasteboard.PasteboardType] =
        [.fileURL] + (NSFilePromiseReceiver.readableDraggedTypes + NSImage.imageTypes).map { NSPasteboard.PasteboardType($0) }

    init(strip: AvatarStrip, store: Store) {
        self.strip = strip
        self.store = store
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        hidesOnDeactivate = false  // Perch is in the background whenever another app's drag comes by
        isOpaque = false
        backgroundColor = NSColor(white: 0, alpha: 0.004)  // clear, but solid enough for the window to take the drag
        hasShadow = false
        level = NSWindow.Level(NSWindow.Level.statusBar.rawValue + 2)  // over the spread strip
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        animationBehavior = .none
        pill.cornerRadius = 26
        pill.tintColor = .panelShade
        pill.contentView = label
        pill.alphaValue = 0
        target.addSubview(pill)
        target.zone = self
        contentView = target
        target.registerForDraggedTypes(Self.types)
    }

    required init?(coder: NSCoder) { fatalError("not used from nibs") }

    /// From the global monitor, on a press in another app: follows it until it's let go, 20 times a second.
    func pressed() {
        guard watch == nil else { return }
        let from = NSEvent.mouseLocation
        watch = Task {
            while NSEvent.pressedMouseButtons & 1 != 0 {
                let at = NSEvent.mouseLocation
                if !isVisible, hypot(at.x - from.x, at.y - from.y) > 4, !strip.bar.isEmpty, area.contains(at) { show() }
                try? await Task.sleep(for: .milliseconds(50))
            }
            // Let go anywhere else and this window hears nothing more, so it goes. Over a face, the drop may not have
            // arrived yet; the drag's end takes the window down then.
            if slot == nil { hide() }
            watch = nil
        }
    }

    private func show() {
        setFrame(area, display: false)
        orderFrontRegardless()
    }

    /// The strip and the room under it, wide enough for the pill under either end.
    private var area: NSRect {
        let r = strip.rect, w = r.width + Self.pillSize.width + 40
        return NSRect(x: r.midX - w / 2, y: r.minY - Self.reach, width: w, height: r.height + Self.reach)
    }

    /// Takes the window down; the press's watch puts it back if the drag comes near again.
    func hide() {
        aim(nil, at: nil)
        orderOut(nil)
    }

    /// Moves the pill under the face nearest `point`, or hides it.
    fileprivate func aim(at point: NSPoint?) {
        guard let point else { return aim(nil, at: nil) }
        let count = strip.bar.count
        let nearest = (0..<count).min { abs(strip.anchor(under: $0).x - point.x) < abs(strip.anchor(under: $1).x - point.x) }
        aim(nearest, at: point)
    }

    private func aim(_ new: Int?, at point: NSPoint?) {
        let bar = strip.bar
        if let new, new < bar.count {
            let local = convertFromScreen(strip.frame(under: new, size: Self.pillSize))
            label.rootView = DropPill(name: store.shortName(bar[new]), pointer: point.map { convertFromScreen(NSRect(origin: $0, size: .zero)).origin }
                .map { NSPoint(x: $0.x - local.minX, y: local.maxY - $0.y) })  // pill coordinates, y down
            if new != slot {
                let reduce = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
                NSAnimationContext.runAnimationGroup { ctx in
                    ctx.duration = slot == nil || reduce ? 0 : 0.2
                    ctx.timingFunction = .strongEaseOut
                    pill.animator().frame = local
                }
                if slot == nil {
                    NSAnimationContext.runAnimationGroup { ctx in
                        ctx.duration = 0.15
                        pill.animator().alphaValue = 1
                    }
                }
            }
        } else if slot != nil {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.15
                pill.animator().alphaValue = 0
            }
        }
        slot = new
        strip.dropTarget = new  // spreads the strip and rings the face
    }

    /// Files as they are, files another app writes on drop (into a fresh folder), or a picture saved as a PNG. The
    /// chat is fixed at the drop: written files can take a while, and the bar may reorder meanwhile.
    fileprivate func drop(_ drag: NSPasteboard) -> Bool {
        guard let chat = strip.chat(in: slot) else { return false }
        if let urls = drag.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL],
           !urls.isEmpty {
            onDrop(chat, urls)
            return true
        }
        if let promises = drag.readObjects(forClasses: [NSFilePromiseReceiver.self]) as? [NSFilePromiseReceiver],
           !promises.isEmpty {
            let dir = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
            guard (try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)) != nil else { return false }
            var urls: [URL] = [], left = promises.count
            for promise in promises {
                promise.receivePromisedFiles(atDestination: dir, operationQueue: .main) { [weak self] url, error in
                    MainActor.assumeIsolated {
                        if error == nil { urls.append(url) }
                        left -= 1
                        if left == 0, !urls.isEmpty { self?.onDrop(chat, urls) }
                    }
                }
            }
            return true
        }
        guard let picture = Clipboard.picture(from: drag) else { return false }
        onDrop(chat, [picture])
        return true
    }

    private final class Target: NSView {
        weak var zone: DropZone?

        override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { draggingUpdated(sender) }

        override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
            zone?.aim(at: window?.convertPoint(toScreen: sender.draggingLocation))
            return .copy
        }

        override func draggingExited(_ sender: NSDraggingInfo?) { zone?.hide() }

        override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
            let dropped = zone?.drop(sender.draggingPasteboard) ?? false
            DispatchQueue.main.async { [zone] in zone?.hide() }  // after the drag session hears back
            return dropped
        }

        override func draggingEnded(_ sender: NSDraggingInfo) {
            DispatchQueue.main.async { [zone] in zone?.hide() }
        }
    }
}

/// "Drop to Ashley" over a grid of dots that brighten around the dragged file.
struct DropPill: View {
    let name: String
    /// The pointer in the pill, y down.
    let pointer: NSPoint?

    var body: some View {
        ZStack {
            Canvas { context, size in
                let step: CGFloat = 10
                for x in stride(from: step, to: size.width, by: step) {
                    for y in stride(from: step, to: size.height, by: step) {
                        let near = pointer.map { max(0, 1 - hypot($0.x - x, $0.y - y) / 90) } ?? 0
                        context.fill(Path(ellipseIn: CGRect(x: x - 1, y: y - 1, width: 2, height: 2)),
                                     with: .color(.white.opacity(0.1 + 0.35 * near)))
                    }
                }
            }
            Text("Drop to \(name)").font(.callout.weight(.semibold)).foregroundStyle(.white)
        }
        .frame(width: DropZone.pillSize.width, height: DropZone.pillSize.height)
        .clipShape(.rect(cornerRadius: 26, style: .continuous))
    }
}
