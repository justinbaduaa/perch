import AppKit
import SwiftUI

/// The menu bar item. Avatars overlap, left on top, and part around the one under the pointer (or the open chat);
/// "•••" at the end lists chats beyond the bar. The item has one width, with a parting gap's worth of margin on
/// each side at rest: a focused avatar stays exactly where it rests and its neighbours slide into the margins,
/// so neither the menu bar nor the avatar under the pointer ever moves.
final class AvatarStrip {
    static let size: CGFloat = 20, rest: CGFloat = 13, gap: CGFloat = 3
    static let corner: CGFloat = 8  // squircle: closer to a circle than a square, like Hoy's
    private static let part = size + gap - rest  // how far each side of a focused avatar opens

    let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private(set) var hovered: Int?
    private let store: Store
    private var xs: [CGFloat] = []  // drawn x of each slot, eased toward the layout
    private var easing: Timer?

    init(store: Store) { self.store = store }

    var bar: [Chat] { store.barChats }
    var moreSlot: Int? { store.chats.count > bar.count ? bar.count : nil }
    private var slots: Int { bar.count + (moreSlot == nil ? 0 : 1) }
    private var focus: Int? { hovered ?? openSlot }

    /// Where `chat` lives in the strip: its avatar, or "•••" for a chat beyond the bar.
    func slot(of chat: Chat) -> Int? { bar.firstIndex { $0.id == chat.id } ?? moreSlot }

    private var openSlot: Int? { store.panelShown ? store.panelChat.flatMap(slot) : nil }

    /// x of each slot. At rest the stack is centred; a focused slot keeps its resting x and its neighbours part from it.
    static func layout(_ count: Int, parting focus: Int?) -> [CGFloat] {
        let resting = (0..<count).map { part + CGFloat($0) * rest }
        guard let focus, resting.indices.contains(focus) else { return resting }
        var x: CGFloat = 0
        let parted = (0..<count).map { i in
            defer { x += focus == i || focus == i + 1 ? size + gap : rest }
            return x
        }
        return parted.map { $0 + resting[focus] - parted[focus] }
    }

    static func width(_ count: Int) -> CGFloat { count == 0 ? 0 : CGFloat(count - 1) * rest + size + 2 * part }

    /// The strip on screen. Two points taller than the item, because the pointer can rest on the screen's top edge.
    var rect: NSRect {
        guard let button = item.button, let window = button.window else { return .zero }
        let r = window.convertToScreen(button.convert(button.bounds, to: nil))
        let w = button.image?.size.width ?? 0
        return NSRect(x: r.midX - w / 2, y: r.minY, width: w, height: r.height + 2)
    }

    /// The slot under a screen point. The hovered slot keeps the pointer across its resting box plus a gap,
    /// so moving within it never flips to a neighbour.
    func slot(at point: NSPoint) -> Int? {
        let r = rect
        guard r.contains(point), slots > 0 else { return nil }
        let x = point.x - r.minX
        if let h = hovered, h < slots {
            let start = Self.layout(slots, parting: nil)[h]
            if x >= start - Self.gap, x < start + Self.size + Self.gap { return h }
        }
        let drawn = Self.layout(slots, parting: focus)
        return drawn.indices.first { x >= drawn[$0] && x < drawn[$0] + Self.size }  // left is on top
    }

    /// Screen point just under the menu bar, centred on `slot`, which never moves when it is focused.
    func anchor(under slot: Int) -> NSPoint {
        let resting = Self.layout(slots, parting: nil)
        guard resting.indices.contains(slot) else { return NSPoint(x: rect.midX, y: rect.minY - 6) }  // empty strip
        return NSPoint(x: rect.minX + resting[slot] + Self.size / 2, y: rect.minY - 6)
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
    func update() {
        if xs.count != slots || NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            xs = Self.layout(slots, parting: focus)
        }
        draw()
        guard easing == nil else { return }
        easing = Timer.scheduledTimer(withTimeInterval: 1.0 / 60, repeats: true) { [unowned self] _ in
            MainActor.assumeIsolated {
                let target = Self.layout(slots, parting: focus)  // read every tick, so a new hover retargets mid-flight
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
                Avatar(image: store.photo(chat), name: store.name(chat), size: size, cornerRadius: Self.corner)
                    .overlay {
                        shape.strokeBorder(i == recording ? .red : i == open ? Color.primary : rim,
                                           lineWidth: i == recording || i == open ? 1.5 : 1)
                    }
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
