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
    private lazy var dropZone = DropZone(strip: strip, store: store)
    private let pill = AppDelegate.floatingPanel()
    /// The pill's beat before it grows into the panel, which another click or a close cancels.
    private var opening: Task<Void, Never>?
    private var mouseDownAt = NSPoint.zero
    /// Whether that press came while a modal of ours was up. The file picker is one: macOS draws it in another
    /// process, so clicks in it arrive here as clicks elsewhere.
    private var downInModal = false
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
        store.showPanel = { [unowned self] chat in if !store.panelShown || store.panelChat?.id != chat.id { show(chat) } }
        store.hidePanel = { [unowned self] in hidePanel() }
        store.showSetup = { [unowned self] in showSetup() }
        permissions.onContacts = { [unowned self] in Task { await store.contacts.load() } }
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

        dropZone.onDrop = { [unowned self] chat, files in
            store.stage(files, for: chat.id)  // into the message box; Send sends
            show(chat)
        }
        NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDown) { [unowned self] _ in dropZone.pressed() }

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
        store.hoverChat = strip.chat(in: strip.hovered)
        guard !store.panelShown else { return }
        if let slot = strip.hovered { _ = showPill(label(store.hoverChat), under: slot) } else { pill.orderOut(nil) }
    }

    /// "Oliver · 2 hrs ago" for a chat, "Chats" for the list behind "•••".
    private func label(_ chat: Chat?) -> String {
        guard let chat else { return "Chats" }
        return "\(store.shortName(chat)) · \(chat.lastActive.formatted(.relative(presentation: .numeric, unitsStyle: .narrow)))"
    }

    @objc private func clicked() {
        guard let button = strip.item.button else { return }
        if NSApp.currentEvent?.type == .rightMouseUp {
            let menu = NSHostingMenu(rootView: StripMenu(store: store, chat: strip.chat(in: strip.slot(at: NSEvent.mouseLocation))))
            menu.popUp(positioning: nil, at: NSPoint(x: 0, y: button.bounds.maxY + 4), in: button)
            return
        }
        let slot = strip.slot(at: NSEvent.mouseLocation) ?? 0  // VoiceOver presses have no pointer over the strip
        let chat = strip.chat(in: slot)  // "•••" opens the searchable list of every chat
        if store.panelShown && store.panelChat?.id == chat?.id { return hidePanel() }
        show(chat, under: slot)
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
        let target = strip.frame(under: slot, size: PanelRoot.size)
        opening?.cancel()
        NSApp.activate()
        if store.panelShown {
            withAnimation(.smooth(duration: 0.3)) { store.panelChat = chat }
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.3
                panel.animator().setFrame(Self.padded(target), display: true)
            }
            return panel.makeKey()
        }
        store.panelChat = chat
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            store.panelShown = true
            panel.setFrame(Self.padded(target), display: true)
            panel.alphaValue = 1
            return panel.makeKeyAndOrderFront(nil)
        }
        let start = showPill(label(chat), under: slot)
        opening = Task {
            guard (try? await Task.sleep(for: .milliseconds(80))) != nil else { return }  // the pill holds a beat
            panel.setFrame(Self.padded(start), display: false)
            panel.alphaValue = 0
            panel.makeKeyAndOrderFront(nil)
            withAnimation(.smooth(duration: 0.3)) { store.panelShown = true }
            await NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.28  // opened dozens of times a day: keep it under 300ms
                ctx.timingFunction = .strongEaseOut
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
        glass.tintColor = .panelShade
        glass.autoresizingMask = [.width, .height]
        glass.contentView = content
        box.addSubview(glass)
        return box
    }

    /// The name in a glass capsule under the menu bar. Returns its frame, which the panel grows from.
    private func showPill(_ name: String, under slot: Int) -> NSRect {
        let label = NSHostingView(rootView: Text(name).font(.callout.weight(.semibold)).lineLimit(1)
            .padding(.horizontal, 12).padding(.vertical, 6).fixedSize())
        let size = label.fittingSize
        pill.contentView = Self.glassBox(label, size: size, radius: size.height / 2)
        let frame = strip.frame(under: slot, size: size)
        pill.setFrame(Self.padded(frame), display: true)
        pill.alphaValue = 1
        pill.orderFront(nil)
        return frame
    }

    /// Blurs the content out while the window shrinks back toward the menu bar.
    private func hidePanel() {
        if let opening {  // clicked away before the pill grew
            opening.cancel()
            self.opening = nil
            pill.orderOut(nil)
        }
        guard store.panelShown else { return }
        nowPlaying?.stop()
        withAnimation(.smooth(duration: 0.18)) { store.panelShown = false }
        let f = panel.frame.insetBy(dx: Self.margin, dy: Self.margin)
        let end = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? f : NSRect(x: f.midX - 60, y: f.maxY - 30, width: 120, height: 30)
        Task {
            await NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.18
                panel.animator().setFrame(Self.padded(end), display: true)
                panel.animator().alphaValue = 0
            }
            if !store.panelShown { panel.orderOut(nil); pill.orderOut(nil) }  // unless reopened mid-animation
        }
    }

    private func makePanel() -> NSPanel {
        let panel = Self.floatingPanel()
        let host = NSHostingView(rootView: PanelRoot(store: store))
        host.sizingOptions = []
        // The glass pins its contentView edge to edge, so that is a bare container with no size of its own; the
        // panel inside keeps full size, pinned top-centre, and is revealed as the window grows out of the pill.
        let bounds = NSRect(origin: .zero, size: PanelRoot.size)
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
        let panel = KeyablePanel(contentRect: NSRect(origin: .zero, size: PanelRoot.size),
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

extension NSColor {
    /// The glass's shade: a little darker than plain glass, so text holds up on light pages.
    static let panelShade = NSColor.black.withAlphaComponent(0.3)
}

extension Color {
    /// Solid blue on the panel's glass. The glass blends SwiftUI's own `.blue` with what's behind it, which turns
    /// it a pale cyan; a color made from an NSColor draws as is.
    static let solidBlue = Color(nsColor: .systemBlue)
}

extension CAMediaTimingFunction {
    /// Fast out of the gate, settling softly: things that open many times a day.
    static let strongEaseOut = CAMediaTimingFunction(controlPoints: 0.23, 1, 0.32, 1)
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
