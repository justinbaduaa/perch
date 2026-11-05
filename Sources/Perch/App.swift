import AppKit
import SwiftUI

/// SwiftUI owns the lifecycle so the app gets a standard main menu (Cmd-C/V/Q work in the panel).
@main struct PerchApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    var body: some Scene { Settings { EmptyView() } }
}

/// Menu bar strip of avatars. Clicking one drops a glass panel with that conversation under it.
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let store = Store()
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private lazy var panel = makePanel()
    private var mouseDownAt = NSPoint.zero
    private static let avatar: CGFloat = 20, stride: CGFloat = 17  // avatars overlap by 3pt

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        item.button?.target = self
        item.button?.action = #selector(clicked)
        item.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
        store.onChange = { [unowned self] in drawBar() }
        store.start()
        drawBar()

        // Close on a click in another app, but not on a drag: dragging files in from Finder is how you drop them.
        NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .leftMouseUp, .rightMouseDown]) { [unowned self] event in
            let at = NSEvent.mouseLocation
            switch event.type {
            case .leftMouseDown: mouseDownAt = at
            case .leftMouseUp where hypot(at.x - mouseDownAt.x, at.y - mouseDownAt.y) < 4: hidePanel()
            case .rightMouseDown: hidePanel()
            default: break
            }
        }
    }

    private func drawBar() {
        let bar = store.barChats
        item.button?.setAccessibilityLabel(bar.isEmpty ? "Perch" : bar.map(store.name).joined(separator: ", "))
        guard !bar.isEmpty else {
            item.button?.image = NSImage(systemSymbolName: "bubble.left.and.bubble.right", accessibilityDescription: "Perch")
            return
        }
        let open = panel.isVisible ? store.panelChat?.id : nil
        let store = store
        let renderer = ImageRenderer(content: HStack(spacing: Self.stride - Self.avatar) {
            ForEach(bar) { chat in
                Avatar(image: store.photo(chat), name: store.name(chat), size: Self.avatar)
                    .overlay { if chat.id == open { Circle().strokeBorder(.white, lineWidth: 1.5) } }
            }
        })
        renderer.scale = NSScreen.main?.backingScaleFactor ?? 2
        item.button?.image = renderer.nsImage
    }

    @objc private func clicked() {
        guard let button = item.button else { return }
        let event = NSApp.currentEvent  // not a mouse event when pressed through VoiceOver
        if event?.type == .rightMouseUp {
            let menu = NSMenu()
            menu.addItem(withTitle: "Quit Perch", action: #selector(NSApplication.terminate), keyEquivalent: "q")
            menu.popUp(positioning: nil, at: NSPoint(x: 0, y: button.bounds.maxY + 4), in: button)
            return
        }
        let bar = store.barChats
        let inset = (button.bounds.width - (button.image?.size.width ?? 0)) / 2
        let x = event.flatMap { $0.type == .leftMouseUp ? button.convert($0.locationInWindow, from: nil).x - inset : nil } ?? 0
        let index = min(max(Int(x / Self.stride), 0), max(bar.count - 1, 0))
        let chat = bar.isEmpty ? nil : bar[index]
        if panel.isVisible && store.panelChat?.id == chat?.id { return hidePanel() }
        store.panelChat = chat
        showPanel(under: index)
    }

    private func showPanel(under index: Int) {
        guard let button = item.button, let barWindow = button.window else { return }
        let rect = barWindow.convertToScreen(button.convert(button.bounds, to: nil))
        let inset = (rect.width - (button.image?.size.width ?? 0)) / 2
        let centerX = rect.minX + inset + CGFloat(index) * Self.stride + Self.avatar / 2
        let size = panel.frame.size
        let screen = barWindow.screen?.visibleFrame ?? rect
        let x = min(max(centerX - size.width / 2, screen.minX + 8), screen.maxX - size.width - 8)
        let frame = NSRect(x: x, y: rect.minY - 6 - size.height, width: size.width, height: size.height)

        let wasVisible = panel.isVisible
        NSApp.activate()
        panel.makeKeyAndOrderFront(nil)
        if wasVisible {
            panel.animator().setFrame(frame, display: true)
        } else {
            panel.setFrame(frame.offsetBy(dx: 0, dy: 10), display: false)
            panel.alphaValue = 0
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.18
                panel.animator().setFrame(frame, display: true)
                panel.animator().alphaValue = 1
            }
        }
        drawBar()
    }

    private func hidePanel() {
        guard panel.isVisible else { return }
        panel.orderOut(nil)
        drawBar()
    }

    /// A 1:1 chat opens on its thread. Messages has no public link to a group thread, so a group opens the app.
    private func openInMessages() {
        hidePanel()
        let handles = store.panelChat?.handles ?? []
        let thread = handles.count == 1 ? URL(string: "sms:\(handles[0])") : nil
        NSWorkspace.shared.open(thread ?? URL(filePath: "/System/Applications/Messages.app"))
    }

    private func makePanel() -> NSPanel {
        let panel = KeyablePanel(contentRect: NSRect(x: 0, y: 0, width: 340, height: 540),
                                 styleMask: [.borderless], backing: .buffered, defer: true)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .floating  // stays above Finder while files are dragged in
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        let glass = NSGlassEffectView(frame: panel.contentLayoutRect)
        glass.cornerRadius = 26
        glass.contentView = NSHostingView(rootView: PanelRoot(
            store: store,
            openInMessages: { [unowned self] in openInMessages() },
            close: { [unowned self] in hidePanel() }))
        panel.contentView = glass
        return panel
    }
}

/// Borderless panels refuse key status by default, which would block typing.
final class KeyablePanel: NSPanel {
    override var canBecomeKey: Bool { true }
}
