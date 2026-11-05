import AppKit
import SwiftUI

/// The menu bar item. Avatars overlap, left on top, and all spread out side by side while the pointer is over the
/// strip or the panel is open; "•••" at the end lists chats beyond the bar. The item is always as wide as the spread
/// strip, with the overlapped stack centred in it, so the menu bar never moves.
final class AvatarStrip {
    static let size: CGFloat = 20, rest: CGFloat = 13, gap: CGFloat = 4
    static let corner: CGFloat = 8  // squircle: closer to a circle than a square, like Hoy's

    let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private(set) var hovered: Int?
    private var inside = false
    private let store: Store
    private var xs: [CGFloat] = []  // drawn x of each slot, eased toward the layout
    private var easing: Timer?

    init(store: Store) { self.store = store }

    var bar: [Chat] { store.barChats }
    var moreSlot: Int? { store.chats.count > bar.count ? bar.count : nil }
    private var slots: Int { bar.count + (moreSlot == nil ? 0 : 1) }
    private var spread: Bool { inside || store.panelShown }

    /// Where `chat` lives in the strip: its avatar, or "•••" for a chat beyond the bar.
    func slot(of chat: Chat) -> Int? { bar.firstIndex { $0.id == chat.id } ?? moreSlot }

    private var openSlot: Int? { store.panelShown ? store.panelChat.flatMap(slot) ?? moreSlot : nil }

    /// x of each slot: side by side when spread, overlapping and centred at rest.
    static func layout(_ count: Int, spread: Bool) -> [CGFloat] {
        let inset = spread ? 0 : (width(count) - CGFloat(max(count - 1, 0)) * rest - size) / 2
        return (0..<count).map { inset + CGFloat($0) * (spread ? size + gap : rest) }
    }

    static func width(_ count: Int) -> CGFloat { count == 0 ? 0 : CGFloat(count) * size + CGFloat(count - 1) * gap }

    /// The strip on screen. Two points taller than the item, because the pointer can rest on the screen's top edge.
    var rect: NSRect {
        guard let button = item.button, let window = button.window else { return .zero }
        let r = window.convertToScreen(button.convert(button.bounds, to: nil))
        let w = button.image?.size.width ?? 0
        return NSRect(x: r.midX - w / 2, y: r.minY, width: w, height: r.height + 2)
    }

    /// The slot under a screen point, in the spread layout (the strip spreads as soon as the pointer is over it).
    /// Each slot owns half the gap on either side, so the pointer is never between two.
    func slot(at point: NSPoint) -> Int? {
        let r = rect
        guard r.contains(point), slots > 0 else { return nil }
        return min(slots - 1, Int((point.x - r.minX + Self.gap / 2) / (Self.size + Self.gap)))
    }

    /// Screen point just under the menu bar, centred on `slot` as the spread strip draws it.
    func anchor(under slot: Int) -> NSPoint {
        let spread = Self.layout(slots, spread: true)
        guard spread.indices.contains(slot) else { return NSPoint(x: rect.midX, y: rect.minY - 6) }  // empty strip
        return NSPoint(x: rect.minX + spread[slot] + Self.size / 2, y: rect.minY - 6)
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
        if xs.count != slots || NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            xs = Self.layout(slots, spread: spread)
        }
        draw()
        guard easing == nil else { return }
        easing = Timer.scheduledTimer(withTimeInterval: 1.0 / 60, repeats: true) { [unowned self] _ in
            MainActor.assumeIsolated {
                let target = Self.layout(slots, spread: spread)  // read every tick, so leaving mid-spread turns it around
                if xs.count != target.count { xs = target }
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

    private func draw() {
        guard let button = item.button else { return }
        let bar = bar, store = store
        button.setAccessibilityLabel(bar.isEmpty ? "Perch" : bar.map(store.name).joined(separator: ", "))
        guard !bar.isEmpty, xs.count == slots else {
            button.image = NSImage(systemSymbolName: "bubble.left.and.bubble.right", accessibilityDescription: "Perch")
            return
        }
        let dark = button.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let rim = dark ? Color.black.opacity(0.45) : Color.white.opacity(0.85)  // reads as a cut between stacked avatars
        let shape = RoundedRectangle(cornerRadius: Self.corner, style: .continuous)
        let xs = xs, open = openSlot, more = moreSlot, size = Self.size
        let recording = bar.firstIndex { $0.id == store.recorder.chatID }
        let strip = ZStack(alignment: .leading) {
            ForEach(Array(bar.enumerated()), id: \.element.id) { i, chat in
                // Red while recording for them, white for the open chat, blue for something unread.
                let ring: Color? = i == recording ? .red : i == open ? .primary : store.isUnread(chat) ? .blue : nil
                Avatar(image: store.photo(chat), name: store.name(chat), size: size, cornerRadius: Self.corner)
                    .overlay { shape.strokeBorder(ring ?? rim, lineWidth: ring == nil ? 1 : 1.5) }
                    .offset(x: xs[i])
                    .zIndex(Double(bar.count - i))
            }
            if let more {
                Image(systemName: "ellipsis").font(.system(size: 9, weight: .heavy))
                    .frame(width: size, height: size)
                    .background(.gray.opacity(0.45), in: shape)
                    .overlay { if more == open { shape.strokeBorder(.primary, lineWidth: 1.5) } }
                    .offset(x: xs[more])
            }
        }
        .frame(width: Self.width(slots), height: size, alignment: .leading)
        .environment(\.colorScheme, dark ? .dark : .light)
        let renderer = ImageRenderer(content: strip)
        renderer.scale = button.window?.backingScaleFactor ?? 2
        button.image = renderer.nsImage
    }
}
