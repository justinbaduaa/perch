import AppKit
import SwiftUI

/// The menu bar item. Avatars overlap, the right one on top, and part around the one under the pointer
/// (or the open chat); "•••" at the end lists chats beyond the bar. The strip is only as wide as it needs:
/// while focused it widens by the parting gaps, growing to the left. The item's right edge never moves,
/// so the avatar under the pointer stays under it.
final class AvatarStrip {
    static let size: CGFloat = 20, rest: CGFloat = 13, gap: CGFloat = 3
    static let corner: CGFloat = 8  // squircle: closer to a circle than a square, like Hoy's
    private static let part = size + gap - rest  // how far each side of a focused avatar opens

    let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private(set) var hovered: Int?
    private let store: Store
    private var xs: [CGFloat] = []  // drawn x of each slot, eased toward the layout
    private var drawnWidth: CGFloat = 0
    private var easing: Timer?

    init(store: Store) { self.store = store }

    var bar: [Chat] { store.barChats }
    var moreSlot: Int? { store.chats.count > bar.count ? bar.count : nil }
    private var slots: Int { bar.count + (moreSlot == nil ? 0 : 1) }
    private var focus: Int? { hovered ?? openSlot }

    /// Where `chat` lives in the strip: its avatar, or "•••" for a chat beyond the bar.
    func slot(of chat: Chat) -> Int? { bar.firstIndex { $0.id == chat.id } ?? moreSlot }

    private var openSlot: Int? { store.panelShown ? store.panelChat.flatMap(slot) : nil }

    /// x of each slot in a strip `width(count, parting: focus)` wide. Steps into and out of `focus` are a full
    /// avatar plus a gap; a focused end slot opens on one side only, so it is padded on the left.
    static func layout(_ count: Int, parting focus: Int?) -> [CGFloat] {
        var x: CGFloat = 0
        let xs = (0..<count).map { i in
            defer { x += focus == i || focus == i + 1 ? size + gap : rest }
            return x
        }
        let pad = width(count, parting: focus) - ((xs.last ?? 0) + size)
        return xs.map { $0 + pad }
    }

    /// Resting width, plus both parting gaps whenever a slot is focused, so moving between avatars never resizes it.
    static func width(_ count: Int, parting focus: Int?) -> CGFloat {
        count == 0 ? 0 : CGFloat(count - 1) * rest + size + (focus == nil ? 0 : 2 * part)
    }

    /// The strip on screen. Two points taller than the item, because the pointer can rest on the screen's top edge.
    var rect: NSRect {
        guard let button = item.button, let window = button.window else { return .zero }
        let r = window.convertToScreen(button.convert(button.bounds, to: nil))
        let w = button.image?.size.width ?? 0
        return NSRect(x: r.midX - w / 2, y: r.minY, width: w, height: r.height + 2)
    }

    /// The slot under a screen point, measured from the strip's right edge, which never moves. The hovered slot
    /// keeps the pointer across its whole parted width, so parting can't push the pointer onto a neighbour.
    func slot(at point: NSPoint) -> Int? {
        let r = rect
        guard r.contains(point), slots > 0 else { return nil }
        let fromRight = r.maxX - point.x
        if let h = hovered, h < slots {
            let start = Self.layout(slots, parting: h)[h], x = Self.width(slots, parting: h) - fromRight
            if x >= start - Self.gap, x < start + Self.size + Self.gap { return h }
        }
        let drawn = Self.layout(slots, parting: focus), x = Self.width(slots, parting: focus) - fromRight
        return drawn.indices.last { x >= drawn[$0] && x < drawn[$0] + Self.size }  // the right one is on top
    }

    /// Screen point just under the menu bar, centred on `slot` as it sits when parted.
    func anchor(under slot: Int) -> NSPoint {
        let layout = Self.layout(slots, parting: slot)
        guard layout.indices.contains(slot) else { return NSPoint(x: rect.midX, y: rect.minY - 6) }  // empty strip
        let x = rect.maxX - Self.width(slots, parting: slot) + layout[slot] + Self.size / 2
        return NSPoint(x: x, y: rect.minY - 6)
    }

    /// Returns true when the hovered slot changed.
    func pointerMoved() -> Bool {
        let now = slot(at: NSEvent.mouseLocation)
        guard now != hovered else { return false }
        hovered = now
        update()
        return true
    }

    /// Eases toward the layout for the current bar, hover and open chat. Stops once settled, so it costs nothing at rest.
    /// Width and positions ease by the same factor, so slots right of the focus hold still on screen.
    func update() {
        if xs.count != slots || NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            xs = Self.layout(slots, parting: focus)
            drawnWidth = Self.width(slots, parting: focus)
        }
        draw()
        guard easing == nil else { return }
        easing = Timer.scheduledTimer(withTimeInterval: 1.0 / 60, repeats: true) { [unowned self] _ in
            MainActor.assumeIsolated {
                let target = Self.layout(slots, parting: focus)  // read every tick, so a new hover retargets mid-flight
                let width = Self.width(slots, parting: focus)
                if xs.count != target.count { xs = target; drawnWidth = width }
                let settled = abs(width - drawnWidth) < 0.25 && xs.indices.allSatisfy { abs(target[$0] - xs[$0]) < 0.25 }
                if settled {
                    xs = target
                    drawnWidth = width
                    easing?.invalidate()
                    easing = nil
                } else {
                    drawnWidth += (width - drawnWidth) * 0.3
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
        let strip = ZStack(alignment: .leading) {
            ForEach(Array(bar.enumerated()), id: \.element.id) { i, chat in
                Avatar(image: store.photo(chat), name: store.name(chat), size: size, cornerRadius: Self.corner)
                    .overlay { shape.strokeBorder(i == open ? Color.primary : rim, lineWidth: i == open ? 1.5 : 1) }
                    .offset(x: xs[i])
                    .zIndex(Double(i))
            }
            if let more {
                Image(systemName: "ellipsis").font(.system(size: 9, weight: .heavy))
                    .frame(width: size, height: size)
                    .background(.gray.opacity(0.45), in: shape)
                    .overlay { if more == open { shape.strokeBorder(.primary, lineWidth: 1.5) } }
                    .offset(x: xs[more])
                    .zIndex(Double(more))
            }
        }
        .frame(width: drawnWidth, height: size, alignment: .leading)
        .environment(\.colorScheme, dark ? .dark : .light)
        let renderer = ImageRenderer(content: strip)
        renderer.scale = button.window?.backingScaleFactor ?? 2
        button.image = renderer.nsImage
    }
}
