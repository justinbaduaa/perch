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

/// App state. Polls chat.db and bumps `revision` whenever a new row lands.
@Observable final class Store {
    private(set) var chats: [Chat] = []
    private(set) var revision = 0
    private(set) var needsAccess = false
    /// Why chat.db could not be read when it is readable, shown in the panel instead of failing silently.
    private(set) var readError: String?
    private(set) var pending: [Pending] = []
    var sendError: String?
    /// Files waiting in each chat's message box for Send.
    private(set) var drafts: [Int64: [URL]] = [:]
    /// My tapback on a message while it's on its way (nil value: being removed), shown until chat.db catches up.
    private(set) var tapbacks: [String: String?] = [:]
    let recorder = Recorder()
    /// Message guid to reminder time. The system keeps the reminders, as pending notifications keyed by guid.
    private(set) var reminders: [String: Date] = [:]
    /// Chats held at the front of the menu bar, by guid, in the order they were pinned.
    private(set) var pins = UserDefaults.standard.stringArray(forKey: "pins") ?? []
    var panelChat: Chat?
    var panelShown = false
    /// The menu bar avatar under the pointer.
    var hoverChat: Chat?
    let contacts = ContactBook()
    @ObservationIgnored var onChange: () -> Void = {}
    /// Set by the app delegate, which owns the panel.
    @ObservationIgnored var showPanel: (Chat) -> Void = { _ in }
    @ObservationIgnored var hidePanel: () -> Void = {}
    @ObservationIgnored var showSetup: () -> Void = {}

    @ObservationIgnored private var db: MessagesDB?
    /// chat.db's newest row, unread count and receipts on my recent messages at the last poll; any change reloads.
    @ObservationIgnored private var lastMark: [Int64] = []
    @ObservationIgnored private var nextPendingID: Int64 = -1
    /// The latest send. Each waits for the one before, so they go out in the order they were sent, as in Messages.
    @ObservationIgnored private var lastSend: Task<Bool, Never>?
    /// Chat guid to the newest unread row opened in Perch, so the bar rings only what came after.
    @ObservationIgnored private var seen = UserDefaults.standard.dictionary(forKey: "seen") as? [String: Int] ?? [:]
    /// Chat guids marked unread from Perch, ringed until opened.
    @ObservationIgnored private var markedUnread = Set(UserDefaults.standard.stringArray(forKey: "markedUnread") ?? [])
    /// Messages' Hide Alerts list, as of the last poll, and what Perch has set since.
    @ObservationIgnored private var mutedKeys: Set<String> = []
    @ObservationIgnored private var mutedOverride: [String: Bool] = [:]
    /// Chats on their way out, kept off the bar until chat.db drops them.
    @ObservationIgnored private var deleting: Set<Int64> = []

    func start() {
        recorder.onScreenEnded = { [unowned self] id in
            Task {
                if let file = try? await recorder.stop() { stage([file], for: id) }  // a finished capture waits for Send
                onChange()
                if let chat = chats.first(where: { $0.id == id }) { showPanel(chat) }
            }
        }
        poll()
        Task {
            await contacts.load()
            onChange()
        }
        Task {
            let requests = await UNUserNotificationCenter.current().pendingNotificationRequests()
            for r in requests {
                reminders[r.identifier] = (r.trigger as? UNCalendarNotificationTrigger)?.nextTriggerDate()
            }
        }
        Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { _ in
            MainActor.assumeIsolated { self.poll() }
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
        onChange()
    }

    /// Something they sent that I haven't opened in Perch or answered, or a chat I marked unread.
    func isUnread(_ chat: Chat) -> Bool {
        markedUnread.contains(chat.guid) || chat.unread.map { $0 > seen[chat.guid] ?? 0 } ?? false
    }

    /// Opening a chat in Perch reads it, as far as the bar's rings go.
    func markSeen(_ chat: Chat?) {
        guard let chat = chats.first(where: { $0.id == chat?.id }) else { return }
        var changed = markedUnread.remove(chat.guid) != nil
        if let row = chat.unread.map(Int.init), seen[chat.guid] != row {
            seen[chat.guid] = row
            changed = true
        }
        guard changed else { return }
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
        onChange()
        inMessages { try await HiddenMessages.setRead(read, chat: chat.guid) } undo: {}
    }

    func isMuted(_ chat: Chat) -> Bool {
        mutedOverride[chat.guid] ?? mutedKeys.contains(chat.isGroup ? chat.groupID ?? "" : chat.identifier)
    }

    /// Hide or Show Alerts in Messages. Perch posts no message alerts of its own.
    func setMuted(_ chat: Chat, _ muted: Bool) {
        mutedOverride[chat.guid] = muted
        inMessages { try await HiddenMessages.setMuted(muted, chat: chat.guid) } undo: { self.mutedOverride[chat.guid] = nil }
    }

    /// Reads Messages' Hide Alerts list: chat identifiers, or group ids, each muted until a date.
    func refreshMuted() {
        let domain = "com.apple.MobileSMS.CKDNDList" as CFString
        CFPreferencesAppSynchronize(domain)
        let list = CFPreferencesCopyAppValue("CKDNDListKey" as CFString, domain) as? [String: Int] ?? [:]
        mutedKeys = Set(list.filter { Date(timeIntervalSince1970: TimeInterval($0.value)) > .now }.keys)
        mutedOverride = mutedOverride.filter { guid, muted in  // drop what Messages has caught up with
            guard let chat = chats.first(where: { $0.guid == guid }) else { return false }
            return mutedKeys.contains(chat.isGroup ? chat.groupID ?? "" : chat.identifier) != muted
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
        onChange()
        inMessages { try await HiddenMessages.delete(chat: chat.guid) } undo: {
            self.deleting.remove(chat.id)
            self.lastMark = []  // reload, which brings it back
            self.poll()
        }
    }

    /// Runs a change through the hidden copy of Messages. If it fails, undoes what Perch already showed and says why.
    private func inMessages(_ change: @escaping () async throws -> Void, undo: @escaping () -> Void) {
        Task {
            do {
                try await change()
            } catch {
                undo()
                onChange()
                let alert = NSAlert()
                alert.messageText = "Messages didn't make the change"
                alert.informativeText = error.localizedDescription
                alert.runModal()
            }
        }
    }

    func messages(for chat: Chat) -> [Message] { (try? db?.messages(chat: chat.id)) ?? [] }

    func name(_ chat: Chat) -> String {
        chat.groupName ?? (chat.handles.isEmpty ? chat.identifier : chat.handles.map(contacts.name).joined(separator: ", "))
    }

    func shortName(_ chat: Chat) -> String {
        chat.handles.count == 1 && chat.groupName == nil ? contacts.shortName(chat.handles[0]) : name(chat)
    }

    func photo(_ chat: Chat) -> NSImage? { chat.handles.count == 1 ? contacts.photo(chat.handles[0]) : nil }

    /// Shows the send in the thread at once, then hands it to Messages, or to the hidden copy for a reply, once the
    /// sends before it have gone. Returns false if it failed.
    @discardableResult
    func send(_ text: String = "", file: URL? = nil, to chat: Chat, replyingTo original: Message? = nil) async -> Bool {
        let p = Pending(id: nextPendingID, chatID: chat.id, text: text, file: file, replyTo: original?.guid)
        nextPendingID -= 1
        withAnimation(.smooth) { pending.append(p) }
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
            // The real row replaces it as soon as it lands (see `Pending.landed`); this only cleans up.
            Task {
                try? await Task.sleep(for: .seconds(10))
                pending.removeAll { $0.id == p.id }
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

    /// Picking the tapback you already gave takes it off, as in Messages; any other replaces it.
    func react(_ emoji: String, to message: Message, in chat: Chat) {
        let on = message.mine != emoji
        withAnimation(.smooth) { tapbacks[message.guid] = .some(on ? emoji : nil) }
        Task {
            do {
                try await HiddenMessages.react(emoji, on: on, message: message.guid, chat: chat.guid)
                sendError = nil
                try? await Task.sleep(for: .seconds(6))  // chat.db has the row by now
            } catch {
                sendError = error.localizedDescription
            }
            withAnimation(.smooth) { _ = tapbacks.removeValue(forKey: message.guid) }
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
        guard (try? await center.requestAuthorization(options: [.alert, .sound])) == true,
              (try? await center.add(request)) != nil else { return }
        withAnimation(.smooth) { reminders[message.guid] = date }
    }

    private func poll() {
        do {
            if db == nil { db = try MessagesDB(path: MessagesDB.path) }
            let mark = [try db!.maxRowID(), try db!.unreadCount()] + (try db!.receiptMark())
            needsAccess = false
            readError = nil
            guard mark != lastMark else { return }
            lastMark = mark
            chats = try db!.chats().filter { !deleting.contains($0.id) }
            refreshMuted()
            if panelShown { markSeen(panelChat) }  // arrived while open, so read
            revision += 1
        } catch {
            db = nil
            needsAccess = !FileManager.default.isReadableFile(atPath: MessagesDB.path)
            readError = needsAccess ? nil : "\(error)"
        }
        onChange()  // only reached on a change or a failure
    }
}
