import AppKit
import SwiftUI

/// Dragging files near the menu bar drops a glass pill under the nearest face, "Drop to Ashley", which follows the
/// pointer from face to face. Dropping there puts the files in that chat's message box and opens it.
///
/// A drag belongs to the app it started in, so Perch watches for it with a global monitor, then puts up a window
/// over the strip and the room under it to take the drop. The window is up only while a file drag is near.
final class DropZone: NSPanel {
    /// The bar slot the pill is under, as the pointer moves; nil when it leaves.
    var onTarget: (Int?) -> Void = { _ in }
    var onDrop: (Int, [URL]) -> Void = { _, _ in }

    private let strip: AvatarStrip
    private let store: Store
    private let target = Target()
    private let pill = NSGlassEffectView()
    private let label = NSHostingView(rootView: DropPill(name: "", pointer: nil))
    private var slot: Int?
    /// The drag pasteboard's count at the last press. A drag that starts after it writes there; one left from an
    /// earlier drag doesn't count.
    private var pressCount = 0
    private var watch: Task<Void, Never>?

    static let pillSize = NSSize(width: 300, height: 110)
    /// How far below the menu bar a drag still counts as near the faces.
    private static let reach: CGFloat = pillSize.height + 30

    init(strip: AvatarStrip, store: Store) {
        self.strip = strip
        self.store = store
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        isOpaque = false
        backgroundColor = NSColor(white: 0, alpha: 0.004)  // clear, but solid enough for the window to take the drag
        hasShadow = false
        level = NSWindow.Level(NSWindow.Level.statusBar.rawValue + 2)  // over the spread strip
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        animationBehavior = .none
        pill.cornerRadius = 26
        pill.tintColor = .black.withAlphaComponent(0.3)  // the panel's shade
        pill.contentView = label
        pill.alphaValue = 0
        target.addSubview(pill)
        target.registerForDraggedTypes([.fileURL])
        target.zone = self
        contentView = target
    }

    required init?(coder: NSCoder) { fatalError("not used from nibs") }

    func pressed() { pressCount = NSPasteboard(name: .drag).changeCount }

    /// From the global drag monitor: comes up once a file drag started since the last press is near the faces.
    func dragged() {
        guard !isVisible, !store.barChats.isEmpty else { return }
        let drag = NSPasteboard(name: .drag)
        guard drag.changeCount != pressCount, drag.canReadObject(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]),
              area.contains(NSEvent.mouseLocation) else { return }
        setFrame(area, display: false)
        orderFrontRegardless()
        // Ends with the drag, wherever it's let go: a drop elsewhere sends this window nothing.
        watch = Task {
            while NSEvent.pressedMouseButtons & 1 != 0, !Task.isCancelled { try? await Task.sleep(for: .milliseconds(100)) }
            if !Task.isCancelled { dismiss() }
        }
    }

    /// The strip and the room under it, wide enough for the pill under either end.
    private var area: NSRect {
        let r = strip.rect, w = r.width + Self.pillSize.width + 40
        return NSRect(x: r.midX - w / 2, y: r.minY - Self.reach, width: w, height: r.height + Self.reach)
    }

    func dismiss() {
        watch?.cancel()
        watch = nil
        aim(nil, at: nil)
        orderOut(nil)
    }

    /// Moves the pill under the face nearest `point`, or hides it.
    fileprivate func aim(at point: NSPoint?) {
        guard let point else { return aim(nil, at: nil) }
        let count = store.barChats.count
        let nearest = (0..<count).min { abs(strip.anchor(under: $0).x - point.x) < abs(strip.anchor(under: $1).x - point.x) }
        aim(nearest, at: point)
    }

    private func aim(_ new: Int?, at point: NSPoint?) {
        let bar = store.barChats
        if let new, new < bar.count {
            let anchor = strip.anchor(under: new), size = Self.pillSize
            let screen = (screen ?? NSScreen.main)?.visibleFrame ?? .infinite
            let x = min(max(anchor.x - size.width / 2, screen.minX + 8), screen.maxX - size.width - 8)
            let local = NSRect(origin: convertFromScreen(NSRect(x: x, y: anchor.y - size.height, width: 0, height: 0)).origin, size: size)
            label.rootView = DropPill(name: store.shortName(bar[new]), pointer: point.map { convertFromScreen(NSRect(origin: $0, size: .zero)).origin }
                .map { NSPoint(x: $0.x - local.minX, y: local.maxY - $0.y) })  // pill coordinates, y down
            if new != slot {
                let reduce = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
                NSAnimationContext.runAnimationGroup { ctx in
                    ctx.duration = slot == nil || reduce ? 0 : 0.2
                    ctx.timingFunction = CAMediaTimingFunction(controlPoints: 0.23, 1, 0.32, 1)
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
        let changed = new != slot
        slot = new
        if changed { onTarget(new) }
    }

    fileprivate func drop(_ urls: [URL]) -> Bool {
        guard let slot, !urls.isEmpty else { return false }
        onDrop(slot, urls)
        return true
    }

    private final class Target: NSView {
        weak var zone: DropZone?

        override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { draggingUpdated(sender) }

        override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
            zone?.aim(at: window?.convertPoint(toScreen: sender.draggingLocation))
            return .copy
        }

        override func draggingExited(_ sender: NSDraggingInfo?) { zone?.dismiss() }

        override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
            let urls = sender.draggingPasteboard.readObjects(forClasses: [NSURL.self],
                                                             options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
            let dropped = zone?.drop(urls) ?? false
            DispatchQueue.main.async { [zone] in zone?.dismiss() }  // after the drag session hears back
            return dropped
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
