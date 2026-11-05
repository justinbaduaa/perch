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

    var message: Message {
        let mime = file.flatMap { UTType(filenameExtension: $0.pathExtension)?.preferredMIMEType } ?? ""
        return Message(id: id, guid: "", date: date, fromMe: true, sender: nil, text: text,
                       attachments: file.map { [Attachment(url: $0, mime: mime)] } ?? [])
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
    /// My tapback on a message while it's on its way (nil value: being removed), shown until chat.db catches up.
    private(set) var tapbacks: [String: String?] = [:]
    let recorder = Recorder()
    /// Message guid to reminder time. The system keeps the reminders, as pending notifications keyed by guid.
    private(set) var reminders: [String: Date] = [:]
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

    func start() {
        recorder.onScreenEnded = { [unowned self] id in
            onChange()
            if let chat = chats.first(where: { $0.id == id }) { showPanel(chat) }
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

    /// The people you talked to last, whoever sent the last message. A chat you're recording for stays first,
    /// so the recording is one click away after the panel closes.
    var barChats: [Chat] {
        let recording = chats.first { $0.id == recorder.chatID }
        return Array(([recording].compactMap(\.self) + chats.filter { $0.id != recording?.id }).prefix(5))
    }

    func messages(for chat: Chat) -> [Message] { (try? db?.messages(chat: chat.id)) ?? [] }

    func name(_ chat: Chat) -> String {
        chat.groupName ?? (chat.handles.isEmpty ? chat.identifier : chat.handles.map(contacts.name).joined(separator: ", "))
    }

    func shortName(_ chat: Chat) -> String {
        chat.handles.count == 1 && chat.groupName == nil ? contacts.shortName(chat.handles[0]) : name(chat)
    }

    func photo(_ chat: Chat) -> NSImage? { chat.handles.count == 1 ? contacts.photo(chat.handles[0]) : nil }

    /// Shows the send in the thread at once, then hands it to Messages. Returns false if it failed.
    @discardableResult
    func send(_ text: String = "", file: URL? = nil, to chat: Chat) async -> Bool {
        let p = Pending(id: nextPendingID, chatID: chat.id, text: text, file: file)
        nextPendingID -= 1
        withAnimation(.smooth) { pending.append(p) }
        do {
            if let file { try await MessagesApp.send(file: file, to: chat) } else { try await MessagesApp.send(text: text, to: chat) }
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

    /// Picking the tapback you already gave takes it off, as in Messages; any other replaces it.
    func react(_ emoji: String, to message: Message, in chat: Chat) {
        let on = message.mine != emoji
        withAnimation(.smooth) { tapbacks[message.guid] = .some(on ? emoji : nil) }
        Task {
            do {
                try await Tapbacks.set(emoji, on: on, message: message.guid, chat: chat.guid)
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
            revision += 1
        } catch {
            db = nil
            needsAccess = !FileManager.default.isReadableFile(atPath: MessagesDB.path)
            readError = needsAccess ? nil : "\(error)"
        }
        onChange()  // only reached on a change or a failure
    }
}
