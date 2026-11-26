import ApplicationServices
import IMessage

/// Tapbacks, threaded replies and conversation actions, which Messages' AppleScript can't do. Beeper's platform-imessage drives
/// Messages through Accessibility, its window parked on a hidden Space meanwhile; Perch needs Accessibility.
nonisolated enum HiddenMessages {
    /// The six classic tapbacks, in chat.db's order (type 2000 is the first), and as platform-imessage names them.
    static let tapbacks: [(emoji: String, key: String)] = [
        ("❤️", "heart"), ("👍", "like"), ("👎", "dislike"), ("😂", "laugh"), ("‼️", "emphasize"), ("❓", "question"),
    ]

    /// Messages' row of recent emoji tapbacks: the emoji last picked anywhere on this Mac, newest first, leaving out
    /// stickers and the six above. Picking one sends it through Messages' own emoji picker, which moves it to the front.
    static func recentEmoji(_ order: [String]? = nil) -> [String] {
        let domain = "com.apple.EmojiPreferences" as CFString
        if order == nil { CFPreferencesAppSynchronize(domain) }
        let order = order ?? CFPreferencesCopyAppValue("com.apple.stickers.recency.order" as CFString, domain) as? [String] ?? []
        var seen = Set(tapbacks.map(\.emoji))
        return order.compactMap { $0.hasPrefix("emoji:") ? plain(String($0.dropFirst(6))) : nil }.filter { seen.insert($0).inserted }
    }

    /// `emoji` in the default skin tone, which is the one platform-imessage always picks.
    static func plain(_ emoji: String) -> String {
        String(String.UnicodeScalarView(emoji.unicodeScalars.filter { !(0x1F3FB...0x1F3FF).contains($0.value) }))
    }

    struct Failure: LocalizedError { let errorDescription: String? }

    /// Built once, on first use: platform-imessage allows one per process. `bootstrap` registers Beeper's defaults; without
    /// them Messages' window popped up on every reaction. Window coordination (parking that window on a hidden Space) is
    /// turned off for this process only: in a stress run against a self-chat it timed out the first action after launch
    /// and broke misfire prevention, while without it 36 of 36 sends, tapbacks and replies landed and no Messages window
    /// showed. Dock suppression goes too: a park that timed out left Messages with no Dock icon and its window on the
    /// hidden Space, so it couldn't be opened. Its secondary-instance mode, a second hidden Messages, failed and cost 360 MB.
    nonisolated(unsafe) private static let api = Result { () throws -> PlatformAPI in
        IMessageHost.bootstrap()
        UserDefaults(suiteName: "com.automattic.beeper.desktop.swift-server")?.register(defaults: ["BEEPWindowCoordination": false, "BEEPDockSuppression": false])  // registration domain: Beeper Desktop's saved settings are untouched
        return try PlatformAPI(accountID: "perch")
    }

    static func react(_ emoji: String, on: Bool, message: String, chat: String) async throws {
        guard let api = try ready(to: "react") else { return }
        let key = tapbacks.first { $0.emoji == emoji }?.key ?? emoji  // a custom emoji tapback goes by the emoji itself
        if on {
            try await api.addReaction(threadID: chat, messageID: message, reactionKey: key)
        } else {
            try await api.removeReaction(threadID: chat, messageID: message, reactionKey: key)
        }
    }

    /// Sends text or a file into the thread of the message `original`.
    static func reply(text: String?, file: URL?, to original: String, chat: String) async throws {
        guard let api = try ready(to: "reply") else { return try await Task.sleep(for: .milliseconds(700)) }
        _ = try await api.sendMessage(threadID: chat, text: text, filePath: file?.path, quotedMessageID: original)
    }

    /// Marks the chat read, as opening it in Messages does (sending read receipts if they're on), or unread.
    static func setRead(_ read: Bool, chat: String) async throws {
        guard let api = try ready(to: "change chats") else { return }
        if read { try await api.sendReadReceipt(threadID: chat) } else { try await api.markAsUnread(threadID: chat) }
    }

    /// Messages' Hide Alerts.
    static func setMuted(_ muted: Bool, chat: String) async throws {
        guard let api = try ready(to: "change chats") else { return }
        try await api.updateThread(threadID: chat, muted: muted)
    }

    static func delete(chat: String) async throws {
        guard let api = try ready(to: "delete chats") else { return }
        try await api.deleteThread(threadID: chat)
    }

    /// The API, or nil against a fixture database, which has no Messages behind it.
    private static func ready(to action: String) throws -> PlatformAPI? {
        if MessagesDB.isFixture { return nil }
        let prompt = ["AXTrustedCheckOptionPrompt": true] as CFDictionary  // kAXTrustedCheckOptionPrompt, which Swift 6 flags as shared state
        guard AXIsProcessTrustedWithOptions(prompt) else {
            throw Failure(errorDescription: "Allow Perch under Accessibility in System Settings to \(action).")
        }
        return try api.get()
    }
}
