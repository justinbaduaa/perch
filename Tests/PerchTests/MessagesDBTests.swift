import Foundation
import SQLite3
import Testing
@testable import Perch

/// Builds a chat.db with the columns Perch reads and checks what comes back.
@Test func readsTextAttachmentsAndTapbacks() throws {
    let dir = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let photo = dir.appending(path: "photo.jpg")
    try Data([0xFF]).write(to: photo)
    let archived = NSArchiver.archivedData(withRootObject: NSAttributedString(string: "from attributedBody"))
    let blob = archived.map { String(format: "%02x", $0) }.joined()

    let path = dir.appending(path: "chat.db").path
    var db: OpaquePointer?
    sqlite3_open(path, &db)
    let sql = """
        CREATE TABLE handle (ROWID INTEGER PRIMARY KEY, id TEXT);
        CREATE TABLE chat (ROWID INTEGER PRIMARY KEY, guid TEXT, chat_identifier TEXT, display_name TEXT);
        CREATE TABLE chat_handle_join (chat_id INTEGER, handle_id INTEGER);
        CREATE TABLE message (ROWID INTEGER PRIMARY KEY, guid TEXT, text TEXT, attributedBody BLOB, handle_id INTEGER,
          date INTEGER, is_from_me INTEGER, item_type INTEGER DEFAULT 0, associated_message_type INTEGER DEFAULT 0,
          associated_message_guid TEXT, associated_message_emoji TEXT);
        CREATE TABLE chat_message_join (chat_id INTEGER, message_id INTEGER, message_date INTEGER);
        CREATE TABLE attachment (ROWID INTEGER PRIMARY KEY, filename TEXT, mime_type TEXT);
        CREATE TABLE message_attachment_join (message_id INTEGER, attachment_id INTEGER);

        INSERT INTO handle VALUES (1, '+15551234567');
        INSERT INTO chat VALUES (1, 'any;-;+15551234567', '+15551234567', ''), (2, 'any;+;chat9', 'chat9', 'Team');
        INSERT INTO chat_handle_join VALUES (1, 1), (2, 1);
        INSERT INTO message (ROWID, guid, text, attributedBody, handle_id, date, is_from_me, item_type,
                             associated_message_type, associated_message_guid) VALUES
          (1, 'A', 'hello', NULL, 1, 1000, 0, 0, 0, NULL),
          (2, 'B', NULL, X'\(blob)', 0, 2000, 1, 0, 0, NULL),
          (3, 'C', char(65532), NULL, 1, 3000, 0, 0, 0, NULL),
          (4, 'R1', NULL, NULL, 1, 4000, 0, 0, 2000, 'p:0/B'),
          (5, 'R2', NULL, NULL, 0, 5000, 1, 0, 2003, 'p:0/A'),
          (6, 'R3', NULL, NULL, 1, 6000, 0, 0, 3000, 'p:0/B'),
          (7, 'G', NULL, NULL, 1, 7000, 0, 1, 0, NULL),
          (8, 'D', NULL, NULL, 1, 8000, 0, 0, 0, NULL),
          (9, 'Z', 'old group', NULL, 1, 500, 0, 0, 0, NULL);
        INSERT INTO chat_message_join SELECT 1, ROWID, date FROM message WHERE ROWID < 9;
        INSERT INTO chat_message_join VALUES (2, 9, 500);
        INSERT INTO attachment VALUES (1, '\(photo.path)', 'image/jpeg'), (2, '/nope/gone.jpg', 'image/jpeg');
        INSERT INTO message_attachment_join VALUES (3, 1), (8, 2);
        """
    #expect(sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK)
    sqlite3_close(db)

    let messages = try MessagesDB(path: path)
    #expect(try messages.chats().map(\.groupName) == [nil, "Team"])
    #expect(try messages.chats().first?.handles == ["+15551234567"])

    let rows = try messages.messages(chat: 1)
    #expect(rows.map(\.text) == ["hello", "from attributedBody", ""])
    #expect(rows.map(\.reactions) == [["😂"], [], []])  // B's ❤️ was removed by the 3000 row
    #expect(rows.map(\.mine) == ["😂", nil, nil])  // the 😂 on A is mine
    #expect(rows[1].fromMe && rows[0].sender == "+15551234567")
    #expect(rows[2].attachments.map(\.url.path) == [photo.path])

    #expect(ContactBook.key("+1 (555) 123-4567") == ContactBook.key("5551234567"))
}

/// A pending send stops showing once a matching row from me lands, and not before.
@Test func pendingSendSettlesWhenItsRowLands() {
    let sent = Date.now
    let text = Pending(id: -1, chatID: 1, text: "on it", file: nil, date: sent)
    let file = Pending(id: -2, chatID: 1, text: "", file: URL(filePath: "/tmp/a/IMG_1.heic"), date: sent)
    func row(_ text: String, fromMe: Bool = true, at date: Date = sent, file: String? = nil) -> Message {
        Message(id: 1, guid: "g", date: date, fromMe: fromMe, sender: nil, text: text,
                attachments: file.map { [Attachment(url: URL(filePath: $0), mime: "image/heic")] } ?? [])
    }
    #expect(!text.landed(in: [row("on it", fromMe: false)]))
    #expect(!text.landed(in: [row("on it", at: sent.addingTimeInterval(-60))]))  // an older identical message
    #expect(text.landed(in: [row("on it")]))
    #expect(!file.landed(in: [row("on it")]))
    #expect(file.landed(in: [row("", file: "/Users/x/Library/Messages/Attachments/ab/IMG_1.heic")]))
}

/// Hovering never moves the hovered avatar, and parting never needs more than the strip's fixed width.
@Test func focusedAvatarHoldsStillInsideAFixedWidth() {
    for count in 1...6 {
        let resting = AvatarStrip.layout(count, parting: nil), width = AvatarStrip.width(count)
        for focus in 0..<count {
            let parted = AvatarStrip.layout(count, parting: focus)
            #expect(parted[focus] == resting[focus])
            #expect(parted.allSatisfy { $0 >= 0 && $0 + AvatarStrip.size <= width })
        }
    }
}

/// Only a video in a capture folder made after recording started counts; old captures and screenshots don't.
@Test func picksUpOnlyTheNewCleanShotVideo() throws {
    let media = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: media) }
    func capture(_ folder: String, _ file: String) throws -> URL {
        let dir = media.appending(path: folder)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appending(path: file)
        try Data([0]).write(to: url)
        return url
    }
    _ = try capture("media_old", "CleanShot old.mp4")
    let since = Date.now
    _ = try capture("media_shot", "CleanShot shot.png")
    #expect(Recorder.capture(in: media, since: since) == nil)
    let video = try capture("media_new", "CleanShot new.mp4")
    let found = Recorder.capture(in: media, since: since)
    #expect(found?.resolvingSymlinksInPath() == video.resolvingSymlinksInPath(), "found \(String(describing: found)) want \(video)")
}
