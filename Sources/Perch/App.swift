import AppKit
import Quartz
import SwiftUI

/// SwiftUI owns the lifecycle so the app gets a standard main menu (Cmd-C/V/Q work in the panel).
@main struct PerchApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    var body: some Scene { Settings { EmptyView() } }
}

/// Clicking an avatar in the strip shows its name in a pill, which grows into a glass panel with the conversation.
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private let store = Store()
    private let permissions = Permissions()
    private var setup: NSWindow?
    private lazy var strip = AvatarStrip(store: store)
    private lazy var panel = makePanel()
    private let pill = AppDelegate.floatingPanel()
    private var mouseDownAt = NSPoint.zero
    /// Whether that press came while a modal of ours was up. The file picker is one: macOS draws it in another
    /// process, so clicks in it arrive here as clicks elsewhere.
    private var downInModal = false
    private static let width: CGFloat = 340, height: CGFloat = 540
    /// Clear room around the glass for its own shadow, which the window edge would otherwise cut square.
    private static let margin: CGFloat = 24

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        guard let button = strip.item.button else { return }
        button.target = self
        button.action = #selector(clicked)
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        strip.onClick = { [unowned self] in clicked() }
        pill.ignoresMouseEvents = true
        store.onChange = { [unowned self] in strip.update() }
        store.showPanel = { [unowned self] chat in if !store.panelShown || store.panelChat?.id != chat.id { show(chat) } }
        store.hidePanel = { [unowned self] in hidePanel() }
        store.showSetup = { [unowned self] in showSetup() }
        permissions.onContacts = { [unowned self] in
            Task {
                await store.contacts.load()
                store.onChange()
            }
        }
        store.start()
        strip.update()
        Task {
            // Nothing works without Full Disk Access, so a new Mac opens on setup. After that, until it's closed once.
            await permissions.refresh()
            let dismissed = UserDefaults.standard.bool(forKey: "setUp")
            if !permissions.granted.contains(.fullDisk) || !dismissed && !permissions.missing.isEmpty { showSetup() }
        }

        // The status button is drawn outside this process, so tracking areas on it never fire; watch the pointer instead.
        NSEvent.addGlobalMonitorForEvents(matching: .mouseMoved) { [unowned self] _ in pointerMoved() }
        NSEvent.addLocalMonitorForEvents(matching: .mouseMoved) { [unowned self] event in pointerMoved(); return event }

        // Close on a click elsewhere, but not on a drag: dragging files in from Finder is how you drop them.
        // Nor on a click in the file picker. Clicks on the strip arrive here too (another process draws it);
        // `clicked` handles those.
        NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .leftMouseUp, .rightMouseDown]) { [unowned self] event in
            let at = NSEvent.mouseLocation
            guard !strip.rect.contains(at) else { return }
            switch event.type {
            case .leftMouseDown: (mouseDownAt, downInModal) = (at, NSApp.modalWindow != nil)
            case .leftMouseUp where !downInModal && hypot(at.x - mouseDownAt.x, at.y - mouseDownAt.y) < 4: hidePanel()
            case .rightMouseDown where NSApp.modalWindow == nil: hidePanel()
            default: break
            }
        }
    }

    /// A screen capture outlives the app otherwise, recording with nothing in Perch to stop it.
    func applicationWillTerminate(_ notification: Notification) { store.recorder.discard() }

    /// Names the hovered avatar in a pill under it, which grows into the panel on click. With the panel open,
    /// its composer says "Switch to …" instead.
    private func pointerMoved() {
        guard strip.pointerMoved() else { return }
        store.hoverChat = strip.hovered.flatMap { $0 < strip.bar.count ? strip.bar[$0] : nil }
        guard !store.panelShown else { return }
        if let slot = strip.hovered { _ = showPill(label(store.hoverChat), at: strip.anchor(under: slot)) } else { pill.orderOut(nil) }
    }

    /// "Oliver · 2 hrs ago" for a chat, "Chats" for the list behind "•••".
    private func label(_ chat: Chat?) -> String {
        guard let chat else { return "Chats" }
        return "\(store.shortName(chat)) · \(chat.lastActive.formatted(.relative(presentation: .numeric, unitsStyle: .narrow)))"
    }

    @objc private func clicked() {
        guard let button = strip.item.button else { return }
        if NSApp.currentEvent?.type == .rightMouseUp {
            let menu = NSMenu()
            if let slot = strip.slot(at: NSEvent.mouseLocation), slot < strip.bar.count {
                chatMenu(strip.bar[slot]).forEach(menu.addItem)
                menu.addItem(.separator())
            }
            menu.addItem(ActionItem("Set Up Perch…") { [unowned self] in showSetup() })
            menu.addItem(withTitle: "Quit Perch", action: #selector(NSApplication.terminate), keyEquivalent: "q")
            menu.popUp(positioning: nil, at: NSPoint(x: 0, y: button.bounds.maxY + 4), in: button)
            return
        }
        let slot = strip.slot(at: NSEvent.mouseLocation) ?? 0  // VoiceOver presses have no pointer over the strip
        let chat = slot < strip.bar.count ? strip.bar[slot] : nil  // "•••" opens the searchable list of every chat
        if store.panelShown && store.panelChat?.id == chat?.id { return hidePanel() }
        show(chat, under: slot)
    }

    /// Messages' menu for a conversation, under its name. The list behind "•••" has the same one (`ChatMenu`).
    private func chatMenu(_ chat: Chat) -> [NSMenuItem] {
        store.refreshMuted()
        let store = store, unread = store.isUnread(chat), muted = store.isMuted(chat)
        return [
            .sectionHeader(title: store.name(chat)),
            ActionItem(store.pins.contains(chat.guid) ? "Unpin" : "Pin") { store.togglePin(chat) },
            .separator(),
            ActionItem(unread ? "Mark as Read" : "Mark as Unread") { store.setRead(chat, unread) },
            ActionItem(muted ? "Show Alerts" : "Hide Alerts") { store.setMuted(chat, !muted) },
            .separator(),
            ActionItem("Open in Messages") { MessagesApp.open(chat) },
            .separator(),
            ActionItem("Delete…") { store.confirmDelete(chat) },
        ]
    }

    // MARK: Setup

    /// Every grant on one screen. It floats so Perch can be dragged from it into a list in Settings.
    private func showSetup() {
        hidePanel()
        if setup == nil {
            let host = NSHostingView(rootView: SetupView(permissions: permissions) { [unowned self] in setup?.close() })
            let window = NSWindow(contentRect: NSRect(origin: .zero, size: host.fittingSize),
                                  styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false)
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
            window.isMovableByWindowBackground = true
            window.isReleasedWhenClosed = false
            window.level = .floating
            window.appearance = NSAppearance(named: .darkAqua)
            window.contentView = host
            window.delegate = self
            window.center()
            setup = window
        }
        NSApp.activate()
        setup?.makeKeyAndOrderFront(nil)
    }

    /// Closing setup, by Later, Done or its close button, stops it opening at launch while Full Disk Access is on.
    func windowWillClose(_ notification: Notification) {
        guard notification.object as? NSWindow === setup else { return }
        UserDefaults.standard.set(true, forKey: "setUp")
        setup = nil  // its view's refresh loop ends with it
    }

    // MARK: Panel

    /// Grows the panel out of a name pill under the chat's slot, or slides it over when already open.
    /// No chat shows the list of every chat.
    private func show(_ chat: Chat?, under slot: Int? = nil) {
        let slot = slot ?? chat.flatMap(strip.slot) ?? 0
        store.markSeen(chat)
        NSApp.activate()
        if store.panelShown {
            withAnimation(.smooth(duration: 0.3)) { store.panelChat = chat }
            strip.update()
            let target = frame(under: slot)
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.3
                panel.animator().setFrame(Self.padded(target), display: true)
            }
            return panel.makeKey()
        }
        store.panelChat = chat
        let target = frame(under: slot)
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            store.panelShown = true
            strip.update()
            panel.setFrame(Self.padded(target), display: true)
            panel.alphaValue = 1
            return panel.makeKeyAndOrderFront(nil)
        }
        let start = showPill(label(chat), at: strip.anchor(under: slot))
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
        glass.tintColor = .black.withAlphaComponent(0.3)  // a shade darker than plain glass, so text holds up on light pages
        glass.autoresizingMask = [.width, .height]
        glass.contentView = content
        box.addSubview(glass)
        return box
    }

    /// The panel's glass at rest: centred under a strip slot, kept on screen.
    private func frame(under slot: Int) -> NSRect {
        let at = strip.anchor(under: slot)
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

    private func openInMessages() {
        hidePanel()
        if let chat = store.panelChat { MessagesApp.open(chat) }
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

/// A menu item that runs a closure. Nonisolated like NSMenuItem's initialisers; menus fire on the main thread.
nonisolated final class ActionItem: NSMenuItem {
    private let run: @MainActor () -> Void

    init(_ title: String, run: @escaping @MainActor () -> Void) {
        self.run = run
        super.init(title: title, action: #selector(fire), keyEquivalent: "")
        target = self
    }

    required init(coder: NSCoder) { fatalError("not used from nibs") }

    @objc private func fire() {
        let run = run  // a main-actor closure is Sendable; the item itself is not
        MainActor.assumeIsolated { run() }
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
