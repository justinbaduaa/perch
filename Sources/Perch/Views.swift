import AVFoundation
import QuickLookThumbnailing
import SwiftUI

/// Contents of the menu bar panel: one conversation, or why there is none.
struct PanelRoot: View {
    let store: Store
    let openInMessages: () -> Void
    let close: () -> Void

    var body: some View {
        Group {
            if store.needsAccess {
                AccessView()
            } else if let error = store.readError {
                ContentUnavailableView("Can't read Messages", systemImage: "exclamationmark.bubble", description: Text(error))
            } else if let chat = store.panelChat {
                ConversationView(store: store, chat: chat, openInMessages: openInMessages)
                    .id(chat.id)
                    .transition(.blurReplace)
            } else {
                PeopleView(store: store)
            }
        }
        .frame(width: 340, height: 540)
        .coordinateSpace(.named("panel"))  // thumbnails report here, for Quick Look's zoom
        // The window grows from a pill while this blurs in, so pin the content to the top and clip it.
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .clipped()
        .blur(radius: store.panelShown ? 0 : 14)
        .opacity(store.panelShown ? 1 : 0)
        .onExitCommand(perform: close)
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
                            }
                            .padding(.horizontal, 10).padding(.vertical, 6)
                            .background(hovered == chat.id ? AnyShapeStyle(.quaternary) : AnyShapeStyle(.clear),
                                        in: .rect(cornerRadius: 10, style: .continuous))
                            .contentShape(.rect)
                        }
                        .buttonStyle(.plain)
                        .onHover { hovered = $0 ? chat.id : nil }
                    }
                }
                .padding(.horizontal, 6).padding(.bottom, 8)
            }
            .scrollIndicators(.never)
        }
        .task {
            try? await Task.sleep(for: .milliseconds(400))  // after the panel has grown and become key, or focus won't stick
            focused = true
        }
    }

    private func open(_ chat: Chat) {
        withAnimation(.smooth(duration: 0.3)) { store.panelChat = chat }
        store.onChange()  // the strip rings the open chat
    }
}

struct AccessView: View {
    var body: some View {
        ContentUnavailableView {
            Label("Full Disk Access", systemImage: "lock")
        } description: {
            Text("Perch reads your conversations from Messages.")
        } actions: {
            Button("Open Settings") {
                NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!)
            }
        }
    }
}

struct ConversationView: View {
    let store: Store
    let chat: Chat
    let openInMessages: () -> Void
    @State private var messages: [Message] = []
    @State private var dropping = false

    var body: some View {
        VStack(spacing: 0) {
            header
            ScrollView {
                LazyVStack(spacing: 6) {
                    ForEach(messages.indices, id: \.self) { i in
                        let m = messages[i]
                        if i == 0 || m.date.timeIntervalSince(messages[i - 1].date) > 3600 {
                            Text(separator.string(from: m.date))
                                .font(.caption).foregroundStyle(.secondary).padding(.vertical, 6)
                        }
                        let next = i + 1 < messages.count ? messages[i + 1] : nil
                        MessageRow(store: store, chat: chat, message: m,
                                   showAvatar: next == nil || next?.fromMe != m.fromMe || next?.sender != m.sender)
                            .id(m.id)
                    }
                    ForEach(store.pending.filter { $0.chatID == chat.id && !$0.landed(in: messages) }) { p in
                        MessageRow(store: store, chat: chat, message: p.message, showAvatar: false, isPending: true)
                            .transition(.scale(scale: 0.9, anchor: .bottomTrailing).combined(with: .opacity))
                    }
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 8)
            }
            .defaultScrollAnchor(.bottom)
            .defaultScrollAnchor(.bottom, for: .sizeChanges)
            .scrollIndicators(.never)
            Composer(store: store, chat: chat)
        }
        .overlay {
            if dropping {
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .strokeBorder(Color.accentColor, lineWidth: 2).padding(4)
            }
        }
        .dropDestination(for: URL.self) { urls, _ in
            Task { for url in urls { await store.send(file: url, to: chat) } }
            return true
        } isTargeted: { dropping = $0 }
        .task(id: "\(chat.id)-\(store.revision)") {
            messages = store.messages(for: chat)
            Preview.shared.urls = messages.flatMap { $0.attachments.filter { !$0.isAudio }.map(\.url) }
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Avatar(image: store.photo(chat), name: store.name(chat), size: 32)
            VStack(alignment: .leading, spacing: 1) {
                Text(store.name(chat)).font(.headline).lineLimit(1)
                if let last = messages.last(where: { !$0.fromMe }) {
                    Text("Active \(last.date.formatted(.relative(presentation: .named, unitsStyle: .narrow)))")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()
            Button(action: openInMessages) { Image(systemName: "arrow.up.left.and.arrow.down.right") }
                .buttonStyle(.plain).foregroundStyle(.secondary).help("Open in Messages")
                .accessibilityLabel("Open in Messages")
        }
        .padding(14)
    }
}

/// "Today, 8:38 AM" for separators; `inline` gives "today, 8:38 AM" for use mid-sentence.
private let separator = relativeFormatter(.standalone)
private let inline = relativeFormatter(.middleOfSentence)

private func relativeFormatter(_ context: Formatter.Context) -> DateFormatter {
    let f = DateFormatter()
    f.dateStyle = .short
    f.timeStyle = .short
    f.doesRelativeDateFormatting = true
    f.formattingContext = context
    return f
}

struct MessageRow: View {
    let store: Store
    let chat: Chat
    let message: Message
    let showAvatar: Bool
    /// Sent but not yet in chat.db: dimmed, with an upload mark on files, and no menu.
    var isPending = false

    var body: some View {
        HStack(alignment: .bottom, spacing: 8) {
            if message.fromMe { Spacer(minLength: 40) } else { avatar }
            VStack(alignment: message.fromMe ? .trailing : .leading, spacing: 4) {
                ForEach(message.attachments.filter(\.isAudio), id: \.self) { AudioChip(url: $0.url) }
                let media = message.attachments.filter { !$0.isAudio }
                if !media.isEmpty {
                    MediaGrid(items: media).overlay(alignment: .topTrailing) {
                        if isPending {
                            Image(systemName: "icloud.and.arrow.up").font(.caption)
                                .padding(6).background(.ultraThinMaterial, in: .circle).padding(6)
                        }
                    }
                }
                if !message.text.isEmpty {
                    Text(linkified(message.text))
                        .padding(.horizontal, 12).padding(.vertical, 8)
                        .background(.quaternary, in: .rect(cornerRadius: 16, style: .continuous))
                }
                if !message.reactions.isEmpty {
                    Text(message.reactions.joined()).font(.caption)
                }
                if let when = store.reminders[message.guid], when > .now {
                    Label("Reminder \(inline.string(from: when))", systemImage: "bell.fill")
                        .font(.caption2).foregroundStyle(.secondary)
                        .transition(.blurReplace)
                }
            }
            .opacity(isPending ? 0.55 : 1)
            .contextMenu { if !isPending { menu.labelStyle(.titleAndIcon) } }
            if message.fromMe { avatar } else { Spacer(minLength: 40) }
        }
    }

    private var avatar: some View {
        Group {
            if showAvatar {
                let name = message.fromMe ? store.contacts.me?.name ?? "Me" : message.sender.map(store.contacts.name) ?? ""
                Avatar(image: store.contacts.photo(message.fromMe ? nil : message.sender ?? ""), name: name, size: 22)
            } else {
                Color.clear  // keeps the indent; an empty Group takes no space
            }
        }
        .frame(width: 22, height: 22)
    }

    @ViewBuilder private var menu: some View {
        let urls = message.attachments.map(\.url)
        Button("Copy", systemImage: "doc.on.doc") {
            NSPasteboard.general.clearContents()
            if urls.isEmpty { NSPasteboard.general.setString(message.text, forType: .string) }
            else { NSPasteboard.general.writeObjects(urls as [NSURL]) }
        }
        if urls.isEmpty { ShareLink(item: message.text) } else { ShareLink(items: urls) }
        if !urls.isEmpty {
            Button("Show in Finder", systemImage: "folder") { NSWorkspace.shared.activateFileViewerSelecting(urls) }
        }
        Divider()
        Menu("Forward to", systemImage: "arrowshape.turn.up.right") {
            ForEach(store.chats.filter { $0.id != chat.id }.prefix(8)) { target in
                Button(store.name(target)) {
                    Task {
                        if !message.text.isEmpty { await store.send(message.text, to: target) }
                        for url in urls { await store.send(file: url, to: target) }
                    }
                }
            }
        }
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

struct MediaGrid: View {
    let items: [Attachment]

    var body: some View {
        if items.count == 1 {
            Thumbnail(item: items[0], side: 220, square: false)
        } else {
            LazyVGrid(columns: Array(repeating: GridItem(.fixed(72), spacing: 4), count: min(3, items.count)), spacing: 4) {
                ForEach(items, id: \.self) { Thumbnail(item: $0, side: 72, square: true) }
            }
        }
    }
}

/// Quick Look thumbnail for any file type. Click zooms it into Quick Look; drag copies the file out.
struct Thumbnail: View {
    let item: Attachment
    let side: CGFloat
    let square: Bool
    @State private var image: NSImage?
    @State private var hovering = false

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image).resizable().aspectRatio(contentMode: square ? .fill : .fit)
            } else {
                Rectangle().fill(.quaternary)
            }
        }
        .frame(width: square || image == nil ? side * (square ? 1 : 0.7) : nil,
               height: square || image == nil ? side * (square ? 1 : 0.5) : nil)
        .frame(maxWidth: side, maxHeight: side)
        .overlay {
            if item.isVideo { Image(systemName: "play.fill").font(.title2).foregroundStyle(.white).shadow(radius: 4) }
        }
        .clipShape(.rect(cornerRadius: square ? 10 : 14, style: .continuous))
        .scaleEffect(hovering ? 1.02 : 1)
        .animation(.smooth(duration: 0.15), value: hovering)
        .contentShape(.rect)
        .onHover { hovering = $0 }
        .onTapGesture { Preview.shared.toggle(item.url) }
        .draggable(item.url)
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .named("panel")) } action: { Preview.shared.frames[item.url] = $0 }
        .task(id: item.url) {
            let request = QLThumbnailGenerator.Request(fileAt: item.url, size: CGSize(width: side, height: side),
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

    var body: some View {
        Button(action: toggle) {
            HStack(spacing: 8) {
                Image(systemName: playing ? "pause.fill" : "play.fill")
                Text(Duration.seconds(player?.duration ?? 0).formatted(.time(pattern: .minuteSecond)))
                    .font(.caption).monospacedDigit()
                HStack(spacing: 2) {
                    ForEach(bars.indices, id: \.self) { Capsule().frame(width: 2, height: max(2, bars[$0] * 16)) }
                }
                .frame(height: 16)
                .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
            .background(.quaternary, in: .capsule)
            .contentShape(.capsule)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(playing ? "Pause voice note" : "Play voice note")
        .task {
            player = try? AVAudioPlayer(contentsOf: url)
            bars = await Task.detached { [url] in waveform(url) }.value
        }
    }

    private func toggle() {
        guard let player else { return }
        if player.isPlaying { player.pause(); playing = false; return }
        nowPlaying?.stop()
        nowPlaying = player
        player.play()
        playing = true
        Task {
            while player.isPlaying { try? await Task.sleep(for: .milliseconds(250)) }
            playing = false
        }
    }
}

/// RMS loudness in `bins` buckets, normalised to 0...1. Reads at most the first 5 minutes.
nonisolated func waveform(_ url: URL, bins: Int = 28) -> [CGFloat] {
    guard let file = try? AVAudioFile(forReading: url),
          let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat,
                                        frameCapacity: AVAudioFrameCount(min(file.length, Int64(file.fileFormat.sampleRate * 300)))),
          (try? file.read(into: buffer)) != nil,
          let samples = buffer.floatChannelData?[0], buffer.frameLength > 0 else { return [] }
    let step = max(1, Int(buffer.frameLength) / bins)
    let rms = (0..<bins).map { b -> Float in
        let range = (b * step)..<min((b + 1) * step, Int(buffer.frameLength))
        guard !range.isEmpty else { return 0 }
        return (range.reduce(Float(0)) { $0 + samples[$1] * samples[$1] } / Float(range.count)).squareRoot()
    }
    let peak = max(rms.max() ?? 0, .leastNonzeroMagnitude)
    return rms.map { CGFloat($0 / peak) }
}

struct Composer: View {
    let store: Store
    let chat: Chat
    @State private var draft = ""

    /// Hovering another avatar in the menu bar previews where a click goes.
    private var placeholder: String {
        if let other = store.hoverChat, other.id != chat.id { return "Switch to \(store.shortName(other))" }
        return "Note to \(store.shortName(chat))…"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            TextField(placeholder, text: $draft, axis: .vertical)
                .textFieldStyle(.plain)
                .lineLimit(1...5)
                .onSubmit(sendText)
            if let error = store.sendError {
                Text(error).font(.caption).foregroundStyle(.secondary)
            }
            HStack(spacing: 14) {
                let recorder = store.recorder
                if recorder.kind != nil, recorder.chatID == chat.id {
                    Image(systemName: "circle.fill").font(.system(size: 8))
                        .foregroundStyle(recorder.ready == nil ? AnyShapeStyle(.red) : AnyShapeStyle(.secondary))
                    Group {
                        if let ready = recorder.ready {
                            Text(ready.pathExtension == "png" ? "Screenshot" : "Screen recording")
                        } else if recorder.finishing {
                            Text("Preparing…")
                        } else if recorder.kind == .screen {
                            Text(recorder.stopHint)
                        } else {
                            TimelineView(.periodic(from: recorder.started, by: 1)) { context in
                                Text(Duration.seconds(context.date.timeIntervalSince(recorder.started)).formatted(.time(pattern: .minuteSecond)))
                            }
                            .monospacedDigit()
                        }
                    }
                    .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    tool("xmark", "Discard recording") { recorder.discard(); store.onChange() }
                    if recorder.kind == .voice || recorder.ready != nil {
                        sendButton("Send", action: finishRecording).disabled(recorder.finishing)
                    }
                } else {
                    Group {
                        tool("waveform", "Record voice") { record(.voice) }
                        tool("record.circle", "Record screen") { record(.screen) }
                    }
                    .disabled(recorder.kind != nil)  // already recording for another chat
                    tool("paperclip", "Attach", action: attach)
                    Spacer()
                    sendButton("Send ↵", action: sendText)
                        .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
        .padding(12)
        .background(.quaternary, in: .rect(cornerRadius: 18, style: .continuous))
        .padding(10)
    }

    /// Clears the field at once; a failed send puts the text back so nothing typed is lost.
    private func sendText() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        draft = ""
        Task {
            if await !store.send(text, to: chat), draft.isEmpty { draft = text }
        }
    }

    private func attach() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        guard panel.runModal() == .OK else { return }
        let urls = panel.urls
        Task { for url in urls { await store.send(file: url, to: chat) } }
    }

    private func record(_ kind: Recorder.Kind) {
        Task {
            do {
                try await store.recorder.start(kind, for: chat)
                store.sendError = nil
                store.onChange()  // the strip rings the chat being recorded
                if kind == .screen { store.hidePanel() }  // out of the way of the toolbar and out of the recording
            } catch {
                store.sendError = error.localizedDescription
            }
        }
    }

    /// Stops the recording and sends it.
    private func finishRecording() {
        Task {
            do {
                if let file = try await store.recorder.stop() { await store.send(file: file, to: chat) }
            } catch {
                store.sendError = error.localizedDescription
            }
            store.onChange()
        }
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

/// Makes bare URLs in message text clickable.
private func linkified(_ text: String) -> AttributedString {
    var out = AttributedString(text)
    let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)
    for match in detector?.matches(in: text, range: NSRange(text.startIndex..., in: text)) ?? [] {
        if let range = Range(match.range, in: out), let url = match.url { out[range].link = url }
    }
    return out
}
