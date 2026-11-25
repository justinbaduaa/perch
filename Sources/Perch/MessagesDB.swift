import Foundation
import SQLite3
import UniformTypeIdentifiers

/// A conversation in chat.db. `guid` is the id Messages' AppleScript uses for the chat.
nonisolated struct Chat: Identifiable, Hashable {
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
    /// A group's own picture, set in Messages.
    var photo: URL?

    var isGroup: Bool { guid.contains(";+;") }
    /// The other person in a one-to-one chat. A group down to one other member is still a group.
    var person: String? { isGroup ? nil : handles.first }
    /// What Messages' Hide Alerts list calls this chat.
    var muteKey: String { isGroup ? groupID ?? "" : identifier }
}

nonisolated struct Attachment: Hashable {
    let url: URL
    let mime: String
    var isAudio: Bool { mime.hasPrefix("audio/") }
    var isImage: Bool { mime.hasPrefix("image/") }
    var isVideo: Bool { mime.hasPrefix("video/") }
}

/// A link's preview card, as Messages saved it when the link was sent.
nonisolated struct LinkPreview: Hashable {
    let url: URL
    let title: String?
    let site: String?
    /// The page's picture, which Messages keeps as one of the message's attachments.
    var image: URL?
}

/// How far a message of mine has got, as Messages writes under the last one.
nonisolated enum Receipt: Equatable {
    case sending, sent, delivered, read(Date), failed
}

nonisolated struct Message: Identifiable, Equatable {
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
    /// Mine only.
    var receipt: Receipt?

    /// Photos, videos and other files: what shows as thumbnails, and what Quick Look steps through.
    var media: [Attachment] { attachments.filter { !$0.isAudio } }
}

nonisolated struct DBError: Error { let message: String }

/// Read-only view of the Messages database, read off the main thread. Opening it needs Full Disk Access.
actor MessagesDB {
    static let path = ProcessInfo.processInfo.environment["PERCH_DB"]
        ?? URL.homeDirectory.appending(path: "Library/Messages/chat.db").path
    /// A fixture database has no Messages behind it, so sends and chat actions only pretend.
    static let isFixture = ProcessInfo.processInfo.environment["PERCH_DB"] != nil
    /// The most messages a thread loads.
    static let threadLength: Int64 = 80

    /// Whether Perch can open chat.db, which only Full Disk Access allows.
    static var readable: Bool { FileHandle(forReadingAtPath: path) != nil }

    private var db: OpaquePointer?

    /// Opens without reading, so a missing Full Disk Access shows on the first read, not here.
    init(path: String) throws {
        guard sqlite3_open_v2(path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            defer { sqlite3_close(db) }
            throw DBError(message: String(cString: sqlite3_errmsg(db)))
        }
    }

    isolated deinit { sqlite3_close(db) }

    /// Changes whenever Messages writes anything: a message, an edit or unsend, a read, a receipt, a download finishing.
    /// It counts per connection, so marks from two connections can't be compared.
    func mark() throws -> Int64 {
        var version: Int64 = 0
        try query("PRAGMA data_version") { version = $0.int(0) }
        return version
    }

    /// Most recently active conversations first. Unread rows are found once through Messages' unread index, and my
    /// newest by walking each chat back from its end: a MAX over each chat's messages took 250 ms on 300k messages.
    func chats() throws -> [Chat] {
        var out: [Chat] = []
        var photos: [(chat: Int, guid: String)] = []
        try query("""
            WITH top AS (
              SELECT c.ROWID AS id, c.guid, c.chat_identifier, c.display_name, c.group_id, MAX(cmj.message_date) AS last
              FROM chat c JOIN chat_message_join cmj ON cmj.chat_id = c.ROWID
              GROUP BY c.ROWID ORDER BY last DESC LIMIT 100),
            unread AS MATERIALIZED (
              SELECT j.chat_id, MAX(m.ROWID) AS row FROM message m CROSS JOIN chat_message_join j
              WHERE j.message_id = m.ROWID AND m.is_from_me = 0 AND m.is_read = 0
                AND m.item_type = 0 AND m.associated_message_type = 0
              GROUP BY j.chat_id)
            SELECT id, guid, chat_identifier, display_name,
              (SELECT group_concat(h.id, ',') FROM chat_handle_join j
                 JOIN handle h ON h.ROWID = j.handle_id WHERE j.chat_id = top.id),
              last, group_id, unread.row,
              (SELECT j.message_id FROM chat_message_join j JOIN message m ON m.ROWID = j.message_id
                 WHERE j.chat_id = top.id AND m.is_from_me = 1 ORDER BY j.message_id DESC LIMIT 1),
              (SELECT properties FROM chat WHERE ROWID = top.id)
            FROM top LEFT JOIN unread ON unread.chat_id = top.id ORDER BY last DESC
            """) { r in
            let unread = r.int(7), mine = r.int(8)  // 0 when there is none
            out.append(Chat(
                id: r.int(0), guid: r.text(1) ?? "", identifier: r.text(2) ?? "",
                groupName: r.text(3).flatMap { $0.isEmpty ? nil : $0 },
                handles: r.text(4)?.split(separator: ",").map(String.init) ?? [],
                groupID: r.text(6),
                lastActive: appleDate(r.int(5)),
                unread: unread > mine ? unread : nil))
            // A group's picture is an attachment, named by `groupPhotoGuid` in the chat's properties plist.
            if out[out.count - 1].isGroup, let data = r.data(9),
               let properties = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
               let guid = properties["groupPhotoGuid"] as? String {
                photos.append((out.count - 1, guid))
            }
        }
        for (i, guid) in photos {
            try query("SELECT filename FROM attachment WHERE guid = ?", guid) { r in
                out[i].photo = r.text(0).map { URL(filePath: ($0 as NSString).expandingTildeInPath) }
            }
        }
        return out
    }

    /// The last `threadLength` rows of a chat, oldest first, with tapbacks folded onto their targets.
    func messages(chat: Int64) throws -> [Message] {
        var rows: [Message] = []
        var tapbacks: [(target: String, sender: String, type: Int64, emoji: String?)] = []
        var linkImages: [Int64: Int] = [:]  // message ROWID to which of its preview files is the picture
        try query("""
            SELECT m.ROWID, m.guid, m.date, m.is_from_me, h.id, m.text, m.attributedBody,
                   m.associated_message_type, m.associated_message_guid, m.associated_message_emoji,
                   m.thread_originator_guid, m.balloon_bundle_id, m.payload_data,
                   m.is_sent, m.is_delivered, m.date_read, m.error
            FROM chat_message_join cmj
            JOIN message m ON m.ROWID = cmj.message_id
            LEFT JOIN handle h ON h.ROWID = m.handle_id
            WHERE cmj.chat_id = ? AND m.item_type = 0
            ORDER BY cmj.message_date DESC LIMIT ?
            """, chat, Self.threadLength) { r in
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
                if fromMe {
                    message.receipt = r.int(16) != 0 ? .failed : r.int(15) > 0 ? .read(appleDate(r.int(15)))
                        : r.int(14) != 0 ? .delivered : r.int(13) != 0 ? .sent : .sending
                }
                rows.append(message)
            } else if let target = r.text(8) {
                tapbacks.append((target, fromMe ? "me" : r.text(4) ?? "", r.int(7), r.text(9)))
            }
        }
        rows.reverse()

        let index = Dictionary(uniqueKeysWithValues: rows.enumerated().map { ($1.id, $0) })
        var previewFiles: [Int: [URL]] = [:]  // row index to its link preview's files, in order
        // Exactly the rows above (ids are integers, so nothing to escape).
        try query("""
            SELECT maj.message_id, a.filename, a.mime_type
            FROM message_attachment_join maj JOIN attachment a ON a.ROWID = maj.attachment_id
            WHERE maj.message_id IN (\(index.keys.map(String.init).joined(separator: ",")))
            ORDER BY a.ROWID
            """) { r in
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
            case 2000...2006:  // the six, then 2006 for any other emoji
                let i = Int(t.type - 2000), six = HiddenMessages.tapbacks
                current[target, default: [:]][t.sender] = i < six.count ? six[i].emoji : t.emoji
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

    private func query(_ sql: String, _ args: any Bindable..., row: (Row) -> Void) throws {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
            throw DBError(message: String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt) }
        for (i, arg) in args.enumerated() { arg.bind(stmt, Int32(i + 1)) }
        while true {
            switch sqlite3_step(stmt) {
            case SQLITE_ROW: row(Row(stmt: stmt))
            case SQLITE_DONE: return
            default: throw DBError(message: String(cString: sqlite3_errmsg(db)))
            }
        }
    }
}

/// What a `?` in a query can stand for.
nonisolated private protocol Bindable { func bind(_ stmt: OpaquePointer, _ index: Int32) }
extension Int64: Bindable { func bind(_ stmt: OpaquePointer, _ index: Int32) { sqlite3_bind_int64(stmt, index, self) } }
extension String: Bindable {
    func bind(_ stmt: OpaquePointer, _ index: Int32) {
        sqlite3_bind_text(stmt, index, self, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))  // SQLITE_TRANSIENT: sqlite copies it
    }
}

nonisolated private struct Row {
    let stmt: OpaquePointer
    func int(_ i: Int32) -> Int64 { sqlite3_column_int64(stmt, i) }
    func text(_ i: Int32) -> String? { sqlite3_column_text(stmt, i).map { String(cString: $0) } }
    func data(_ i: Int32) -> Data? {
        sqlite3_column_blob(stmt, i).map { Data(bytes: $0, count: Int(sqlite3_column_bytes(stmt, i))) }
    }
}

/// Reads the preview Messages saved for a link: an NSKeyedArchiver plist of Messages' own classes, walked as plain
/// dictionaries (as Beeper's platform-imessage does). The picture is an index into the message's preview files.
nonisolated func linkPreview(_ data: Data) -> (link: LinkPreview, image: Int?)? {
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
nonisolated private func archiveUID(_ value: Any) -> Int? {
    if let dict = value as? [String: Any] { return dict.count == 1 ? dict["CF$UID"] as? Int : nil }
    if value is String || value is Data || value is NSNumber || value is [Any] { return nil }
    let text = String(describing: value)  // "<CFKeyedArchiverUID 0x…>{value = 7}"
    guard text.contains("CFKeyedArchiverUID"), let r = text.range(of: #"value = \d+"#, options: .regularExpression) else { return nil }
    return Int(text[r].dropFirst("value = ".count))
}

/// chat.db stores dates as nanoseconds since 2001-01-01, which is Foundation's reference date.
nonisolated private func appleDate(_ ns: Int64) -> Date { Date(timeIntervalSinceReferenceDate: Double(ns) / 1_000_000_000) }

/// Messages keeps most text only in `attributedBody`, an NSArchiver typedstream of an NSAttributedString.
nonisolated private func decodeAttributedBody(_ data: Data) -> String? {
    (NSUnarchiver(forReadingWith: data)?.decodeObject() as? NSAttributedString)?.string
}
