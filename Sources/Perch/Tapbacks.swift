import ApplicationServices
import IMessage

/// Sends tapbacks, which Messages offers no public API for. Beeper's platform-imessage drives a hidden second
/// copy of Messages through Accessibility, so your own Messages window never moves; Perch needs Accessibility.
nonisolated enum Tapbacks {
    /// The six classic tapbacks, as chat.db shows them and as platform-imessage names them.
    static let all: [(emoji: String, key: String)] = [
        ("❤️", "heart"), ("👍", "like"), ("👎", "dislike"), ("😂", "laugh"), ("‼️", "emphasize"), ("❓", "question"),
    ]

    struct Failure: LocalizedError { let errorDescription: String? }

    /// Built once, on first use: platform-imessage allows one per process.
    nonisolated(unsafe) private static let api = Result { try PlatformAPI(accountID: "perch") }

    static func set(_ emoji: String, on: Bool, message: String, chat: String) async throws {
        if ProcessInfo.processInfo.environment["PERCH_DB"] != nil { return }  // a fixture database has no Messages behind it
        let prompt = ["AXTrustedCheckOptionPrompt": true] as CFDictionary  // kAXTrustedCheckOptionPrompt, which Swift 6 flags as shared state
        guard AXIsProcessTrustedWithOptions(prompt) else {
            throw Failure(errorDescription: "Allow Perch under Accessibility in System Settings to react.")
        }
        let api = try api.get()
        let key = all.first { $0.emoji == emoji }?.key ?? emoji  // a custom emoji tapback goes by the emoji itself
        if on {
            try await api.addReaction(threadID: chat, messageID: message, reactionKey: key)
        } else {
            try await api.removeReaction(threadID: chat, messageID: message, reactionKey: key)
        }
    }
}
