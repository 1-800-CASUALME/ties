import Foundation
import GRDB
@testable import TiesCore

/// A miniature `chat.db` written from scratch: the handful of tables and columns
/// `MessagesCollector` reads, filled with one group chat between the person, one other
/// participant, and a pile of old filler so the 500-message cap and the 365-day window have
/// something to bite on. Never touches the real Messages store.
enum ChatDBFixture {
    /// The handle the tests hand to the collector as the person's phone channel.
    static let personHandle = "+966501234567"
    /// Another participant in the same group chat — the one who addresses the person.
    static let otherHandle = "+966500000001"
    /// The group chat's name, company-ish so it lands in `companies`.
    static let groupName = "Acme Inc"
    /// Messages older than a year, all from the person.
    static let fillerCount = 600
    /// Recent messages: three from the other participant, one from the person.
    static let recentCount = 4

    /// Creates `chat.db` inside `directory` and returns its URL.
    static func make(at directory: URL) throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("chat.db")
        let queue = try DatabaseQueue(path: url.path)
        try queue.write { db in
            try schema(db)
            try rows(db)
        }
        try queue.close()
        return url
    }

    private static func schema(_ db: Database) throws {
        try db.execute(sql: """
            CREATE TABLE handle (ROWID INTEGER PRIMARY KEY, id TEXT);
            CREATE TABLE chat (ROWID INTEGER PRIMARY KEY, chat_identifier TEXT, display_name TEXT);
            CREATE TABLE message (
                ROWID INTEGER PRIMARY KEY,
                text TEXT,
                attributedBody BLOB,
                handle_id INTEGER,
                is_from_me INTEGER,
                date INTEGER,
                cache_roomnames TEXT
            );
            CREATE TABLE chat_handle_join (chat_id INTEGER, handle_id INTEGER);
            CREATE TABLE chat_message_join (chat_id INTEGER, message_id INTEGER);
            """)
    }

    private static func rows(_ db: Database) throws {
        try db.execute(sql: "INSERT INTO handle (ROWID, id) VALUES (1, ?), (2, ?)",
                       arguments: [personHandle, otherHandle])
        try db.execute(sql: "INSERT INTO chat (ROWID, chat_identifier, display_name) VALUES (1, ?, ?)",
                       arguments: ["chat123456", groupName])
        try db.execute(sql: "INSERT INTO chat_handle_join (chat_id, handle_id) VALUES (1, 1), (1, 2)")

        // Dated relative to now, not to a literal 2026-08-01, so the 365-day window keeps
        // meaning the same thing whenever the suite is run.
        try insert(db, id: 1, handle: 2, text: "Dr. Sara can you check", daysAgo: 46)
        try insert(db, id: 2, handle: 2, text: "thanks Dr. Sara", daysAgo: 45)
        // Modern Messages rows often carry no `text` at all: the words live in a typedstream
        // blob, which the collector has to unwrap.
        try insert(db, id: 3, handle: 2, body: TypedStreamFixture.archive("Dr. Sara said yes"), daysAgo: 44)
        try insert(db, id: 4, handle: 1, text: "my profile https://www.linkedin.com/in/sara-ahmed/", daysAgo: 43)

        for index in 0..<fillerCount {
            // Older rows use Apple's legacy seconds-since-2001 timestamps; the collector has to
            // read both encodings, and both have to sort by real time.
            try insert(db, id: 5 + index, handle: 1, text: "filler \(index)",
                       daysAgo: 400 + Double(index), seconds: true)
        }
    }

    private static func insert(
        _ db: Database,
        id: Int,
        handle: Int,
        text: String? = nil,
        body: Data? = nil,
        daysAgo: Double,
        seconds: Bool = false
    ) throws {
        let elapsed = Date.now.addingTimeInterval(-daysAgo * 86_400).timeIntervalSinceReferenceDate
        let date = seconds ? Int64(elapsed) : Int64(elapsed * 1_000_000_000)
        try db.execute(
            sql: """
                INSERT INTO message (ROWID, text, attributedBody, handle_id, is_from_me, date, cache_roomnames)
                VALUES (?, ?, ?, ?, 0, ?, ?)
                """,
            arguments: [id, text, body, handle, date, groupName]
        )
        try db.execute(sql: "INSERT INTO chat_message_join (chat_id, message_id) VALUES (1, ?)", arguments: [id])
    }
}

/// Hand-built `streamtyped` archives, the shape Messages stores in `message.attributedBody`.
enum TypedStreamFixture {
    /// A real archive's byte sequence for "Hello world", written out so the parser is tested
    /// against the format rather than against a builder of our own.
    static let helloWorld = Data([
        0x04, 0x0B, 0x73, 0x74, 0x72, 0x65, 0x61, 0x6D, 0x74, 0x79, 0x70, 0x65, 0x64,  // \x04\x0bstreamtyped
        0x81, 0xE8, 0x03, 0x84, 0x01, 0x40, 0x84, 0x84, 0x84,
        0x12, 0x4E, 0x53, 0x41, 0x74, 0x74, 0x72, 0x69, 0x62, 0x75, 0x74, 0x65,
        0x64, 0x53, 0x74, 0x72, 0x69, 0x6E, 0x67,  // NSAttributedString
        0x00, 0x84, 0x84, 0x08, 0x4E, 0x53, 0x4F, 0x62, 0x6A, 0x65, 0x63, 0x74,  // NSObject
        0x00, 0x85, 0x92, 0x84, 0x84, 0x84,
        0x08, 0x4E, 0x53, 0x53, 0x74, 0x72, 0x69, 0x6E, 0x67,  // NSString
        0x01, 0x94, 0x84, 0x01, 0x2B,  // the run that precedes the payload
        0x0B,  // length: 11
        0x48, 0x65, 0x6C, 0x6C, 0x6F, 0x20, 0x77, 0x6F, 0x72, 0x6C, 0x64,  // Hello world
        0x86, 0x84, 0x02, 0x69, 0x49, 0x01, 0x0B, 0x86,
    ])

    /// The long-string encoding: `0x81` then a little-endian `UInt16` length.
    static let longText: Data = {
        let payload = Array(String(repeating: "ب", count: 200).utf8)  // 400 bytes, past 0x80
        var bytes = Array("NSString".utf8) + [0x01, 0x94, 0x84, 0x01, 0x2B]
        bytes += [0x81, UInt8(payload.count & 0xFF), UInt8(payload.count >> 8)]
        return Data(bytes + payload)
    }()

    /// An `attributedBody` with no string payload at all.
    static let withoutMarker = Data([0x04, 0x0B] + Array("streamtyped".utf8) + [0x81, 0xE8, 0x03, 0x84])

    /// Builds an archive for arbitrary text, picking the length encoding the way Messages does.
    static func archive(_ text: String) -> Data {
        let payload = Array(text.utf8)
        var bytes = Array("NSString".utf8) + [0x01, 0x94, 0x84, 0x01, 0x2B]
        if payload.count < 0x80 {
            bytes.append(UInt8(payload.count))
        } else {
            bytes += [0x81, UInt8(payload.count & 0xFF), UInt8(payload.count >> 8)]
        }
        return Data(bytes + payload)
    }
}
