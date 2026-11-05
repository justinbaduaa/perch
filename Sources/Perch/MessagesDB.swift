import Foundation
import SQLite3
import UniformTypeIdentifiers

/// A conversation in chat.db. `guid` is the id Messages' AppleScript uses for the chat.
struct Chat: Identifiable, Hashable {
    let id: Int64
    let guid: String
    let identifier: String
    let groupName: String?
    let handles: [String]
}

struct Attachment: Hashable {
    let url: URL
    let mime: String
    var isAudio: Bool { mime.hasPrefix("audio/") }
    var isVideo: Bool { mime.hasPrefix("video/") }
}

struct Message: Identifiable {
    let id: Int64
    let guid: String
    let date: Date
    let fromMe: Bool
    let sender: String?
    let text: String
    var attachments: [Attachment] = []
    var reactions: [String] = []
}

struct DBError: Error { let message: String }

/// Read-only view of the Messages database. Opening it needs Full Disk Access.
final class MessagesDB {
    static let path = ProcessInfo.processInfo.environment["PERCH_DB"]
        ?? URL.homeDirectory.appending(path: "Library/Messages/chat.db").path

    private var db: OpaquePointer?

    init(path: String) throws {
        guard sqlite3_open_v2(path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            defer { sqlite3_close(db) }
            throw DBError(message: String(cString: sqlite3_errmsg(db)))
        }
        _ = try maxRowID()  // TCC denial surfaces on first read, not on open
    }

    isolated deinit { sqlite3_close(db) }

    func maxRowID() throws -> Int64 {
        var id: Int64 = 0
        try query("SELECT IFNULL(MAX(ROWID), 0) FROM message") { id = $0.int(0) }
        return id
    }

    /// Most recently active conversations first.
    func chats(limit: Int64 = 100) throws -> [Chat] {
        var out: [Chat] = []
        try query("""
            SELECT c.ROWID, c.guid, c.chat_identifier, c.display_name,
              (SELECT group_concat(h.id, ',') FROM chat_handle_join j
                 JOIN handle h ON h.ROWID = j.handle_id WHERE j.chat_id = c.ROWID)
            FROM chat c JOIN chat_message_join cmj ON cmj.chat_id = c.ROWID
            GROUP BY c.ROWID ORDER BY MAX(cmj.message_date) DESC LIMIT ?
            """, limit) { r in
            out.append(Chat(
                id: r.int(0), guid: r.text(1) ?? "", identifier: r.text(2) ?? "",
                groupName: r.text(3).flatMap { $0.isEmpty ? nil : $0 },
                handles: r.text(4)?.split(separator: ",").map(String.init) ?? []))
        }
        return out
    }

    /// The last `limit` rows of a chat, oldest first, with tapbacks folded onto their targets.
    func messages(chat: Int64, limit: Int64 = 80) throws -> [Message] {
        var rows: [Message] = []
        var tapbacks: [(target: String, sender: String, type: Int64, emoji: String?)] = []
        try query("""
            SELECT m.ROWID, m.guid, m.date, m.is_from_me, h.id, m.text, m.attributedBody,
                   m.associated_message_type, m.associated_message_guid, m.associated_message_emoji
            FROM chat_message_join cmj
            JOIN message m ON m.ROWID = cmj.message_id
            LEFT JOIN handle h ON h.ROWID = m.handle_id
            WHERE cmj.chat_id = ? AND m.item_type = 0
            ORDER BY cmj.message_date DESC LIMIT ?
            """, chat, limit) { r in
            let fromMe = r.int(3) != 0
            if r.int(7) == 0 {
                let raw = r.text(5).flatMap { $0.isEmpty ? nil : $0 } ?? r.data(6).flatMap(decodeAttributedBody) ?? ""
                let text = raw.replacingOccurrences(of: "\u{FFFC}", with: "").trimmingCharacters(in: .whitespacesAndNewlines)
                rows.append(Message(id: r.int(0), guid: r.text(1) ?? "", date: appleDate(r.int(2)),
                                    fromMe: fromMe, sender: fromMe ? nil : r.text(4), text: text))
            } else if let target = r.text(8) {
                tapbacks.append((target, fromMe ? "me" : r.text(4) ?? "", r.int(7), r.text(9)))
            }
        }
        rows.reverse()

        let index = Dictionary(uniqueKeysWithValues: rows.enumerated().map { ($1.id, $0) })
        try query("""
            SELECT maj.message_id, a.filename, a.mime_type
            FROM message_attachment_join maj JOIN attachment a ON a.ROWID = maj.attachment_id
            WHERE maj.message_id IN (SELECT message_id FROM chat_message_join
                                     WHERE chat_id = ? ORDER BY message_date DESC LIMIT ?)
            ORDER BY a.ROWID
            """, chat, limit) { r in
            guard let i = index[r.int(0)], let name = r.text(1), !name.hasSuffix("pluginPayloadAttachment") else { return }
            let url = URL(filePath: (name as NSString).expandingTildeInPath)
            guard FileManager.default.fileExists(atPath: url.path) else { return }  // pruned or offloaded to iCloud
            let mime = r.text(2) ?? UTType(filenameExtension: url.pathExtension)?.preferredMIMEType ?? ""
            rows[i].attachments.append(Attachment(url: url, mime: mime))
        }

        // One tapback per person per message: a later one replaces it, a 3000-series row removes it.
        var current: [String: [String: String]] = [:]
        for t in tapbacks.reversed() {
            var target = String(t.target.split(separator: "/").last ?? "")  // "p:0/GUID" or "bp:GUID"
            if target.hasPrefix("bp:") { target.removeFirst(3) }
            switch t.type {
            case 2000...2006: current[target, default: [:]][t.sender] = tapbackEmoji[t.type] ?? t.emoji
            case 3000...3006: current[target]?[t.sender] = nil
            default: break
            }
        }
        for i in rows.indices { rows[i].reactions = current[rows[i].guid]?.values.sorted() ?? [] }

        return rows.filter { !$0.text.isEmpty || !$0.attachments.isEmpty }
    }

    /// Chat identifiers pinned in Messages, in pin order. Empty when the format is not what we expect.
    static func pinnedIdentifiers() -> [String] {
        let url = URL.homeDirectory.appending(path: "Library/Preferences/com.apple.messages.pinning.plist")
        return ((NSDictionary(contentsOf: url)?["pD"] as? [String: Any])?["pP"] as? [String]) ?? []
    }

    private func query(_ sql: String, _ args: Int64..., row: (Row) -> Void) throws {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
            throw DBError(message: String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt) }
        for (i, arg) in args.enumerated() { sqlite3_bind_int64(stmt, Int32(i + 1), arg) }
        while true {
            switch sqlite3_step(stmt) {
            case SQLITE_ROW: row(Row(stmt: stmt))
            case SQLITE_DONE: return
            default: throw DBError(message: String(cString: sqlite3_errmsg(db)))
            }
        }
    }
}

private struct Row {
    let stmt: OpaquePointer
    func int(_ i: Int32) -> Int64 { sqlite3_column_int64(stmt, i) }
    func text(_ i: Int32) -> String? { sqlite3_column_text(stmt, i).map { String(cString: $0) } }
    func data(_ i: Int32) -> Data? {
        sqlite3_column_blob(stmt, i).map { Data(bytes: $0, count: Int(sqlite3_column_bytes(stmt, i))) }
    }
}

private let tapbackEmoji: [Int64: String] = [2000: "❤️", 2001: "👍", 2002: "👎", 2003: "😂", 2004: "‼️", 2005: "❓"]

/// chat.db stores dates as nanoseconds since 2001-01-01, which is Foundation's reference date.
private func appleDate(_ ns: Int64) -> Date { Date(timeIntervalSinceReferenceDate: Double(ns) / 1_000_000_000) }

/// Messages keeps most text only in `attributedBody`, an NSArchiver typedstream of an NSAttributedString.
private func decodeAttributedBody(_ data: Data) -> String? {
    (NSUnarchiver(forReadingWith: data)?.decodeObject() as? NSAttributedString)?.string
}
