import SwiftUI
import UniformTypeIdentifiers
import UserNotifications

/// A send shown in the thread before Messages has written its row.
struct Pending: Identifiable {
    let id: Int64  // negative, so it never collides with a chat.db ROWID
    let chatID: Int64
    let text: String
    let file: URL?
    var date = Date.now
    var replyTo: String?

    var message: Message {
        let mime = file.flatMap { UTType(filenameExtension: $0.pathExtension)?.preferredMIMEType } ?? ""
        return Message(id: id, guid: "", date: date, fromMe: true, sender: nil, text: text,
                       attachments: file.map { [Attachment(url: $0, mime: mime)] } ?? [], replyTo: replyTo)
    }

    /// True once chat.db has a row from me that matches: same text, or an attachment with the same file name.
    func landed(in messages: [Message]) -> Bool {
        messages.contains { m in
            guard m.fromMe, m.date > date.addingTimeInterval(-5) else { return false }
            guard let file else { return m.text == text }
            return m.attachments.contains { $0.url.lastPathComponent == file.lastPathComponent }
        }
    }
}

/// App state. Polls chat.db off the main thread, and keeps the open chat's thread loaded.
@Observable final class Store {
    private(set) var chats: [Chat] = []
    /// The last messages of chats opened in the panel. Only the open one is kept up to date; switching back to
    /// another shows what it had while that reloads.
    private(set) var threads: [Int64: [Message]] = [:]
    private(set) var needsAccess = false
    /// Why chat.db could not be read when it is readable, shown in the panel instead of failing silently.
    private(set) var readError: String?
    private(set) var pending: [Pending] = []
    private(set) var sendError: String?
    /// Files waiting in each chat's message box for Send.
    private(set) var drafts: [Int64: [URL]] = [:]
    /// My tapback on a message while it's on its way (nil value: being removed), shown until chat.db has it.
    private(set) var tapbacks: [String: String?] = [:]
    /// Messages' row of recent emoji tapbacks. Picking one sends it through Messages, which adds a row, so it's read
    /// again whenever chat.db changes.
    private(set) var recentEmoji: [String] = []
    let recorder = Recorder()
    /// Message guid to reminder time. The system keeps the reminders, as pending notifications keyed by guid.
    private(set) var reminders: [String: Date] = [:]
    /// Chats held at the front of the menu bar, by guid, in the order they were pinned.
    private(set) var pins = UserDefaults.standard.stringArray(forKey: "pins") ?? []
    /// The chat in the panel. Opening one reads it, as far as the bar's rings go.
    var panelChat: Chat? {
        didSet {
            markSeen(panelChat)
            Task { await poll() }  // loads its thread now rather than at the next tick
        }
    }
    var panelShown = false
    /// The menu bar avatar under the pointer.
    var hoverChat: Chat?
    let contacts = ContactBook()
    /// Set by the app delegate, which owns the panel.
    @ObservationIgnored var showPanel: (Chat) -> Void = { _ in }
    @ObservationIgnored var hidePanel: () -> Void = {}
    @ObservationIgnored var showSetup: () -> Void = {}

    @ObservationIgnored private var db: MessagesDB?
    /// chat.db's mark (`MessagesDB.mark`) when the chat list last loaded; any change reloads.
    @ObservationIgnored private var lastMark: Int64?
    /// The mark each thread was loaded at.
    @ObservationIgnored private var loadedAt: [Int64: Int64] = [:]
    /// The open chat and the oldest message its thread loaded with. Later loads start there, so a new message adds to
    /// the end instead of pushing the oldest off the top, which moved whatever was being read.
    @ObservationIgnored private var threadStart: (chat: Int64, message: Int64)?
    /// Group pictures as avatar-sized thumbnails; nil for one that won't load.
    @ObservationIgnored private var groupPhotos: [URL: NSImage?] = [:]
    @ObservationIgnored private var nextPendingID: Int64 = -1
    /// The latest send. Each waits for the one before, so they go out in the order they were sent, as in Messages.
    @ObservationIgnored private var lastSend: Task<Bool, Never>?
    /// Chat guid to the newest unread row opened in Perch, so the bar rings only what came after.
    private var seen = UserDefaults.standard.dictionary(forKey: "seen") as? [String: Int] ?? [:]
    /// Chat guids marked unread from Perch, ringed until opened.
    private var markedUnread = Set(UserDefaults.standard.stringArray(forKey: "markedUnread") ?? [])
    /// Messages' Hide Alerts list, as of the last poll, and what Perch has set since.
    private var mutedKeys: Set<String> = []
    private var mutedOverride: [String: Bool] = [:]
    /// Chats on their way out, kept off the bar until chat.db drops them.
    @ObservationIgnored private var deleting: Set<Int64> = []

    func start() {
        recorder.onScreenEnded = { [unowned self] id, file in
            if let file { stage([file], for: id) }  // a finished capture waits for Send
            if let chat = chats.first(where: { $0.id == id }) { showPanel(chat) }
        }
        Task { await contacts.load() }
        Task {
            let requests = await UNUserNotificationCenter.current().pendingNotificationRequests()
            for r in requests {
                reminders[r.identifier] = (r.trigger as? UNCalendarNotificationTrigger)?.nextTriggerDate()
            }
        }
        Task {
            while true {
                await poll()
                try? await Task.sleep(for: .seconds(1.5))
            }
        }
    }

    /// Pinned chats, then the people you talked to last, whoever sent the last message. A chat you're recording
    /// for goes first, so the recording is one click away after the panel closes.
    var barChats: [Chat] {
        let recording = chats.filter { $0.id == recorder.chatID }
        let pinned = pins.compactMap { guid in chats.first { $0.guid == guid } }
        var ids = Set<Int64>()
        return Array((recording + pinned + chats).filter { ids.insert($0.id).inserted }.prefix(5))
    }

    func togglePin(_ chat: Chat) {
        if pins.contains(chat.guid) { pins.removeAll { $0 == chat.guid } } else { pins.append(chat.guid) }
        UserDefaults.standard.set(pins, forKey: "pins")
    }

    /// Something they sent that I haven't opened in Perch or answered, or a chat I marked unread.
    func isUnread(_ chat: Chat) -> Bool {
        markedUnread.contains(chat.guid) || chat.unread.map { $0 > seen[chat.guid] ?? 0 } ?? false
    }

    private func markSeen(_ chat: Chat?) {
        guard let chat = chats.first(where: { $0.id == chat?.id }) else { return }
        let row = chat.unread.map(Int.init) ?? seen[chat.guid]
        // Checked first: even a remove that finds nothing tells observers, and the strip would redraw every poll.
        guard markedUnread.contains(chat.guid) || seen[chat.guid] != row else { return }
        markedUnread.remove(chat.guid)
        seen[chat.guid] = row
        UserDefaults.standard.set(seen, forKey: "seen")
        UserDefaults.standard.set(Array(markedUnread), forKey: "markedUnread")
    }

    /// Mark as Read or Unread, here and in Messages.
    func setRead(_ chat: Chat, _ read: Bool) {
        if read {
            markSeen(chat)
        } else {
            markedUnread.insert(chat.guid)
            UserDefaults.standard.set(Array(markedUnread), forKey: "markedUnread")
        }
        inMessages { try await HiddenMessages.setRead(read, chat: chat.guid) } undo: {}
    }

    func isMuted(_ chat: Chat) -> Bool {
        mutedOverride[chat.guid] ?? mutedKeys.contains(chat.muteKey)
    }

    /// Hide or Show Alerts in Messages. Perch posts no message alerts of its own.
    func setMuted(_ chat: Chat, _ muted: Bool) {
        mutedOverride[chat.guid] = muted
        inMessages { try await HiddenMessages.setMuted(muted, chat: chat.guid) } undo: { self.mutedOverride[chat.guid] = nil }
    }

    /// Reads Messages' Hide Alerts list: chat identifiers, or group ids, each muted until a date.
    private func refreshMuted() {
        let domain = "com.apple.MobileSMS.CKDNDList" as CFString
        CFPreferencesAppSynchronize(domain)
        let list = CFPreferencesCopyAppValue("CKDNDListKey" as CFString, domain) as? [String: Int] ?? [:]
        mutedKeys = Set(list.filter { Date(timeIntervalSince1970: TimeInterval($0.value)) > .now }.keys)
        mutedOverride = mutedOverride.filter { guid, muted in  // drop what Messages has caught up with
            guard let chat = chats.first(where: { $0.guid == guid }) else { return false }
            return mutedKeys.contains(chat.muteKey) != muted
        }
    }

    /// Asks first, as Messages does, then deletes the conversation in Messages.
    func confirmDelete(_ chat: Chat) {
        let alert = NSAlert()
        alert.messageText = "Delete your conversation with \(name(chat))?"
        alert.informativeText = "It's deleted in Messages too. This can't be undone."
        alert.addButton(withTitle: "Delete").hasDestructiveAction = true
        alert.addButton(withTitle: "Cancel")
        NSApp.activate()
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        if panelChat?.id == chat.id { hidePanel() }
        deleting.insert(chat.id)
        withAnimation(.smooth) { chats.removeAll { $0.id == chat.id } }
        inMessages { try await HiddenMessages.delete(chat: chat.guid) } undo: {
            self.deleting.remove(chat.id)
            self.lastMark = nil  // reload, which brings it back
        }
    }

    /// Runs a change through the hidden copy of Messages. If it fails, undoes what Perch already showed and says why.
    private func inMessages(_ change: @escaping () async throws -> Void, undo: @escaping () -> Void) {
        Task {
            do {
                try await change()
            } catch {
                undo()
                let alert = NSAlert()
                alert.messageText = "Messages didn't make the change"
                alert.informativeText = error.localizedDescription
                alert.runModal()
            }
        }
    }

    func name(_ chat: Chat) -> String {
        chat.groupName ?? (chat.handles.isEmpty ? chat.identifier : chat.handles.map(contacts.name).joined(separator: ", "))
    }

    func shortName(_ chat: Chat) -> String { chat.person.map(contacts.shortName) ?? name(chat) }

    /// Their contact photo, or a group's own picture.
    func photo(_ chat: Chat) -> NSImage? {
        if let person = chat.person { return contacts.photo(person) }
        guard let url = chat.photo else { return nil }
        if let cached = groupPhotos[url] { return cached }
        // Group pictures are full-size photos; an avatar needs a small one, decoded once.
        let options = [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: 160,
                       kCGImageSourceCreateThumbnailWithTransform: true] as CFDictionary
        let image = CGImageSourceCreateWithURL(url as CFURL, nil)
            .flatMap { CGImageSourceCreateThumbnailAtIndex($0, 0, options) }
            .map { NSImage(cgImage: $0, size: .zero) }
        groupPhotos[url] = image
        return image
    }

    /// A group's members for its cluster of faces, those with photos first, as Messages shows them.
    func members(_ chat: Chat) -> [Avatar.Member] {
        guard chat.isGroup else { return [] }
        let all = chat.handles.map { Avatar.Member(image: contacts.photo($0), name: contacts.name($0)) }
        return Array((all.filter { $0.image != nil } + all.filter { $0.image == nil }).prefix(4))
    }

    /// Opens the thread in Messages, out from under the panel.
    func openInMessages(_ chat: Chat) {
        hidePanel()
        MessagesApp.open(chat)
    }

    /// Shows the send in the thread at once, then hands it to Messages, or to the hidden copy for a reply, once the
    /// sends before it have gone. Returns false if it failed.
    @discardableResult
    func send(_ text: String = "", file: URL? = nil, to chat: Chat, replyingTo original: Message? = nil) async -> Bool {
        let p = Pending(id: nextPendingID, chatID: chat.id, text: text, file: file, replyTo: original?.guid)
        nextPendingID -= 1
        pending.append(p)  // not animated: a scroll asked for while the thread's height animates is dropped, so the send stayed under the message box (its bubble pops in by itself)
        let before = lastSend
        let this = Task {
            _ = await before?.value
            return await hand(p, to: chat, replyingTo: original)
        }
        lastSend = this
        return await this.value
    }

    private func hand(_ p: Pending, to chat: Chat, replyingTo original: Message?) async -> Bool {
        let (text, file) = (p.text, p.file)
        do {
            if let original {
                try await HiddenMessages.reply(text: file == nil ? text : nil, file: file, to: original.guid, chat: chat.guid)
            } else if let file {
                try await MessagesApp.send(file: file, to: chat)
            } else {
                try await MessagesApp.send(text: text, to: chat)
            }
            sendError = nil
            Task {  // its row replaces it as it lands (see `poll`); this is for one that never shows, such as a pretend send
                try? await Task.sleep(for: .seconds(30))
                if pending.contains(where: { $0.id == p.id }) { pending.removeAll { $0.id == p.id } }
            }
            return true
        } catch {
            sendError = error.localizedDescription
            withAnimation(.smooth) { pending.removeAll { $0.id == p.id } }
            return false
        }
    }

    func stage(_ files: [URL], for chatID: Int64) {
        withAnimation(.smooth) { drafts[chatID, default: []] += files }
    }

    func unstage(_ file: URL, from chatID: Int64) {
        withAnimation(.smooth) { drafts[chatID]?.removeAll { $0 == file } }
    }

    /// Sends the staged files, then the text, as Messages does, all into `original`'s thread if given.
    /// A file that fails goes back in the box. Returns false if the text failed, so the caller can put it back.
    func sendDraft(text: String, to chat: Chat, replyingTo original: Message? = nil) async -> Bool {
        let files = drafts.removeValue(forKey: chat.id) ?? []
        for file in files {
            if await !send(file: file, to: chat, replyingTo: original) { stage([file], for: chat.id) }
        }
        return text.isEmpty ? true : await send(text, to: chat, replyingTo: original)
    }

    /// My tapback on `message`, counting one on its way.
    func mine(_ message: Message) -> String? { tapbacks[message.guid] ?? message.mine }

    /// Picking the tapback you already gave takes it off, as in Messages; any other replaces it.
    func react(_ emoji: String, to message: Message, in chat: Chat) {
        let on = mine(message) != emoji
        withAnimation(.smooth) { tapbacks[message.guid] = .some(on ? emoji : nil) }
        Task {
            do {
                try await HiddenMessages.react(emoji, on: on, message: message.guid, chat: chat.guid)
                sendError = nil
                try? await Task.sleep(for: .seconds(30))  // chat.db shows it long before; if it never does, show what it says
                if tapbacks[message.guid] == .some(on ? emoji : nil) { withAnimation(.smooth) { _ = tapbacks.removeValue(forKey: message.guid) } }
            } catch {
                sendError = error.localizedDescription
                withAnimation(.smooth) { _ = tapbacks.removeValue(forKey: message.guid) }
            }
        }
    }

    func remind(_ message: Message, in chat: Chat, at date: Date) async {
        let content = UNMutableNotificationContent()
        content.title = name(chat)
        content.body = message.text.isEmpty ? "Attachment" : message.text
        let when = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        let request = UNNotificationRequest(identifier: message.guid, content: content,
                                            trigger: UNCalendarNotificationTrigger(dateMatching: when, repeats: false))
        let center = UNUserNotificationCenter.current()
        guard (try? await center.requestAuthorization(options: [.alert, .sound])) == true else {
            sendError = "Allow notifications for Perch in System Settings to get reminders."
            return
        }
        guard (try? await center.add(request)) != nil else {
            sendError = "Couldn't set the reminder."
            return
        }
        withAnimation(.smooth) { reminders[message.guid] = date }
    }

    /// Starts a voice note, or a screen recording, which hides the panel: out of the toolbar's way and out of the shot.
    func record(_ kind: Recorder.Kind, for chat: Chat) {
        Task {
            do {
                try await recorder.start(kind, for: chat)
                sendError = nil
                if kind == .screen { hidePanel() }
            } catch {
                sendError = error.localizedDescription
            }
        }
    }

    /// Stops the voice note and sends it.
    func finishRecording(to chat: Chat, replyingTo original: Message?) {
        Task {
            if let file = await recorder.stop() { await send(file: file, to: chat, replyingTo: original) }
        }
    }

    /// Reloads the chat list when chat.db changes, and the open chat's thread when it has changed since that loaded.
    private func poll() async {
        do {
            let db = try self.db ?? MessagesDB(path: MessagesDB.path)
            self.db = db
            let mark = try await db.mark()
            needsAccess = false
            readError = nil
            if mark != lastMark {
                chats = try await db.chats().filter { !deleting.contains($0.id) }
                recentEmoji = HiddenMessages.recentEmoji()
                lastMark = mark  // only once loaded, so a failed load tries again next tick
            }
            refreshMuted()  // Hide Alerts lives in Messages' settings, which chat.db doesn't mark
            if let id = panelChat?.id, loadedAt[id] != mark {
                let from = threadStart?.chat == id ? threadStart?.message : nil
                let thread = try await db.messages(chat: id, from: from)
                if from == nil, let oldest = thread.first { threadStart = (id, oldest.id) }
                loadedAt[id] = mark
                if threads[id] != thread { threads[id] = thread }
                if pending.contains(where: { $0.chatID == id && $0.landed(in: thread) }) {
                    pending.removeAll { $0.chatID == id && $0.landed(in: thread) }
                }
                tapbacks = tapbacks.filter { guid, mine in thread.first { $0.guid == guid }.map { $0.mine != mine } ?? true }
            }
            if panelShown { markSeen(panelChat) }  // arrived while open, so read
        } catch {
            (db, lastMark, loadedAt) = (nil, nil, [:])  // the next connection counts marks afresh
            needsAccess = !MessagesDB.readable
            readError = needsAccess ? nil : "\(error)"
        }
    }
}
