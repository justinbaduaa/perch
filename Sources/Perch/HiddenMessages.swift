import ApplicationServices
import IMessage

/// Tapbacks and threaded replies, which Messages' AppleScript can't send. Beeper's platform-imessage drives a hidden
/// second copy of Messages through Accessibility, so your own Messages window never moves; Perch needs Accessibility.
nonisolated enum HiddenMessages {
    /// The six classic tapbacks, as chat.db shows them and as platform-imessage names them.
    static let tapbacks: [(emoji: String, key: String)] = [
        ("❤️", "heart"), ("👍", "like"), ("👎", "dislike"), ("😂", "laugh"), ("‼️", "emphasize"), ("❓", "question"),
    ]

    struct Failure: LocalizedError { let errorDescription: String? }

    /// Built once, on first use: platform-imessage allows one per process.
    nonisolated(unsafe) private static let api = Result { try PlatformAPI(accountID: "perch") }

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

    /// The API, or nil against a fixture database, which has no Messages behind it.
    private static func ready(to action: String) throws -> PlatformAPI? {
        if ProcessInfo.processInfo.environment["PERCH_DB"] != nil { return nil }
        let prompt = ["AXTrustedCheckOptionPrompt": true] as CFDictionary  // kAXTrustedCheckOptionPrompt, which Swift 6 flags as shared state
        guard AXIsProcessTrustedWithOptions(prompt) else {
            throw Failure(errorDescription: "Allow Perch under Accessibility in System Settings to \(action).")
        }
        return try api.get()
    }
}
