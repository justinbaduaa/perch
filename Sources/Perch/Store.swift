import AppKit

/// App state. Polls chat.db and bumps `revision` whenever a new row lands.
@Observable final class Store {
    private(set) var chats: [Chat] = []
    private(set) var revision = 0
    private(set) var needsAccess = false
    var panelChat: Chat?
    let contacts = ContactBook()
    @ObservationIgnored var onChange: () -> Void = {}

    @ObservationIgnored private var db: MessagesDB?
    @ObservationIgnored private var lastRowID: Int64 = -1
    @ObservationIgnored private var pins: [String] = []

    func start() {
        poll()
        Task {
            await contacts.load()
            onChange()
        }
        Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { _ in
            MainActor.assumeIsolated { self.poll() }
        }
    }

    /// Messages' pins when we can read them, else the most recent chats.
    var barChats: [Chat] {
        let pinned = pins.compactMap { pin in chats.first { $0.identifier == pin || $0.guid == pin } }
        return Array((pinned.isEmpty ? chats : pinned).prefix(5))
    }

    func messages(for chat: Chat) -> [Message] { (try? db?.messages(chat: chat.id)) ?? [] }

    func name(_ chat: Chat) -> String {
        chat.groupName ?? (chat.handles.isEmpty ? chat.identifier : chat.handles.map(contacts.name).joined(separator: ", "))
    }

    func shortName(_ chat: Chat) -> String {
        chat.handles.count == 1 && chat.groupName == nil ? contacts.shortName(chat.handles[0]) : name(chat)
    }

    func photo(_ chat: Chat) -> NSImage? { chat.handles.count == 1 ? contacts.photo(chat.handles[0]) : nil }

    private func poll() {
        do {
            if db == nil {
                db = try MessagesDB(path: MessagesDB.path)
                pins = MessagesDB.pinnedIdentifiers()
            }
            let max = try db!.maxRowID()
            needsAccess = false
            guard max != lastRowID else { return }
            lastRowID = max
            chats = try db!.chats()
            revision += 1
        } catch {
            db = nil
            needsAccess = !FileManager.default.isReadableFile(atPath: MessagesDB.path)
            if !needsAccess { print("Perch: chat.db read failed: \(error)") }
        }
        onChange()  // only reached on a change or a failure
    }
}
