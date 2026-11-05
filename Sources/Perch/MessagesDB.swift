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
    /// What Messages' Hide Alerts list calls a group chat. A 1:1 chat goes by its identifier there.
    var groupID: String?
    var lastActive = Date.distantPast
    /// ROWID of their newest unread message, unless I've written since, which means I read it.
    var unread: Int64?

    var isGroup: Bool { guid.contains(";+;") }
}

struct Attachment: Hashable {
    let url: URL
    let mime: String
    var isAudio: Bool { mime.hasPrefix("audio/") }
    var isVideo: Bool { mime.hasPrefix("video/") }
}

/// A link's preview card, as Messages saved it when the link was sent.
struct LinkPreview: Hashable {
    let url: URL
    let title: String?
    let site: String?
    /// The page's picture, which Messages keeps as one of the message's attachments.
    var image: URL?
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
    /// My own tapback on it, if any.
    var mine: String?
    /// The guid of the message this replies to, in a thread.
    var replyTo: String?
    var link: LinkPreview?
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

    /// Changes when something is read or marked unread anywhere, which adds no row.
    func unreadCount() throws -> Int64 {
        var n: Int64 = 0
        try query("SELECT COUNT(*) FROM message WHERE is_read = 0 AND is_from_me = 0") { n = $0.int(0) }
        return n
    }

    /// Most recently active conversations first.
    func chats(limit: Int64 = 100) throws -> [Chat] {
        var out: [Chat] = []
        try query("""
            WITH top AS (
              SELECT c.ROWID AS id, c.guid, c.chat_identifier, c.display_name, c.group_id, MAX(cmj.message_date) AS last
              FROM chat c JOIN chat_message_join cmj ON cmj.chat_id = c.ROWID
              GROUP BY c.ROWID ORDER BY last DESC LIMIT ?)
            SELECT id, guid, chat_identifier, display_name,
              (SELECT group_concat(h.id, ',') FROM chat_handle_join j
                 JOIN handle h ON h.ROWID = j.handle_id WHERE j.chat_id = top.id),
              last, group_id,
              (SELECT MAX(m.ROWID) FROM chat_message_join j JOIN message m ON m.ROWID = j.message_id
                 WHERE j.chat_id = top.id AND m.is_from_me = 0 AND m.is_read = 0
                   AND m.item_type = 0 AND m.associated_message_type = 0),
              (SELECT MAX(m.ROWID) FROM chat_message_join j JOIN message m ON m.ROWID = j.message_id
                 WHERE j.chat_id = top.id AND m.is_from_me = 1)
            FROM top ORDER BY last DESC
            """, limit) { r in
            let unread = r.int(7), mine = r.int(8)  // 0 when there is none
            out.append(Chat(
                id: r.int(0), guid: r.text(1) ?? "", identifier: r.text(2) ?? "",
                groupName: r.text(3).flatMap { $0.isEmpty ? nil : $0 },
                handles: r.text(4)?.split(separator: ",").map(String.init) ?? [],
                groupID: r.text(6),
                lastActive: appleDate(r.int(5)),
                unread: unread > mine ? unread : nil))
        }
        return out
    }

    /// The last `limit` rows of a chat, oldest first, with tapbacks folded onto their targets.
    func messages(chat: Int64, limit: Int64 = 80) throws -> [Message] {
        var rows: [Message] = []
        var tapbacks: [(target: String, sender: String, type: Int64, emoji: String?)] = []
        var linkImages: [Int64: Int] = [:]  // message ROWID to which of its preview files is the picture
        try query("""
            SELECT m.ROWID, m.guid, m.date, m.is_from_me, h.id, m.text, m.attributedBody,
                   m.associated_message_type, m.associated_message_guid, m.associated_message_emoji,
                   m.thread_originator_guid, m.balloon_bundle_id, m.payload_data
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
                var message = Message(id: r.int(0), guid: r.text(1) ?? "", date: appleDate(r.int(2)),
                                      fromMe: fromMe, sender: fromMe ? nil : r.text(4), text: text, replyTo: r.text(10))
                if r.text(11) == "com.apple.messages.URLBalloonProvider", let preview = r.data(12).flatMap(linkPreview) {
                    message.link = preview.link
                    linkImages[message.id] = preview.image
                }
                rows.append(message)
            } else if let target = r.text(8) {
                tapbacks.append((target, fromMe ? "me" : r.text(4) ?? "", r.int(7), r.text(9)))
            }
        }
        rows.reverse()

        let index = Dictionary(uniqueKeysWithValues: rows.enumerated().map { ($1.id, $0) })
        var previewFiles: [Int: [URL]] = [:]  // row index to its link preview's files, in order
        try query("""
            SELECT maj.message_id, a.filename, a.mime_type
            FROM message_attachment_join maj JOIN attachment a ON a.ROWID = maj.attachment_id
            WHERE maj.message_id IN (SELECT message_id FROM chat_message_join
                                     WHERE chat_id = ? ORDER BY message_date DESC LIMIT ?)
            ORDER BY a.ROWID
            """, chat, limit) { r in
            guard let i = index[r.int(0)], let name = r.text(1) else { return }
            let url = URL(filePath: (name as NSString).expandingTildeInPath)
            if name.hasSuffix("pluginPayloadAttachment") { return previewFiles[i, default: []].append(url) }
            guard FileManager.default.fileExists(atPath: url.path) else { return }  // pruned or offloaded to iCloud
            let mime = r.text(2) ?? UTType(filenameExtension: url.pathExtension)?.preferredMIMEType ?? ""
            rows[i].attachments.append(Attachment(url: url, mime: mime))
        }
        for (i, files) in previewFiles {
            guard let n = linkImages[rows[i].id], files.indices.contains(n),
                  FileManager.default.fileExists(atPath: files[n].path) else { continue }
            rows[i].link?.image = files[n]
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
        for i in rows.indices {
            rows[i].reactions = current[rows[i].guid]?.values.sorted() ?? []
            rows[i].mine = current[rows[i].guid]?["me"]
        }

        return rows.filter { !$0.text.isEmpty || !$0.attachments.isEmpty }
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

/// Reads the preview Messages saved for a link: an NSKeyedArchiver plist of Messages' own classes, walked as plain
/// dictionaries (as Beeper's platform-imessage does). The picture is an index into the message's preview files.
func linkPreview(_ data: Data) -> (link: LinkPreview, image: Int?)? {
    guard let archive = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
          let objects = archive["$objects"] as? [Any],
          let root = (archive["$top"] as? [String: Any])?["root"] else { return nil }
    func resolve(_ value: Any, _ depth: Int) -> Any? {
        guard depth < 32 else { return nil }  // archives can refer back to themselves
        if let uid = archiveUID(value) { return objects.indices.contains(uid) ? resolve(objects[uid], depth + 1) : nil }
        switch value {
        case let string as String:
            return string == "$null" ? nil : string
        case let dict as [String: Any]:
            if let keys = dict["NS.keys"] as? [Any], let values = dict["NS.objects"] as? [Any] {
                var out: [String: Any] = [:]
                for (k, v) in zip(keys, values) { if let k = resolve(k, depth + 1) as? String { out[k] = resolve(v, depth + 1) } }
                return out
            }
            if let values = dict["NS.objects"] as? [Any] { return values.compactMap { resolve($0, depth + 1) } }
            var out: [String: Any] = [:]
            for (k, v) in dict where k != "$class" { out[k] = resolve(v, depth + 1) }
            return out
        default:
            return value
        }
    }
    guard let meta = (resolve(root, 0) as? [String: Any])?["richLinkMetadata"] as? [String: Any] else { return nil }
    func string(_ v: Any?) -> String? { (v as? String) ?? ((v as? [String: Any])?["NS.string"] as? String) }
    func url(_ v: Any?) -> URL? { string((v as? [String: Any])?["NS.relative"] ?? v).flatMap(URL.init(string:)) }
    guard let link = url(meta["originalURL"]) ?? url(meta["URL"]) else { return nil }
    let title = string(meta["title"]).flatMap { $0.isEmpty ? nil : $0 }
    let image = (meta["image"] as? [String: Any])?["richLinkImageAttachmentSubstituteIndex"] as? Int
    return (LinkPreview(url: link, title: title, site: string(meta["siteName"]), image: nil), image)
}

/// A keyed archive's reference to another of its objects. Binary plists hold these as an opaque CF type.
private func archiveUID(_ value: Any) -> Int? {
    if let dict = value as? [String: Any] { return dict.count == 1 ? dict["CF$UID"] as? Int : nil }
    if value is String || value is Data || value is NSNumber || value is [Any] { return nil }
    let text = String(describing: value)  // "<CFKeyedArchiverUID 0x…>{value = 7}"
    guard text.contains("CFKeyedArchiverUID"), let r = text.range(of: #"value = \d+"#, options: .regularExpression) else { return nil }
    return Int(text[r].dropFirst("value = ".count))
}

/// chat.db stores dates as nanoseconds since 2001-01-01, which is Foundation's reference date.
private func appleDate(_ ns: Int64) -> Date { Date(timeIntervalSinceReferenceDate: Double(ns) / 1_000_000_000) }

/// Messages keeps most text only in `attributedBody`, an NSArchiver typedstream of an NSAttributedString.
private func decodeAttributedBody(_ data: Data) -> String? {
    (NSUnarchiver(forReadingWith: data)?.decodeObject() as? NSAttributedString)?.string
}
