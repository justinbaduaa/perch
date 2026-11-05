import Foundation

/// Sends through Messages' AppleScript in an `osascript` child, passing values as argv so nothing needs escaping.
enum MessagesApp {
    struct SendError: LocalizedError {
        let stderr: String
        var errorDescription: String? {
            stderr.contains("-1743") ? "Allow Perch to control Messages in System Settings." : "Couldn't send."
        }
    }

    /// A fixture database has no Messages behind it, so with PERCH_DB set a send only pretends.
    private static let dryRun = ProcessInfo.processInfo.environment["PERCH_DB"] != nil

    static func send(text: String, to chat: Chat) async throws {
        if dryRun { return try await Task.sleep(for: .milliseconds(700)) }
        try await run(chat, kind: "text", payload: text)
    }

    static func send(file: URL, to chat: Chat) async throws {
        if dryRun { return try await Task.sleep(for: .milliseconds(700)) }
        try await run(chat, kind: "file", payload: stage(file).path)
    }

    /// Targets the chat by guid. AppleScript chat ids can differ from chat.db's, so a 1:1 chat
    /// falls back to its handle on the iMessage account.
    private static let script = """
        on run {chatID, theHandle, theKind, thePayload}
            if theKind is "file" then set thePayload to POSIX file thePayload
            tell application "Messages"
                try
                    set theTarget to chat id chatID
                on error errText number errNum
                    if theHandle is "" then error errText number errNum
                    set theTarget to participant theHandle of (1st account whose service type = iMessage)
                end try
                send thePayload to theTarget
            end tell
        end run
        """

    private static func run(_ chat: Chat, kind: String, payload: String) async throws {
        let handle = chat.handles.count == 1 ? chat.handles[0] : ""
        try await withCheckedThrowingContinuation { (done: CheckedContinuation<Void, Error>) in
            let p = Process()
            let stderr = Pipe()
            p.executableURL = URL(filePath: "/usr/bin/osascript")
            p.arguments = ["-e", script, chat.guid, handle, kind, payload]
            p.standardError = stderr
            p.terminationHandler = { p in
                let message = String(decoding: stderr.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                p.terminationStatus == 0 ? done.resume() : done.resume(throwing: SendError(stderr: message))
            }
            do { try p.run() } catch { done.resume(throwing: error) }
        }
    }

    /// Messages reads attachments reliably only from inside its own folder, so copy there first.
    /// shortcut: staged copies are never pruned; add cleanup if disk use ever matters.
    private static func stage(_ file: URL) throws -> URL {
        let dir = URL.homeDirectory.appending(path: "Library/Messages/Attachments/Perch/\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let dest = dir.appending(path: file.lastPathComponent)
        try FileManager.default.copyItem(at: file, to: dest)
        return dest
    }
}
