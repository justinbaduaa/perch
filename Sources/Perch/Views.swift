import AVFoundation
import QuickLookThumbnailing
import SwiftUI

/// Contents of the menu bar panel: one conversation, or why there is none.
struct PanelRoot: View {
    static let size = CGSize(width: 340, height: 540)
    let store: Store

    var body: some View {
        Group {
            if store.needsAccess {
                AccessView(store: store)
            } else if let error = store.readError {
                ContentUnavailableView("Can't read Messages", systemImage: "exclamationmark.bubble", description: Text(error))
            } else if let chat = store.panelChat {
                ConversationView(store: store, chat: chat)
                    .id(chat.id)
                    .transition(.blurReplace)
            } else {
                PeopleView(store: store)
            }
        }
        .frame(width: Self.size.width, height: Self.size.height)
        .coordinateSpace(.named("panel"))  // thumbnails report here, for Quick Look's zoom
        // The window grows from a pill while this blurs in, so pin the content to the top and clip it.
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .clipped()
        .blur(radius: store.panelShown ? 0 : 14)
        .opacity(store.panelShown ? 1 : 0)
        .onExitCommand(perform: store.hidePanel)
    }
}

/// Every chat, newest first, behind a search field. Return opens the top match.
struct PeopleView: View {
    let store: Store
    @State private var search = ""
    @State private var hovered: Chat.ID?
    @FocusState private var focused: Bool

    private var matches: [Chat] {
        search.isEmpty ? store.chats : store.chats.filter { store.name($0).localizedCaseInsensitiveContains(search) }
    }

    var body: some View {
        VStack(spacing: 4) {
            TextField("Search", text: $search)
                .textFieldStyle(.plain)
                .focused($focused)
                .onSubmit { if let top = matches.first { open(top) } }
                .padding(.horizontal, 12).padding(.vertical, 9)
                .background(.quaternary, in: .rect(cornerRadius: 14, style: .continuous))
                .padding([.horizontal, .top], 12)
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(matches) { chat in
                        Button { open(chat) } label: {
                            HStack(spacing: 10) {
                                Avatar(image: store.photo(chat), name: store.name(chat), size: 28)
                                Text(store.name(chat)).lineLimit(1)
                                Spacer(minLength: 0)
                                if store.pins.contains(chat.guid) {
                                    Image(systemName: "pin.fill").font(.caption).foregroundStyle(.secondary)
                                }
                            }
                            .padding(.horizontal, 10).padding(.vertical, 6)
                            .background(hovered == chat.id ? AnyShapeStyle(.quaternary) : AnyShapeStyle(.clear),
                                        in: .rect(cornerRadius: 10, style: .continuous))
                            .contentShape(.rect)
                        }
                        .buttonStyle(.plain)
                        .onHover { hovered = $0 ? chat.id : nil }
                        .contextMenu { ChatMenu(store: store, chat: chat) }
                    }
                }
                .padding(.horizontal, 6).padding(.bottom, 8)
            }
            .scrollIndicators(.never)
        }
        .task(id: store.panelShown) { if store.panelShown { focused = true } }
    }

    private func open(_ chat: Chat) {
        withAnimation(.smooth(duration: 0.3)) { store.panelChat = chat }
    }
}

/// The strip's right-click menu: the menu of the chat under the pointer, if any, then Perch's own.
struct StripMenu: View {
    let store: Store
    let chat: Chat?

    var body: some View {
        if let chat {
            Section(store.name(chat)) { ChatMenu(store: store, chat: chat) }
            Divider()
        }
        Button("Set Up Perch…", action: store.showSetup)
        Button("Quit Perch") { NSApp.terminate(nil) }.keyboardShortcut("q")
    }
}

/// Messages' menu for a conversation, on the strip and in the list behind "•••".
struct ChatMenu: View {
    let store: Store
    let chat: Chat

    var body: some View {
        let pinned = store.pins.contains(chat.guid), unread = store.isUnread(chat), muted = store.isMuted(chat)
        Button(pinned ? "Unpin" : "Pin", systemImage: pinned ? "pin.slash" : "pin") { store.togglePin(chat) }
        Divider()
        Button(unread ? "Mark as Read" : "Mark as Unread", systemImage: unread ? "envelope.open" : "envelope.badge") {
            store.setRead(chat, unread)
        }
        Button(muted ? "Show Alerts" : "Hide Alerts", systemImage: muted ? "bell" : "bell.slash") { store.setMuted(chat, !muted) }
        Divider()
        Button("Open in Messages", systemImage: "message") { store.openInMessages(chat) }
        Divider()
        Button("Delete…", systemImage: "trash", role: .destructive) { store.confirmDelete(chat) }
    }
}

struct AccessView: View {
    let store: Store

    var body: some View {
        ContentUnavailableView {
            Label("Full Disk Access", systemImage: "lock")
        } description: {
            Text("Perch reads your conversations from Messages.")
        } actions: {
            Button("Set Up Perch", action: store.showSetup)
        }
    }
}

struct ConversationView: View {
    let store: Store
    let chat: Chat
    @State private var dropping = false
    @State private var replying: Message?
    @State private var swipe: Swipe?
    @State private var rows = RowFrames()
    @State private var monitor: Any?
    @State private var position = ScrollPosition(edge: .bottom)
    /// Scrolled up past the newest message, so See more shows.
    @State private var above = false

    /// A two-finger swipe on one message: finger travel so far, and whether it turned out sideways.
    private struct Swipe {
        let guid: String
        /// Toward the middle of the panel: right for their messages, left for mine.
        var way: CGFloat = 1
        var x: CGFloat = 0, y: CGFloat = 0
        var sideways: Bool?
        var momentum = false  // the swipe ended; its momentum events are swallowed too
        /// Finger travel toward the middle. Travel the other way doesn't move the message.
        var pull: CGFloat { max(0, x * way) }
        /// Follows the fingers up to the reply arrow, then drags.
        var shown: CGFloat { (pull <= replyReach ? pull : replyReach + (pull - replyReach) * 0.25) * way }
    }

    /// Where each message row sits in the panel. A plain object, so scrolling doesn't re-render the thread.
    private final class RowFrames { var byGuid: [String: CGRect] = [:] }

    var body: some View {
        VStack(spacing: 0) {
            header
            ScrollView {
                // Every row laid out up front: a lazy stack guesses unseen heights and drops rows' pictures as they
                // scroll away, so the thread jumped near the top. A thread is `MessagesDB.threadLength` messages at most.
                VStack(spacing: 6) {
                    ForEach(Array(messages.enumerated()), id: \.element.id) { i, m in
                        if i == 0 || m.date.timeIntervalSince(messages[i - 1].date) > 3600 {
                            Text(separator.string(from: m.date))
                                .font(.caption).foregroundStyle(.secondary).padding(.vertical, 6)
                        }
                        let next = i + 1 < messages.count ? messages[i + 1] : nil
                        MessageRow(store: store, chat: chat, message: m,
                                   showAvatar: next == nil || next?.fromMe != m.fromMe || next?.sender != m.sender,
                                   quoted: quoted(m), swipe: pull(m),
                                   receipt: next == nil && waiting.isEmpty ? m.receipt : nil,
                                   reply: { replying = m })
                            .equatable()
                            .onGeometryChange(for: CGRect.self) { $0.frame(in: .named("panel")) } action: { rows.byGuid[m.guid] = $0 }
                            .onDisappear { rows.byGuid[m.guid] = nil }
                    }
                    ForEach(waiting) { p in
                        MessageRow(store: store, chat: chat, message: p.message, showAvatar: false, quoted: quoted(p.message),
                                   receipt: p.id == waiting.last?.id ? .sending : nil, isPending: true)
                            .transition(.scale(scale: 0.9, anchor: .bottomTrailing).combined(with: .opacity))
                    }
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 8)
            }
            .defaultScrollAnchor(.bottom)
            .defaultScrollAnchor(.bottom, for: .sizeChanges)
            .scrollIndicators(.never)
            .scrollPosition($position)
            .onScrollGeometryChange(for: Bool.self) { $0.visibleRect.maxY < $0.contentSize.height - 40 } action: { above = $1 }
            .overlay(alignment: .bottom) {
                ZStack { if above {
                    Button {
                        withAnimation(.smooth(duration: 0.35)) { position.scrollTo(edge: .bottom) }
                    } label: {
                        HStack(spacing: 6) { Text("See more"); Image(systemName: "chevron.down") }
                            .font(.callout.weight(.semibold)).foregroundStyle(.white)
                            .padding(.horizontal, 14).padding(.vertical, 8)
                            .background(Color.blue, in: .capsule)
                    }
                    .buttonStyle(.plain)
                    .padding(.bottom, 8)
                    .transition(.opacity.combined(with: .scale(scale: 0.9, anchor: .bottom)))
                } }
                .animation(.smooth(duration: 0.2), value: above)
            }
            Composer(store: store, chat: chat, replying: $replying)
        }
        .overlay {
            if dropping {
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .strokeBorder(Color.accentColor, lineWidth: 2).padding(4)
            }
        }
        .dropDestination(for: URL.self) { urls, _ in
            store.stage(urls, for: chat.id)  // into the message box; Send sends
            return true
        } isTargeted: { dropping = $0 }
        .onChange(of: messages, initial: true) {
            Preview.shared.urls = messages.flatMap { $0.media.map(\.url) }
        }
        .onAppear { monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { scrolled($0) ? nil : $0 } }
        .onDisappear { monitor.map(NSEvent.removeMonitor) }
    }

    private var messages: [Message] { store.threads[chat.id] ?? [] }

    /// My sends in this chat that chat.db doesn't have yet. They show after its rows.
    private var waiting: [Pending] { store.pending.filter { $0.chatID == chat.id } }

    private func quoted(_ m: Message) -> Message? { m.replyTo.flatMap { guid in messages.first { $0.guid == guid } } }

    /// How far the bubble has slid toward the middle of the panel, off its reply arrow.
    private func pull(_ m: Message) -> CGFloat {
        guard let swipe, swipe.guid == m.guid, swipe.sideways == true else { return 0 }
        return swipe.shown
    }

    /// Two fingers toward the middle of the panel pull a message off its reply arrow; letting go past the arrow
    /// replies, as in Messages. Up and down still scroll. Returns true for the events of a sideways swipe, so the
    /// thread stays put.
    private func scrolled(_ event: NSEvent) -> Bool {
        guard store.panelChat?.id == chat.id else { return false }  // the chat being switched away from
        if event.phase.isEmpty && event.momentumPhase.isEmpty { return false }  // a mouse wheel
        if event.phase == .began {
            let at = Preview.shared.host.map { $0.convert(event.locationInWindow, from: nil) } ?? .zero
            swipe = rows.byGuid.first { $0.value.contains(at) }.map { hit in
                Swipe(guid: hit.key, way: messages.first { $0.guid == hit.key }?.fromMe == true ? -1 : 1)
            }
            return false
        }
        guard var s = swipe else { return false }
        if !event.momentumPhase.isEmpty {
            if event.momentumPhase == .ended { swipe = nil }
            return s.momentum
        }
        // Natural scrolling reports finger travel as is; classic scrolling reports it reversed.
        let dx = event.isDirectionInvertedFromDevice ? event.scrollingDeltaX : -event.scrollingDeltaX
        switch event.phase {
        case .changed where s.sideways == nil:
            s.x += dx
            s.y += event.scrollingDeltaY
            if abs(s.x) + abs(s.y) > 6 { s.sideways = abs(s.x) > abs(s.y) }
            swipe = s.sideways == false ? nil : s
            return s.sideways == true
        case .changed where s.sideways == true:
            let before = s.pull >= replyReach
            s.x += dx
            if before != (s.pull >= replyReach) { NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now) }
            swipe = s
            return true
        case .ended, .cancelled:
            guard s.sideways == true else { swipe = nil; return false }
            if event.phase == .ended, s.pull >= replyReach, let m = messages.first(where: { $0.guid == s.guid }) {
                withAnimation(.smooth(duration: 0.2)) { replying = m }
            }
            withAnimation(.spring(duration: 0.3, bounce: 0.2)) {
                swipe = Swipe(guid: "", sideways: true, momentum: true)  // springs the row back, keeps eating momentum
            }
            return true
        default:
            return s.sideways == true
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Avatar(image: store.photo(chat), name: store.name(chat), size: 32)
            VStack(alignment: .leading, spacing: 1) {
                Text(store.name(chat)).font(.headline).lineLimit(1)
                if let last = messages.last {  // iMessage has no online status, so this is the only "when"
                    Text("Last message \(last.date.formatted(.relative(presentation: .named, unitsStyle: .narrow)))")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()
            Button { store.openInMessages(chat) } label: { Image(systemName: "arrow.up.left.and.arrow.down.right") }
                .buttonStyle(.plain).foregroundStyle(.secondary).help("Open in Messages")
                .accessibilityLabel("Open in Messages")
        }
        .padding(14)
    }
}

/// "Today, 8:38 AM" for separators; `inline` gives "today, 8:38 AM" for use mid-sentence.
private let separator = relativeFormatter(.standalone)
private let inline = relativeFormatter(.middleOfSentence)

extension Receipt {
    /// What Messages writes under the message.
    var label: String {
        switch self {
        case .sending: "Sending…"
        case .sent: "Sent"
        case .delivered: "Delivered"
        case .read(let date):
            "Read \(Calendar.current.isDateInToday(date) ? date.formatted(date: .omitted, time: .shortened) : inline.string(from: date))"
        case .failed: "Not Delivered"
        }
    }
}

private func relativeFormatter(_ context: Formatter.Context) -> DateFormatter {
    let f = DateFormatter()
    f.dateStyle = .short
    f.timeStyle = .short
    f.doesRelativeDateFormatting = true
    f.formattingContext = context
    return f
}

/// Equatable on what it shows, so a change elsewhere in the thread, or a swipe on another row, skips it.
struct MessageRow: View, Equatable {
    let store: Store
    let chat: Chat
    let message: Message
    let showAvatar: Bool
    /// The message this one replies to, when it's loaded.
    var quoted: Message?
    /// How far a two-finger swipe has pulled it toward replying.
    var swipe: CGFloat = 0
    /// Written under it: Messages does this for the thread's last message, when it's mine.
    var receipt: Receipt?
    var reply: () -> Void = {}
    /// Sent but not yet in chat.db: no menu or tapbacks yet.
    var isPending = false
    @State private var picking = false
    /// The picker was opened by the menu's smiley, so it opens the Mac's emoji picker straight away.
    @State private var pickingAny = false

    var body: some View {
        HStack(alignment: .bottom, spacing: 8) {
            if message.fromMe { Spacer(minLength: 40) } else { avatar }
            VStack(alignment: message.fromMe ? .trailing : .leading, spacing: 4) {
                if let quoted {
                    Label(quoted.text.isEmpty ? "Attachment" : quoted.text, systemImage: "arrowshape.turn.up.left")
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        .padding(.horizontal, 4)
                }
                VStack(alignment: message.fromMe ? .trailing : .leading, spacing: 4) {
                    ForEach(message.attachments.filter(\.isAudio), id: \.self) { AudioChip(url: $0.url) }
                    if !message.media.isEmpty { MediaGrid(items: message.media, trailing: message.fromMe) }
                    // A bare link shows as its card alone, as in Messages.
                    if !message.text.isEmpty, message.link == nil || message.text.contains(where: \.isWhitespace) {
                        Text(linkified(message.text))
                            .padding(.horizontal, 12).padding(.vertical, 8)
                            .background(.quaternary, in: .rect(cornerRadius: 16, style: .continuous))
                            .simultaneousGesture(TapGesture(count: 2).onEnded { picking = !isPending })  // links still take one click
                    }
                    if let link = message.link { LinkCard(link: link) }
                }
                .popover(isPresented: $picking, arrowEdge: .top) { tapbackBar }
                .overlay(alignment: message.fromMe ? .topLeading : .topTrailing) {
                    // Tapbacks sit on the bubble's top corner, as in Messages: mine in blue.
                    HStack(spacing: -6) {
                        ForEach(Array(badges.enumerated()), id: \.offset) { _, badge in
                            Text(badge.emoji).font(.system(size: 11))
                                .frame(width: 22, height: 22)
                                .background(badge.mine ? Color.blue : Color(white: 0.4), in: .circle)
                                .transition(.scale.combined(with: .opacity))
                        }
                    }
                    .offset(x: message.fromMe ? -10 : 10, y: -12)
                }
                if let when = store.reminders[message.guid], when > .now {
                    Label("Reminder \(inline.string(from: when))", systemImage: "bell.fill")
                        .font(.caption2).foregroundStyle(.secondary)
                        .transition(.blurReplace)
                }
                if let receipt {
                    Text(receipt.label).font(.caption2).foregroundStyle(receipt == .failed ? Color.red : Color.secondary)
                        .padding(.horizontal, 4)
                }
            }
            .contextMenu { if !isPending { menu.labelStyle(.titleAndIcon) } }
            .offset(x: swipe)
            .background(alignment: swipe < 0 ? .trailing : .leading) {
                // Laid out where the bubble rests, so it stays put while the bubble slides off it.
                Image(systemName: "arrowshape.turn.up.left.fill")
                    .foregroundStyle(abs(swipe) >= replyReach ? .primary : .secondary)
                    .frame(width: 28)
                    .scaleEffect(min(1, abs(swipe) / replyReach))
                    .opacity(min(1, abs(swipe) / replyReach))
            }
            if message.fromMe { avatar } else { Spacer(minLength: 40) }
        }
        .padding(.top, badges.isEmpty ? 0 : 10)  // room for the badges above the bubble
    }

    nonisolated static func == (a: Self, b: Self) -> Bool {
        a.message == b.message && a.chat == b.chat && a.showAvatar == b.showAvatar && a.quoted == b.quoted
            && a.swipe == b.swipe && a.receipt == b.receipt && a.isPending == b.isPending
    }

    private var mine: String? { store.mine(message) }

    /// The row under the six, as in Messages: my custom tapback first, if I have one, then my recent emoji, five in all.
    private var recent: [String] {
        let custom = mine.flatMap { emoji in HiddenMessages.tapbacks.contains { $0.emoji == emoji } ? nil : emoji }
        return Array(([custom].compactMap(\.self) + store.recentEmoji.filter { $0 != custom }).prefix(5))
    }

    /// Messages' tapback picker, from a double-click or the menu's smiley: the six, then the recent row and the smiley
    /// for any other. Mine is marked; picking it again takes it off.
    private var tapbackBar: some View {
        let mine = mine
        let pick = { (emoji: String) in
            picking = false
            store.react(emoji, to: message, in: chat)
        }
        return VStack(spacing: 2) {
            HStack(spacing: 2) {
                ForEach(HiddenMessages.tapbacks, id: \.key) { tapback in
                    EmojiButton(emoji: tapback.emoji, selected: mine == tapback.emoji) { pick(tapback.emoji) }
                        .accessibilityLabel(tapback.key)
                }
            }
            HStack(spacing: 2) {
                ForEach(recent, id: \.self) { emoji in
                    EmojiButton(emoji: emoji, selected: mine == emoji) { pick(emoji) }
                }
                MoreEmoji(openAtOnce: pickingAny) { pick(HiddenMessages.plain($0)) }
            }
        }
        .padding(6)
        .onDisappear { pickingAny = false }
    }

    private var avatar: some View {
        Group {
            if showAvatar {
                let name = message.fromMe ? store.contacts.me?.name ?? "Me" : message.sender.map(store.contacts.name) ?? ""
                Avatar(image: message.fromMe ? store.contacts.myPhoto : message.sender.flatMap(store.contacts.photo), name: name, size: 22)
            } else {
                Color.clear  // keeps the indent; an empty Group takes no space
            }
        }
        .frame(width: 22, height: 22)
    }

    /// chat.db's tapbacks, theirs then mine, with mine swapped for the one on its way, if any.
    private var badges: [(emoji: String, mine: Bool)] {
        var theirs = message.reactions
        if let old = message.mine, let i = theirs.firstIndex(of: old) { theirs.remove(at: i) }
        return theirs.map { ($0, false) } + (mine.map { [($0, true)] } ?? [])
    }

    @ViewBuilder private var menu: some View {
        let urls = message.attachments.map(\.url)
        // The double-click picker's two rows. The Mac's emoji picker needs a text field to type into and a menu can't hold
        // one, so this smiley opens the double-click picker with the emoji picker already up.
        ControlGroup {
            ForEach(HiddenMessages.tapbacks, id: \.key) { tapback in
                Button { store.react(tapback.emoji, to: message, in: chat) } label: { Image(nsImage: emojiImage(tapback.emoji)) }
                    .accessibilityLabel(tapback.key)
            }
        }
        .controlGroupStyle(.palette)
        ControlGroup {
            ForEach(recent, id: \.self) { emoji in
                Button { store.react(emoji, to: message, in: chat) } label: { Image(nsImage: emojiImage(emoji)) }
            }
            Button("More emoji", systemImage: "face.smiling") {
                pickingAny = true
                picking = true
            }
        }
        .controlGroupStyle(.palette)
        Button("Reply", systemImage: "arrowshape.turn.up.left", action: reply)
        Button("Copy", systemImage: "doc.on.doc") {
            if urls.isEmpty {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(message.text, forType: .string)
            } else {
                Clipboard.copy(urls)
            }
        }
        if urls.isEmpty { ShareLink(item: message.text) } else { ShareLink(items: urls) }
        if !urls.isEmpty {
            Button("Show in Finder", systemImage: "folder") { NSWorkspace.shared.activateFileViewerSelecting(urls) }
        }
        Divider()
        ForwardMenu(store: store, message: message, from: chat)
        Menu("Remind me", systemImage: "bell") {
            let cal = Calendar.current
            Button("In 1 hour") { remind(at: .now.addingTimeInterval(3600)) }
            if let d = cal.date(byAdding: .day, value: 1, to: .now).flatMap({ cal.date(bySettingHour: 9, minute: 0, second: 0, of: $0) }) {
                Button("Tomorrow, 9:00") { remind(at: d) }
            }
            if let d = cal.nextDate(after: .now, matching: DateComponents(hour: 9, minute: 0, weekday: 2), matchingPolicy: .nextTime) {
                Button("Monday, 9:00") { remind(at: d) }
            }
        }
    }

    private func remind(at date: Date) {
        Task { await store.remind(message, in: chat, at: date) }
    }
}

/// A view of its own, so only it redraws when the chat list changes, not every row whose menu holds it.
private struct ForwardMenu: View {
    let store: Store
    let message: Message
    let from: Chat

    var body: some View {
        Menu("Forward to", systemImage: "arrowshape.turn.up.right") {
            ForEach(store.chats.filter { $0.id != from.id }.prefix(8)) { target in
                Button(store.name(target)) {
                    Task {
                        if !message.text.isEmpty { await store.send(message.text, to: target) }
                        for url in message.attachments.map(\.url) { await store.send(file: url, to: target) }
                    }
                }
            }
        }
    }
}

/// A message's photos and videos, laid out as Messages does: one on its own, two or three in a row, and more in a
/// stack under their count. Clicking the count opens the stack out into a grid, and again gathers it back.
struct MediaGrid: View {
    let items: [Attachment]
    /// Mine, so the count lines up on the right.
    var trailing = false
    @State private var open = false

    var body: some View {
        if items.count == 1 {
            Thumbnail(item: items[0])
        } else if items.count < 4 {
            grid
        } else {
            VStack(alignment: trailing ? .trailing : .leading, spacing: 6) {
                Button { withAnimation(.smooth(duration: 0.25)) { open.toggle() } } label: {
                    Label(count, systemImage: open ? "square.stack.fill" : "square.grid.2x2.fill")
                        .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                if open { grid } else { stack }
            }
        }
    }

    private var grid: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.fixed(72), spacing: 4), count: min(3, items.count)), spacing: 4) {
            ForEach(items, id: \.self) { Thumbnail(item: $0, fill: CGSize(width: 72, height: 72)) }
        }
    }

    /// The first on top, and the next two tilted out from behind it.
    private var stack: some View {
        ZStack {
            ForEach(Array(items.prefix(3).enumerated().reversed()), id: \.offset) { i, item in
                Thumbnail(item: item, fill: CGSize(width: 168, height: 216))
                    .shadow(color: .black.opacity(0.3), radius: 3)
                    .scaleEffect(1 - CGFloat(i) * 0.05)
                    .rotationEffect(.degrees(Double(i) * 3))
                    .offset(x: CGFloat(i) * 9)
                    .allowsHitTesting(i == 0)
            }
        }
        .padding(.trailing, 18)
    }

    private var count: String {
        "\(items.count) \(items.allSatisfy(\.isImage) ? "Photos" : items.allSatisfy(\.isVideo) ? "Videos" : "Items")"
    }
}

/// Quick Look thumbnail for any file type. Click zooms it into Quick Look; drag copies the file out.
struct Thumbnail: View {
    let item: Attachment
    /// Crops the picture to fill this; otherwise it fits in a `side` square.
    var fill: CGSize?
    private let side: CGFloat = 220
    @State private var image: NSImage?
    @State private var hovering = false

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image).resizable().aspectRatio(contentMode: fill == nil ? .fit : .fill)
            } else {
                Rectangle().fill(.quaternary)
            }
        }
        .frame(width: fill?.width ?? (image == nil ? side * 0.7 : nil), height: fill?.height ?? (image == nil ? side * 0.5 : nil))
        .frame(maxWidth: fill?.width ?? side, maxHeight: fill?.height ?? side)
        .overlay {
            if item.isVideo { Image(systemName: "play.fill").font(.title2).foregroundStyle(.white).shadow(radius: 4) }
        }
        .clipShape(.rect(cornerRadius: (fill?.width ?? side) < 100 ? 10 : 14, style: .continuous))
        .scaleEffect(hovering ? 1.02 : 1)
        .animation(.smooth(duration: 0.15), value: hovering)
        .contentShape(.rect)
        .onHover { hovering = $0 }
        .onTapGesture { Preview.shared.toggle(item.url) }
        .draggable(item.url)
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .named("panel")) } action: { Preview.shared.frames[item.url] = $0 }
        .task(id: item.url) {
            let request = QLThumbnailGenerator.Request(fileAt: item.url, size: fill ?? CGSize(width: side, height: side),
                                                       scale: 2, representationTypes: .thumbnail)
            image = try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: request).nsImage
            Preview.shared.images[item.url] = image
        }
    }
}

/// The voice note playing now. Only one plays at a time, and closing the panel stops it.
var nowPlaying: AVAudioPlayer?

/// A voice note: click anywhere on it to play or pause.
struct AudioChip: View {
    let url: URL
    @State private var player: AVAudioPlayer?
    @State private var playing = false
    @State private var bars: [CGFloat] = []
    @State private var duration: TimeInterval = 0
    /// How far it has played, 0...1. Kept when paused.
    @State private var progress = 0.0

    var body: some View {
        Button(action: toggle) {
            HStack(spacing: 8) {
                Image(systemName: playing ? "pause.fill" : "play.fill")
                // Counts up while it plays, as in Messages; shows the length otherwise.
                Text(Duration.seconds(duration * (playing || progress > 0 ? progress : 1))
                    .formatted(.time(pattern: .minuteSecond)))
                    .font(.caption).monospacedDigit()
                HStack(spacing: 2) {
                    ForEach(bars.indices, id: \.self) { i in
                        Capsule().frame(width: 2, height: max(2, bars[i] * 16))
                            .foregroundStyle(Double(i) / Double(bars.count) < progress ? .primary : .secondary)
                    }
                }
                .frame(height: 16)
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
            .background(.quaternary, in: .capsule)
            .contentShape(.capsule)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(playing ? "Pause voice note" : "Play voice note")
        .task {
            duration = await Task.detached { [url] in (try? AVAudioFile(forReading: url)).map { Double($0.length) / $0.fileFormat.sampleRate } ?? 0 }.value
            bars = await Task.detached { [url] in waveform(url) }.value
        }
    }

    private func toggle() {
        if player == nil { player = try? AVAudioPlayer(contentsOf: url) }
        guard let player else { return }
        if player.isPlaying { player.pause(); playing = false; return }
        nowPlaying?.stop()
        nowPlaying = player
        guard player.play() else { return }
        playing = true
        Task {
            while player.isPlaying {
                progress = player.currentTime / max(player.duration, 0.01)
                try? await Task.sleep(for: .milliseconds(50))
            }
            playing = false
            progress = player.currentTime / max(player.duration, 0.01)  // 0 once it finished, where it stopped otherwise
        }
    }
}

/// RMS loudness of the first 5 minutes in 28 buckets, normalised to 0...1. Reads a few thousand frames at a time,
/// since every voice note in a thread does this when it opens.
nonisolated func waveform(_ url: URL) -> [CGFloat] {
    let bins = 28
    guard let file = try? AVAudioFile(forReading: url),
          let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 4096) else { return [] }
    let total = min(file.length, AVAudioFramePosition(file.processingFormat.sampleRate * 300))
    var sums = [Float](repeating: 0, count: bins), counts = [Int](repeating: 0, count: bins)
    var read: AVAudioFramePosition = 0
    while read < total, (try? file.read(into: buffer, frameCount: AVAudioFrameCount(min(4096, total - read)))) != nil,
          buffer.frameLength > 0, let samples = buffer.floatChannelData?[0] {
        for i in 0..<Int(buffer.frameLength) {
            let b = Int((read + AVAudioFramePosition(i)) * AVAudioFramePosition(bins) / total)
            sums[b] += samples[i] * samples[i]
            counts[b] += 1
        }
        read += AVAudioFramePosition(buffer.frameLength)
    }
    let rms = zip(sums, counts).map { $1 == 0 ? 0 : ($0 / Float($1)).squareRoot() }
    let peak = max(rms.max() ?? 0, .leastNonzeroMagnitude)
    return rms.map { CGFloat($0 / peak) }
}

struct Composer: View {
    let store: Store
    let chat: Chat
    /// The message a send goes in the thread of, from a swipe or the menu's Reply.
    @Binding var replying: Message?
    @State private var draft = ""
    @FocusState private var focused: Bool
    @State private var pasteMonitor: Any?

    /// Hovering another avatar in the menu bar previews where a click goes.
    private var placeholder: String {
        if let other = store.hoverChat, other.id != chat.id { return "Switch to \(store.shortName(other))" }
        return "\(replying == nil ? "Note" : "Reply") to \(store.shortName(chat))…"
    }

    private var recordingVoice: Bool { store.recorder.kind == .voice && store.recorder.chatID == chat.id }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let replying {
                HStack(spacing: 6) {
                    Label(replying.text.isEmpty ? "Attachment" : replying.text, systemImage: "arrowshape.turn.up.left")
                        .lineLimit(1)
                    Spacer(minLength: 0)
                    Button { self.replying = nil } label: { Image(systemName: "xmark") }
                        .buttonStyle(.plain).accessibilityLabel("Cancel reply")
                }
                .font(.caption).foregroundStyle(.secondary)
                .transition(.blurReplace)
            }
            if let files = store.drafts[chat.id], !files.isEmpty {
                ScrollView(.horizontal) {
                    HStack(spacing: 6) {
                        ForEach(files, id: \.self) { file in
                            DraftChip(url: file) { store.unstage(file, from: chat.id) }
                        }
                    }
                }
                .scrollIndicators(.never)
            }
            if recordingVoice {
                LiveWaveform(levels: store.recorder.levels).frame(height: 20)
            } else {
                TextField(placeholder, text: $draft, axis: .vertical)
                    .textFieldStyle(.plain)
                    .lineLimit(1...5)
                    .focused($focused)
                    .onSubmit(sendAll)
                    .onKeyPress(.escape) {  // Esc drops the reply first, then closes the panel
                        guard replying != nil else { return .ignored }
                        withAnimation(.smooth(duration: 0.2)) { replying = nil }
                        return .handled
                    }
            }
            if let error = store.sendError {
                Text(error).font(.caption).foregroundStyle(.secondary)
            }
            HStack(spacing: 14) {
                let recorder = store.recorder
                if recorder.kind != nil, recorder.chatID == chat.id {
                    Image(systemName: "circle.fill").font(.system(size: 8)).foregroundStyle(.red)
                    Group {
                        if recorder.finishing {
                            Text("Preparing…")
                        } else if recorder.kind == .screen {
                            Text(recorder.stopHint)
                        } else {
                            TimelineView(.periodic(from: recorder.started, by: 1)) { context in
                                Text("Recording \(Duration.seconds(context.date.timeIntervalSince(recorder.started)).formatted(.time(pattern: .minuteSecond)))")
                            }
                            .monospacedDigit()
                        }
                    }
                    .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    tool("xmark", "Discard recording") { recorder.discard() }
                    if recorder.kind == .voice {
                        sendButton("Send", action: finishRecording)
                    }
                } else {
                    Group {
                        tool("waveform", "Record voice") { store.record(.voice, for: chat) }
                        tool("record.circle", "Record screen") { store.record(.screen, for: chat) }
                    }
                    .disabled(recorder.kind != nil)  // already recording for another chat
                    tool("paperclip", "Attach", action: attach)
                    Spacer()
                    sendButton("Send ↵", action: sendAll)
                        .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && store.drafts[chat.id, default: []].isEmpty)
                }
            }
        }
        .padding(12)
        .background(.quaternary, in: .rect(cornerRadius: 18, style: .continuous))
        .padding(10)
        .animation(.smooth(duration: 0.2), value: replying?.guid)
        .onChange(of: replying?.guid) { if replying != nil { focused = true } }
        // Ready to type the moment the panel opens or switches here. The panel is key by the time this runs.
        .task(id: store.panelShown) { if store.panelShown { focused = true } }
        // ⌘V with files or a picture on the clipboard puts them in the box, as a drop does. Text pastes as usual.
        .onAppear {
            pasteMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
                guard event.window is KeyablePanel, store.panelShown, store.panelChat?.id == chat.id,
                      event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
                      event.charactersIgnoringModifiers == "v",
                      let files = Clipboard.pastedFiles() else { return event }
                store.stage(files, for: chat.id)
                return nil
            }
        }
        .onDisappear { pasteMonitor.map(NSEvent.removeMonitor) }
    }

    /// Sends what's in the box: staged files, then the text. Clears the field at once; a failed send puts the
    /// text back so nothing typed is lost.
    private func sendAll() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty || !store.drafts[chat.id, default: []].isEmpty else { return }
        let original = replying
        draft = ""
        replying = nil
        Task {
            if await !store.sendDraft(text: text, to: chat, replyingTo: original), draft.isEmpty {
                draft = text
                replying = original
            }
        }
    }

    private func attach() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        guard panel.runModal() == .OK else { return }
        store.stage(panel.urls, for: chat.id)
        focused = true  // for a caption
    }

    private func finishRecording() {
        store.finishRecording(to: chat, replyingTo: replying)
        replying = nil
    }

    private func tool(_ symbol: String, _ label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: symbol) }
            .buttonStyle(.plain).foregroundStyle(.secondary).help(label).accessibilityLabel(label)
    }

    private func sendButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).font(.caption.weight(.medium))
                .padding(.horizontal, 10).padding(.vertical, 4)
                .background(.quaternary, in: .capsule)
        }
        .buttonStyle(.plain)
    }
}

/// A link's card: the page's picture, title and site, from the preview Messages saved. Click opens the link.
struct LinkCard: View {
    let link: LinkPreview
    @State private var image: NSImage?

    var body: some View {
        Button { NSWorkspace.shared.open(link.url) } label: {
            VStack(alignment: .leading, spacing: 0) {
                if let image {
                    Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
                        .frame(width: 240, height: min(160, 240 * image.size.height / max(image.size.width, 1)))
                        .clipped()
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(link.title ?? link.url.host() ?? link.url.absoluteString)
                        .font(.callout.weight(.semibold)).lineLimit(2).multilineTextAlignment(.leading)
                    Text(link.site ?? link.url.host() ?? "").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                .padding(.horizontal, 12).padding(.vertical, 9)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(width: 240)
            .background(.quaternary)
            .clipShape(.rect(cornerRadius: 16, style: .continuous))
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .help(link.url.absoluteString)
        .task(id: link.image) {
            guard let file = link.image else { return }
            let data = await Task.detached { try? Data(contentsOf: file) }.value  // no extension, so read it as data
            image = data.flatMap(NSImage.init(data:))
        }
    }
}

/// How far a message is pulled sideways before letting go replies to it.
private let replyReach: CGFloat = 56

/// The microphone's loudness while recording, newest on the right. Quiet stretches read as dots.
struct LiveWaveform: View {
    let levels: [CGFloat]

    var body: some View {
        Canvas { context, size in
            let pitch: CGFloat = 4, count = Int(size.width / pitch)
            let shown = Array(repeating: 0, count: max(0, count - levels.count)) + levels.suffix(count)
            for (i, level) in shown.enumerated() {
                let h = max(2, level * size.height)
                let bar = CGRect(x: CGFloat(i) * pitch, y: (size.height - h) / 2, width: 2, height: h)
                context.fill(Path(roundedRect: bar, cornerRadius: 1), with: .color(level < 0.06 ? .secondary : .primary))
            }
        }
        .accessibilityHidden(true)
    }
}

/// One tapback in the double-click bar. Grows under the pointer.
private struct EmojiButton: View {
    let emoji: String
    let selected: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Text(emoji).font(.system(size: 20))
                .frame(width: 34, height: 34)
                .background(selected ? AnyShapeStyle(.quaternary) : AnyShapeStyle(.clear), in: .circle)
                .scaleEffect(hovering ? 1.15 : 1)
                .animation(.smooth(duration: 0.12), value: hovering)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

/// The smiley that ends the tapback picker: opens the Mac's emoji picker and hands back the emoji you choose. The picker
/// types into whatever has focus, so an invisible field under the smiley takes focus first. `openAtOnce` opens it as
/// the smiley appears, for the right-click menu's smiley.
private struct MoreEmoji: View {
    var openAtOnce = false
    let chosen: (String) -> Void
    @State private var typed = ""
    @FocusState private var focused: Bool

    var body: some View {
        Button(action: open) {
            Image(systemName: "face.smiling").font(.system(size: 20)).foregroundStyle(.secondary)
                .frame(width: 34, height: 34).contentShape(.circle)
        }
        .buttonStyle(.plain)
        .background {
            TextField("", text: $typed).focused($focused).frame(width: 1, height: 1).opacity(0).accessibilityHidden(true)
        }
        .onChange(of: typed) { _, text in
            // Typed letters aren't tapbacks; digits are emoji only with a keycap after them.
            guard let last = text.last, let first = last.unicodeScalars.first?.properties,
                  first.isEmojiPresentation || first.isEmoji && last.unicodeScalars.count > 1 else { return }
            chosen(String(last))
        }
        .accessibilityLabel("More emoji")
        .onAppear { if openAtOnce { open() } }
    }

    private func open() {
        focused = true
        DispatchQueue.main.async { NSApp.orderFrontCharacterPalette(nil) }
    }
}

/// A file waiting in the message box: its thumbnail, and an × to take it out.
struct DraftChip: View {
    let url: URL
    let remove: () -> Void
    @State private var image: NSImage?

    var body: some View {
        Group {
            if let image { Image(nsImage: image).resizable().scaledToFill() } else { Rectangle().fill(.quaternary) }
        }
        .frame(width: 52, height: 52)
        .clipShape(.rect(cornerRadius: 10, style: .continuous))
        .overlay(alignment: .topTrailing) {
            Button(action: remove) {
                Image(systemName: "xmark.circle.fill").symbolRenderingMode(.palette).foregroundStyle(.white, .black.opacity(0.6))
            }
            .buttonStyle(.plain).padding(3)
            .accessibilityLabel("Remove \(url.lastPathComponent)")
        }
        .help(url.lastPathComponent)
        .task(id: url) {
            let request = QLThumbnailGenerator.Request(fileAt: url, size: CGSize(width: 52, height: 52), scale: 2, representationTypes: .thumbnail)
            image = try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: request).nsImage
        }
    }
}

/// Menu palettes draw images only, so a tapback's emoji is drawn into one.
private func emojiImage(_ emoji: String) -> NSImage {
    NSImage(size: NSSize(width: 24, height: 24), flipped: false) { rect in
        let text = NSAttributedString(string: emoji, attributes: [.font: NSFont.systemFont(ofSize: 18)])
        let size = text.size()
        text.draw(at: NSPoint(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2))
        return true
    }
}

/// A contact photo, or initials on grey. Round unless given a corner radius (the menu bar uses rounded squares).
struct Avatar: View {
    let image: NSImage?
    let name: String
    var size: CGFloat = 28
    var cornerRadius: CGFloat?

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image).resizable().scaledToFill()
            } else {
                let initials = name.split(separator: " ").prefix(2).compactMap { $0.first(where: \.isLetter) }
                ZStack {
                    Rectangle().fill(.gray.gradient)
                    if initials.isEmpty { Image(systemName: "person.fill").font(.system(size: size * 0.5)) }
                    else { Text(String(initials).uppercased()).font(.system(size: size * 0.4, weight: .semibold)) }
                }
                .foregroundStyle(.white)
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius ?? size / 2, style: .continuous))
        .accessibilityLabel(name)
    }
}

private let linkDetector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)

/// Makes bare URLs in message text clickable.
private func linkified(_ text: String) -> AttributedString {
    var out = AttributedString(text)
    for match in linkDetector?.matches(in: text, range: NSRange(text.startIndex..., in: text)) ?? [] {
        if let range = Range(match.range, in: out), let url = match.url { out[range].link = url }
    }
    return out
}
