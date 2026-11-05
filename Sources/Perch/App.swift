import AppKit
import Quartz
import SwiftUI

/// SwiftUI owns the lifecycle so the app gets a standard main menu (Cmd-C/V/Q work in the panel).
@main struct PerchApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    var body: some Scene { Settings { EmptyView() } }
}

/// Clicking an avatar in the strip shows its name in a pill, which grows into a glass panel with the conversation.
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let store = Store()
    private lazy var strip = AvatarStrip(store: store)
    private lazy var panel = makePanel()
    private let pill = AppDelegate.floatingPanel()
    private var mouseDownAt = NSPoint.zero
    private static let width: CGFloat = 340, height: CGFloat = 540
    /// Clear room around the glass for its own shadow, which the window edge would otherwise cut square.
    private static let margin: CGFloat = 24

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        guard let button = strip.item.button else { return }
        button.target = self
        button.action = #selector(clicked)
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        pill.ignoresMouseEvents = true
        store.onChange = { [unowned self] in strip.update() }
        store.showPanel = { [unowned self] chat in if !store.panelShown || store.panelChat?.id != chat.id { show(chat) } }
        store.hidePanel = { [unowned self] in hidePanel() }
        store.start()
        strip.update()

        // The status button is drawn outside this process, so tracking areas on it never fire; watch the pointer instead.
        NSEvent.addGlobalMonitorForEvents(matching: .mouseMoved) { [unowned self] _ in pointerMoved() }
        NSEvent.addLocalMonitorForEvents(matching: .mouseMoved) { [unowned self] event in pointerMoved(); return event }

        // Close on a click elsewhere, but not on a drag: dragging files in from Finder is how you drop them.
        // Clicks on the strip arrive here too (another process draws it); `clicked` handles those.
        NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .leftMouseUp, .rightMouseDown]) { [unowned self] event in
            let at = NSEvent.mouseLocation
            guard !strip.rect.contains(at) else { return }
            switch event.type {
            case .leftMouseDown: mouseDownAt = at
            case .leftMouseUp where hypot(at.x - mouseDownAt.x, at.y - mouseDownAt.y) < 4: hidePanel()
            case .rightMouseDown: hidePanel()
            default: break
            }
        }
    }

    /// A screen capture outlives the app otherwise, recording with nothing in Perch to stop it.
    func applicationWillTerminate(_ notification: Notification) { store.recorder.discard() }

    /// Parts the strip around the hovered avatar; with the panel open, its composer says "Switch to …".
    private func pointerMoved() {
        guard strip.pointerMoved() else { return }
        store.hoverChat = strip.hovered.flatMap { $0 < strip.bar.count ? strip.bar[$0] : nil }
    }

    @objc private func clicked() {
        guard let button = strip.item.button else { return }
        if NSApp.currentEvent?.type == .rightMouseUp {
            let menu = NSMenu()
            menu.addItem(withTitle: "Quit Perch", action: #selector(NSApplication.terminate), keyEquivalent: "q")
            menu.popUp(positioning: nil, at: NSPoint(x: 0, y: button.bounds.maxY + 4), in: button)
            return
        }
        let slot = strip.slot(at: NSEvent.mouseLocation) ?? 0  // VoiceOver presses have no pointer over the strip
        if slot == strip.moreSlot { return showOthers(under: slot) }
        guard slot < strip.bar.count else { return show(nil) }
        let chat = strip.bar[slot]
        if store.panelShown && store.panelChat?.id == chat.id { return hidePanel() }
        show(chat)
    }

    /// "•••": every recent chat that isn't in the bar.
    private func showOthers(under slot: Int) {
        guard let button = strip.item.button else { return }
        let menu = NSMenu()
        let barIDs = Set(strip.bar.map(\.id))
        for chat in store.chats.filter({ !barIDs.contains($0.id) }).prefix(15) {
            let entry = menu.addItem(withTitle: store.name(chat), action: #selector(pickOther), keyEquivalent: "")
            entry.target = self
            entry.representedObject = chat
            let avatar = ImageRenderer(content: Avatar(image: store.photo(chat), name: store.name(chat), size: 18))
            avatar.scale = 2
            entry.image = avatar.nsImage
        }
        let x = strip.anchor(under: slot).x - strip.rect.minX + (button.bounds.width - strip.rect.width) / 2
        menu.popUp(positioning: nil, at: NSPoint(x: x - 10, y: button.bounds.maxY + 4), in: button)
    }

    @objc private func pickOther(_ sender: NSMenuItem) { show(sender.representedObject as? Chat) }

    // MARK: Panel

    /// Grows the panel out of a name pill under the chat's slot, or slides it over when already open.
    private func show(_ chat: Chat?) {
        NSApp.activate()
        if store.panelShown {
            withAnimation(.smooth(duration: 0.3)) { store.panelChat = chat }
            strip.update()
            let target = frame(for: chat)
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.3
                panel.animator().setFrame(Self.padded(target), display: true)
            }
            return panel.makeKey()
        }
        store.panelChat = chat
        let target = frame(for: chat)
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            store.panelShown = true
            strip.update()
            panel.setFrame(Self.padded(target), display: true)
            panel.alphaValue = 1
            return panel.makeKeyAndOrderFront(nil)
        }
        let start = showPill(chat.map(store.name) ?? "Perch", at: strip.anchor(under: chat.flatMap(strip.slot) ?? 0))
        Task {
            try? await Task.sleep(for: .milliseconds(80))  // the pill holds a beat, then grows into the panel
            panel.setFrame(Self.padded(start), display: false)
            panel.alphaValue = 0
            panel.makeKeyAndOrderFront(nil)
            withAnimation(.smooth(duration: 0.3)) { store.panelShown = true }
            strip.update()
            await NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.28  // opened dozens of times a day: keep it under 300ms, strong ease-out
                ctx.timingFunction = CAMediaTimingFunction(controlPoints: 0.23, 1, 0.32, 1)
                panel.animator().setFrame(Self.padded(target), display: true)
                panel.animator().alphaValue = 1
                pill.animator().alphaValue = 0
            }
            pill.orderOut(nil)
        }
    }

    private static func padded(_ glass: NSRect) -> NSRect { glass.insetBy(dx: -margin, dy: -margin) }

    /// `content` on glass, inset in a clear view so the glass's shadow has room inside the window.
    private static func glassBox(_ content: NSView, size: NSSize, radius: CGFloat) -> NSView {
        let box = NSView(frame: padded(NSRect(origin: .zero, size: size)).offsetBy(dx: margin, dy: margin))
        let glass = NSGlassEffectView(frame: NSRect(x: margin, y: margin, width: size.width, height: size.height))
        glass.cornerRadius = radius
        glass.autoresizingMask = [.width, .height]
        glass.contentView = content
        box.addSubview(glass)
        return box
    }

    /// The panel's glass at rest: centred under the chat's slot, kept on screen.
    private func frame(for chat: Chat?) -> NSRect {
        let at = strip.anchor(under: chat.flatMap(strip.slot) ?? 0)
        let screen = strip.item.button?.window?.screen?.visibleFrame ?? .infinite
        let x = min(max(at.x - Self.width / 2, screen.minX + 8), screen.maxX - Self.width - 8)
        return NSRect(x: x, y: at.y - Self.height, width: Self.width, height: Self.height)
    }

    /// The name in a glass capsule under the menu bar. Returns its frame, which the panel grows from.
    private func showPill(_ name: String, at: NSPoint) -> NSRect {
        let label = NSHostingView(rootView: Text(name).font(.callout.weight(.semibold)).lineLimit(1)
            .padding(.horizontal, 12).padding(.vertical, 6).fixedSize())
        let size = label.fittingSize
        pill.contentView = Self.glassBox(label, size: size, radius: size.height / 2)
        let frame = NSRect(x: at.x - size.width / 2, y: at.y - size.height, width: size.width, height: size.height)
        pill.setFrame(Self.padded(frame), display: true)
        pill.alphaValue = 1
        pill.orderFront(nil)
        return frame
    }

    /// Blurs the content out while the window shrinks back toward the menu bar.
    private func hidePanel() {
        guard store.panelShown else { return }
        nowPlaying?.stop()
        withAnimation(.smooth(duration: 0.18)) { store.panelShown = false }
        strip.update()
        let f = panel.frame.insetBy(dx: Self.margin, dy: Self.margin)
        let end = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? f : NSRect(x: f.midX - 60, y: f.maxY - 30, width: 120, height: 30)
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.18
            panel.animator().setFrame(Self.padded(end), display: true)
            panel.animator().alphaValue = 0
        }
        Task {
            try? await Task.sleep(for: .milliseconds(200))
            if !store.panelShown { panel.orderOut(nil); pill.orderOut(nil) }  // unless reopened mid-animation
        }
    }

    /// A 1:1 chat opens on its thread. Messages has no public link to a group thread, so a group opens the app.
    private func openInMessages() {
        hidePanel()
        let handles = store.panelChat?.handles ?? []
        let thread = handles.count == 1 ? URL(string: "sms:\(handles[0])") : nil
        NSWorkspace.shared.open(thread ?? URL(filePath: "/System/Applications/Messages.app"))
    }

    private func makePanel() -> NSPanel {
        let panel = Self.floatingPanel()
        let host = NSHostingView(rootView: PanelRoot(
            store: store,
            openInMessages: { [unowned self] in openInMessages() },
            close: { [unowned self] in hidePanel() }))
        host.sizingOptions = []
        // The glass pins its contentView edge to edge, so that is a bare container with no size of its own; the
        // panel inside keeps full size, pinned top-centre, and is revealed as the window grows out of the pill.
        let bounds = NSRect(x: 0, y: 0, width: Self.width, height: Self.height)
        let container = NSView(frame: bounds)
        host.frame = bounds
        host.autoresizingMask = [.minXMargin, .maxXMargin, .minYMargin]
        container.addSubview(host)
        panel.contentView = Self.glassBox(container, size: bounds.size, radius: 26)
        Preview.shared.host = host
        return panel
    }

    /// Borderless, clear, above Finder (so files can be dragged in), on every Space.
    private static func floatingPanel() -> KeyablePanel {
        let panel = KeyablePanel(contentRect: NSRect(x: 0, y: 0, width: width, height: height),
                                 styleMask: [.borderless], backing: .buffered, defer: true)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false  // the window shadow and border follow the square frame, not the glass's rounded shape
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        return panel
    }
}

/// Borderless panels refuse key status by default, which would block typing.
/// It also takes control of Quick Look, so previews know which thumbnail they zoom out of.
final class KeyablePanel: NSPanel {
    override var canBecomeKey: Bool { true }
    nonisolated override func acceptsPreviewPanelControl(_ panel: QLPreviewPanel!) -> Bool { true }
    nonisolated override func beginPreviewPanelControl(_ panel: QLPreviewPanel!) {
        MainActor.assumeIsolated { Preview.shared.begin(panel) }
    }
    nonisolated override func endPreviewPanelControl(_ panel: QLPreviewPanel!) {}
}
