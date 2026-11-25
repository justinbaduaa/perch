import AppKit
import SwiftUI

/// The menu bar item. Avatars overlap, left on top, with "•••" at the end listing chats beyond the bar. The item is only
/// as wide as that stack. While the pointer is over it or the panel is open, the avatars spread out side by side in a
/// glass capsule floating over the menu bar, so the items beside it are covered for a moment instead of pushed along.
final class AvatarStrip {
    static let size: CGFloat = 20, rest: CGFloat = 13, gap: CGFloat = 4
    static let corner: CGFloat = 8  // squircle: closer to a circle than a square, like Hoy's
    static let pad: CGFloat = 4  // capsule around the spread avatars

    let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    /// Clicks on the spread strip, which sits over the item and its neighbours. Read the click from `NSApp.currentEvent`.
    var onClick: () -> Void {
        get { lifted.onClick }
        set { lifted.onClick = newValue }
    }
    private let lifted = Lifted()
    private var blank: NSImage?  // the item's picture while the avatars float
    private var liftedAt: Date?  // when the avatars last left the item for the floating window
    private static let handover: TimeInterval = 0.05
    private(set) var hovered: Int?
    /// The face a file drag is over, which spreads the strip and rings it as if open.
    var dropTarget: Int? { didSet { if dropTarget != oldValue { update() } } }
    private var inside = false
    private let store: Store
    private var xs: [CGFloat] = []  // drawn x of each slot, eased toward the layout
    private var easing: Timer?
    /// Counts draws, so only the latest one's observation redraws.
    private var draws = 0

    init(store: Store) { self.store = store }

    var bar: [Chat] { store.barChats }
    var moreSlot: Int? { store.chats.count > bar.count ? bar.count : nil }
    private var slots: Int { bar.count + (moreSlot == nil ? 0 : 1) }
    private var spread: Bool { inside || store.panelShown || dropTarget != nil }

    /// The chat in `slot`, or nil for "•••" or no slot.
    func chat(in slot: Int?) -> Chat? { slot.flatMap { $0 < bar.count ? bar[$0] : nil } }

    /// Where `chat` lives in the strip: its avatar, or "•••" for a chat beyond the bar.
    func slot(of chat: Chat) -> Int? { bar.firstIndex { $0.id == chat.id } ?? moreSlot }

    private var openSlot: Int? { dropTarget ?? (store.panelShown ? store.panelChat.flatMap(slot) ?? moreSlot : nil) }

    /// x of each slot across the spread width: side by side when spread, overlapping and centred at rest, so the stack
    /// opens out from the item's centre.
    static func layout(_ count: Int, spread: Bool) -> [CGFloat] {
        let inset = spread ? 0 : (width(count) - stackWidth(count)) / 2
        return (0..<count).map { inset + CGFloat($0) * (spread ? size + gap : rest) }
    }

    /// The spread strip's width.
    static func width(_ count: Int) -> CGFloat { count == 0 ? 0 : CGFloat(count) * size + CGFloat(count - 1) * gap }
    /// The item's width: the overlapped stack.
    static func stackWidth(_ count: Int) -> CGFloat { count == 0 ? 0 : CGFloat(count - 1) * rest + size }

    /// The item on screen.
    private var itemFrame: NSRect? {
        guard let button = item.button, let window = button.window else { return nil }
        return window.convertToScreen(button.convert(button.bounds, to: nil))
    }

    /// The strip on screen: the stack, or the spread strip over it. Two points taller than the item, because the pointer
    /// can rest on the screen's top edge.
    var rect: NSRect {
        guard let r = itemFrame else { return .zero }
        let w = bar.isEmpty ? item.button?.image?.size.width ?? 0 : spread ? Self.width(slots) : Self.stackWidth(slots)
        return NSRect(x: r.midX - w / 2, y: r.minY, width: w, height: r.height + 2)
    }

    /// The slot under a screen point, in the spread layout (the strip spreads as soon as the pointer is over it).
    /// Each slot owns half the gap on either side, so the pointer is never between two.
    func slot(at point: NSPoint) -> Int? {
        let r = rect
        guard r.contains(point), slots > 0 else { return nil }
        let x = point.x - (r.midX - Self.width(slots) / 2)
        return max(0, min(slots - 1, Int((x + Self.gap / 2) / (Self.size + Self.gap))))
    }

    /// Screen point just under the menu bar, centred on `slot` as the spread strip draws it.
    func anchor(under slot: Int) -> NSPoint {
        let r = itemFrame ?? .zero, spread = Self.layout(slots, spread: true)
        guard spread.indices.contains(slot) else { return NSPoint(x: r.midX, y: r.minY - 6) }  // empty strip
        return NSPoint(x: r.midX - Self.width(slots) / 2 + spread[slot] + Self.size / 2, y: r.minY - 6)
    }

    /// A box of `size` hanging under `slot`, kept on screen: the name pill, the drop pill and the panel.
    func frame(under slot: Int, size: NSSize) -> NSRect {
        let at = anchor(under: slot)
        let screen = item.button?.window?.screen?.visibleFrame ?? .infinite
        let x = min(max(at.x - size.width / 2, screen.minX + 8), screen.maxX - size.width - 8)
        return NSRect(x: x, y: at.y - size.height, width: size.width, height: size.height)
    }

    /// Spreads or gathers the strip as the pointer enters or leaves. Returns true when the hovered slot changed.
    func pointerMoved() -> Bool {
        let at = NSEvent.mouseLocation, now = slot(at: at)
        if rect.contains(at) != inside {
            inside.toggle()
            update()
        }
        guard now != hovered else { return false }
        hovered = now
        return true
    }

    /// Eases toward the layout for the current bar, hover and open chat. Stops once settled, so it costs nothing at rest.
    func update() {
        if xs.count != slots { xs = Self.layout(slots, spread: spread) }
        draw()
        guard easing == nil else { return }
        easing = Timer.scheduledTimer(withTimeInterval: 1.0 / 60, repeats: true) { [unowned self] _ in
            MainActor.assumeIsolated {
                let target = Self.layout(slots, spread: spread)  // read every tick, so leaving mid-spread turns it around
                if xs.count != target.count { xs = target }
                if let liftedAt, Date.now.timeIntervalSince(liftedAt) < Self.handover { return draw() }  // see `render`
                if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion { xs = target }
                if xs.indices.allSatisfy({ abs(target[$0] - xs[$0]) < 0.25 }) {
                    xs = target
                    easing?.invalidate()
                    easing = nil
                } else {
                    for i in xs.indices { xs[i] += (target[i] - xs[i]) * 0.3 }
                }
                draw()
            }
        }
    }

    /// "•••"'s tile, lightening as the strip opens. Solid, because the menu bar and the floating window draw see-through
    /// colours differently and it would jump at the hand-over. In the dark, these are the shades 45% grey had over the
    /// bare bar and over the capsule.
    private static func moreTile(_ opened: CGFloat, dark: Bool) -> Color {
        guard dark else { return Color(white: 0.72) }
        let rest: [CGFloat] = [0x65, 0x60, 0x5A], spread: [CGFloat] = [0x7B, 0x76, 0x73]
        let c = zip(rest, spread).map { ($0 + ($1 - $0) * opened) / 255 }
        return Color(red: c[0], green: c[1], blue: c[2])
    }

    /// Draws, and draws again when anything it drew from changes: chats, pins, rings, contacts, the open chat.
    private func draw() {
        draws += 1
        let drawn = draws
        withObservationTracking(render, onChange: { [unowned self] in
            Task { @MainActor in if draws == drawn { update() } }
        })
    }

    private func render() {
        guard let button = item.button else { return }
        let bar = bar, store = store
        button.setAccessibilityLabel(bar.isEmpty ? "Perch" : bar.map(store.name).joined(separator: ", "))
        guard !bar.isEmpty, xs.count == slots else {
            button.image = NSImage(systemSymbolName: "bubble.left.and.bubble.right", accessibilityDescription: "Perch")
            lifted.orderOut(nil)
            return
        }
        let dark = button.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let rim = dark ? Color.black.opacity(0.45) : Color.white.opacity(0.85)  // reads as a cut between stacked avatars
        let shape = RoundedRectangle(cornerRadius: Self.corner, style: .continuous)
        // Off the stack (spread, or on the way), the avatars draw in the floating window; at rest, in the item itself.
        let stack = Self.layout(slots, spread: false), floating = slots > 1 && (spread || xs != stack)
        let xs = floating ? xs : xs.map { $0 - stack[0] }, open = openSlot, more = moreSlot, size = Self.size
        // 0 on the stack, 1 spread.
        let opened = slots < 2 ? 0 : min(1, max(0, (xs[slots - 1] - xs[0] - stack[slots - 1] + stack[0])
            / (CGFloat(slots - 1) * (Self.size + Self.gap - Self.rest))))
        // Read here rather than in the view: reads inside ImageRenderer's views escape `draw`'s observation.
        let recording = bar.firstIndex { $0.id == store.recorder.chatID }
        let faces = bar.enumerated().map { i, chat in
            // Red while recording for them, white for the open chat, blue for something unread.
            let ring: Color? = i == recording ? .red : i == open ? .primary : store.isUnread(chat) ? .blue : nil
            return (chat: chat, photo: store.photo(chat), name: store.name(chat), ring: ring)
        }
        let strip = ZStack(alignment: .leading) {
            ForEach(Array(faces.enumerated()), id: \.element.chat.id) { i, face in
                let ring = face.ring
                Avatar(image: face.photo, name: face.name, size: size, cornerRadius: Self.corner)
                    .overlay { shape.strokeBorder(ring ?? rim, lineWidth: ring == nil ? 1 : 1.5) }
                    .offset(x: xs[i])
                    .zIndex(Double(bar.count - i))
            }
            if let more {
                Image(systemName: "ellipsis").font(.system(size: 9, weight: .heavy))
                    .frame(width: size, height: size)
                    .background(Self.moreTile(opened, dark: dark), in: shape)
                    .overlay { if more == open { shape.strokeBorder(.primary, lineWidth: 1.5) } }
                    .offset(x: xs[more])
            }
        }
        .frame(width: floating ? Self.width(slots) : Self.stackWidth(slots), height: size, alignment: .leading)
        .environment(\.colorScheme, dark ? .dark : .light)
        let renderer = ImageRenderer(content: strip)
        renderer.scale = button.window?.backingScaleFactor ?? 2
        guard let menuBar = button.window?.frame, let r = itemFrame else { return button.image = renderer.nsImage }
        let over = NSRect(x: r.midX - Self.width(slots) / 2 - Self.pad, y: menuBar.minY,
                          width: Self.width(slots) + 2 * Self.pad, height: menuBar.height)
        guard floating else {
            // Back on the stack. macOS blurs a new item picture in over a frame, so the float keeps the same avatars
            // on top of it a moment longer.
            liftedAt = nil
            button.image = renderer.nsImage
            return lifted.settle(over: over)
        }
        lifted.show(renderer.nsImage, xs: xs, opened: opened, over: over, clickable: spread)
        // The floating window can land a frame after the item changes, so for `handover` it shows the stack right on top
        // of the item's (the easing holds still), and only then does the item empty and the spread start. The item keeps
        // its width.
        let since = liftedAt ?? .now
        liftedAt = since
        guard Date.now.timeIntervalSince(since) >= Self.handover else { return }
        if blank?.size.width != Self.stackWidth(slots) {
            blank = NSImage(size: NSSize(width: Self.stackWidth(slots), height: size), flipped: false) { _ in true }
        }
        if button.image !== blank { button.image = blank }
    }
}

/// The spread strip: a borderless window just above the menu bar's, so it floats over the items beside Perch's instead
/// of pushing them along. It takes the clicks over those items while spread. At rest it stays ordered in and opaque,
/// with its contents hidden and clicks passing through: a window being ordered in, or brought up from zero opacity,
/// can show a frame or two late, and the stack would blink out meanwhile.
private final class Lifted: NSPanel {
    var onClick: () -> Void = {}
    private let glass = NSGlassEffectView(), avatars = NSImageView()
    private var fading: Task<Void, Never>?

    init() {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        level = NSWindow.Level(NSWindow.Level.statusBar.rawValue + 1)
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        animationBehavior = .none
        ignoresMouseEvents = true
        let clicks = Clicks()
        clicks.onClick = { [unowned self] in onClick() }
        glass.tintColor = .panelShade
        avatars.imageScaling = .scaleNone
        clicks.addSubview(glass)
        clicks.addSubview(avatars)
        clicks.isHidden = true
        contentView = clicks
    }

    required init?(coder: NSCoder) { fatalError("not used from nibs") }

    /// Draws `image` (the strip, `AvatarStrip.width` wide) across `frame`, with the capsule around the avatars at `xs`.
    /// `opened` runs from 0 on the stack to 1 spread, and fades the capsule in with it.
    func show(_ image: NSImage?, xs: [CGFloat], opened: CGFloat, over frame: NSRect, clickable: Bool) {
        fading?.cancel()
        fading = nil
        if self.frame != frame { setFrame(frame, display: false) }
        let size = AvatarStrip.size, inset = AvatarStrip.pad, y = (frame.height - size) / 2, pad = min(inset, y)
        avatars.frame = NSRect(x: inset, y: y, width: frame.width - 2 * inset, height: size)
        avatars.image = image
        let lo = xs.min() ?? 0, hi = (xs.max() ?? 0) + size
        glass.frame = NSRect(x: inset + lo - pad, y: y - pad, width: hi - lo + 2 * pad, height: size + 2 * pad)
        glass.cornerRadius = glass.frame.height / 2
        glass.alphaValue = min(1, max(0, opened))
        ignoresMouseEvents = !clickable  // gathering back after the pointer left: clicks are for the neighbours again
        contentView?.isHidden = false
        if !isVisible { orderFront(nil) }
    }

    /// Hides the avatars a moment after the stack is back in the item, leaving the window up for the next spread.
    func settle(over frame: NSRect) {
        ignoresMouseEvents = true
        if self.frame != frame { setFrame(frame, display: false) }
        if !isVisible { orderFront(nil) }
        guard contentView?.isHidden == false, fading == nil else { return }
        fading = Task {
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            contentView?.isHidden = true
            fading = nil
        }
    }
}

/// Takes every click in the floating strip, on the first press even with Perch in the background.
private final class Clicks: NSView {
    var onClick: () -> Void = {}
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { frame.contains(point) ? self : nil }
    override func mouseDown(with event: NSEvent) {}
    override func rightMouseDown(with event: NSEvent) {}
    override func mouseUp(with event: NSEvent) { onClick() }
    override func rightMouseUp(with event: NSEvent) { onClick() }
}
