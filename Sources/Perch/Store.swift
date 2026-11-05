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

    @ObservationIgnored private var db: MessagesDB?
    @ObservationIgnored private var lastRowID: Int64 = -1
    @ObservationIgnored private var nextPendingID: Int64 = -1
    /// Chat guid to the newest unread row opened in Perch, so the bar rings only what came after.
    @ObservationIgnored private var seen = UserDefaults.standard.dictionary(forKey: "seen") as? [String: Int] ?? [:]

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

    /// Something they sent that I haven't opened in Perch or answered. Messages itself may still count it unread.
    func isUnread(_ chat: Chat) -> Bool { chat.unread.map { $0 > seen[chat.guid] ?? 0 } ?? false }

    /// Opening a chat in Perch reads it, as far as the bar's rings go.
    func markSeen(_ chat: Chat?) {
        guard let chat = chats.first(where: { $0.id == chat?.id }), let row = chat.unread.map(Int.init),
              seen[chat.guid] != row else { return }
        seen[chat.guid] = row
        UserDefaults.standard.set(seen, forKey: "seen")
    }

    func messages(for chat: Chat) -> [Message] { (try? db?.messages(chat: chat.id)) ?? [] }

    func name(_ chat: Chat) -> String {
        chat.groupName ?? (chat.handles.isEmpty ? chat.identifier : chat.handles.map(contacts.name).joined(separator: ", "))
    }

    func shortName(_ chat: Chat) -> String {
        chat.handles.count == 1 && chat.groupName == nil ? contacts.shortName(chat.handles[0]) : name(chat)
    }

    func photo(_ chat: Chat) -> NSImage? { chat.handles.count == 1 ? contacts.photo(chat.handles[0]) : nil }

    /// Shows the send in the thread at once, then hands it to Messages, or to the hidden copy for a reply.
    /// Returns false if it failed.
    @discardableResult
    func send(_ text: String = "", file: URL? = nil, to chat: Chat, replyingTo original: Message? = nil) async -> Bool {
        let p = Pending(id: nextPendingID, chatID: chat.id, text: text, file: file, replyTo: original?.guid)
        nextPendingID -= 1
        withAnimation(.smooth) { pending.append(p) }
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
            let max = try db!.maxRowID()
            needsAccess = false
            readError = nil
            guard max != lastRowID else { return }
            lastRowID = max
            chats = try db!.chats()
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
