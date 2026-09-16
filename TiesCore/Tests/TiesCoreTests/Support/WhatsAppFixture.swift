import Foundation
import GRDB
@testable import TiesCore

/// Builds a throwaway `ChatStorage.sqlite` with WhatsApp Desktop's Core Data table shapes, so
/// the collector can be exercised without ever touching the owner's real store.
///
/// The cast: **Sara Ahmed** (`+966501234567`, the person being researched), **Omar**
/// (`+966500000001`) and **Huda** (`+966500000002`) share a group; Sara and the user also have a
/// one-to-one chat; Omar has a one-to-one chat of his own that the collector must ignore.
enum WhatsAppFixture {
    static let saraPhone = "+966501234567"
    static let saraJID = "966501234567@s.whatsapp.net"
    static let omarJID = "966500000001@s.whatsapp.net"
    static let hudaJID = "966500000002@s.whatsapp.net"
    static let groupJID = "120363000000000001@g.us"

    /// The user's own push name, and Sara's — "Dr Sara A" is how she styles herself, which is
    /// close to but not the same as her Contacts name.
    static let saraPushName = "Dr Sara A"

    /// Messages older than this are outside the 365-day interaction window.
    static let fillerAge: TimeInterval = 500 * 86_400

    /// The number of filler messages, chosen to exceed the collector's 500-message cap.
    static let fillerCount = 600

    /// Every message the fixture writes, as (session, text, isFromMe, fromJID, days ago).
    /// Ages are relative to `now` so the 365-day window never rots.
    static func script() -> [(session: Int, text: String, isFromMe: Bool, fromJID: String?, daysAgo: Double)] {
        [
            // The group: other members address her by honorific and by a nickname.
            (2, "Dr. Sara can you check the report", false, omarJID, 20),
            (2, "thanks Dr. Sara", false, omarJID, 19),
            (2, "Dr. Sara said yes", false, omarJID, 18),
            (2, "Sara, ask Sarita to send it", false, hudaJID, 17),
            (2, "Sara, ask Sarita to send it", false, hudaJID, 16),
            (2, "Sara, ask Sarita to send it", false, hudaJID, 15),
            // The user's own group message: never a source of honorifics or aliases.
            (2, "Prof. Sara can you share it", true, nil, 14),
            // Sara's own group messages: her links count, the way she writes her own name doesn't.
            (2, "Capt. Sara is on the way", false, saraJID, 13),
            (2, "my profile https://www.linkedin.com/in/sara-ahmed/", false, saraJID, 12),
            // The one-to-one chat: ZFROMJID is null there, so direction comes from ZISFROMME.
            (1, "here is my site https://sara-ahmed.com", false, nil, 11),
            (1, "look at https://tracker.example.com/ref/123", true, nil, 10),
            (1, "see you tomorrow", true, nil, 9),
            // Omar's own chat: Sara is not in it, so none of it may reach her signals.
            (3, "Prof. Sara will speak on Tuesday", false, nil, 5),
        ]
    }

    /// The most recent message that involves Sara, in days ago — her one-to-one chat's last line,
    /// not the newer message in Omar's unrelated chat.
    static let lastContactDaysAgo: Double = 9

    /// Messages in the last 365 days either direction: three in the one-to-one chat plus Sara's
    /// two group messages. Other members' group chatter is not an interaction with her.
    static let expectedInteractions = 5

    /// Writes the fixture to a fresh temporary directory and returns the store's URL.
    static func make(now: Date = .now, pushName: String = saraPushName) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ties-whatsapp-fixture-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("ChatStorage.sqlite")

        let queue = try DatabaseQueue(path: url.path)
        try queue.write { db in
            try db.execute(sql: """
                CREATE TABLE ZWACHATSESSION (
                    Z_PK INTEGER PRIMARY KEY,
                    ZCONTACTJID TEXT,
                    ZPARTNERNAME TEXT,
                    ZLASTMESSAGEDATE REAL,
                    ZSESSIONTYPE INTEGER
                );
                CREATE TABLE ZWAMESSAGE (
                    Z_PK INTEGER PRIMARY KEY,
                    ZCHATSESSION INTEGER,
                    ZTEXT TEXT,
                    ZISFROMME INTEGER,
                    ZMESSAGEDATE REAL,
                    ZFROMJID TEXT
                );
                CREATE TABLE ZWAPROFILEPUSHNAME (
                    Z_PK INTEGER PRIMARY KEY,
                    ZJID TEXT,
                    ZPUSHNAME TEXT
                );
                CREATE TABLE ZWAGROUPMEMBER (
                    Z_PK INTEGER PRIMARY KEY,
                    ZCHATSESSION INTEGER,
                    ZMEMBERJID TEXT
                );
                """)

            func coreData(_ date: Date) -> Double { date.timeIntervalSinceReferenceDate }
            func daysAgo(_ days: Double) -> Double { coreData(now.addingTimeInterval(-days * 86_400)) }

            for (pk, jid, name, type, last) in [
                (1, saraJID, "Sara Ahmed", 0, lastContactDaysAgo),
                (2, groupJID, "Clinic Team", 1, 12.0),
                (3, omarJID, "Omar", 0, 5.0),
            ] as [(Int, String, String, Int, Double)] {
                try db.execute(
                    sql: "INSERT INTO ZWACHATSESSION VALUES (?, ?, ?, ?, ?)",
                    arguments: [pk, jid, name, daysAgo(last), type]
                )
            }

            for (index, jid) in [saraJID, omarJID, hudaJID].enumerated() {
                try db.execute(
                    sql: "INSERT INTO ZWAGROUPMEMBER VALUES (?, ?, ?)",
                    arguments: [index + 1, 2, jid]
                )
            }

            try db.execute(
                sql: "INSERT INTO ZWAPROFILEPUSHNAME VALUES (?, ?, ?)",
                arguments: [1, saraJID, pushName]
            )
            try db.execute(
                sql: "INSERT INTO ZWAPROFILEPUSHNAME VALUES (?, ?, ?)",
                arguments: [2, omarJID, "Omar K"]
            )

            var pk = 0
            for line in script() {
                pk += 1
                try db.execute(
                    sql: "INSERT INTO ZWAMESSAGE VALUES (?, ?, ?, ?, ?, ?)",
                    arguments: [pk, line.session, line.text, line.isFromMe ? 1 : 0, daysAgo(line.daysAgo), line.fromJID]
                )
            }
            // Older than the interaction window and more numerous than the read cap.
            for filler in 0..<fillerCount {
                pk += 1
                try db.execute(
                    sql: "INSERT INTO ZWAMESSAGE VALUES (?, ?, ?, ?, ?, ?)",
                    arguments: [pk, 1, "ok", filler % 2, daysAgo(500 + Double(filler)), nil]
                )
            }
        }
        // Close the writer before the collector snapshots the file.
        try queue.close()
        return url
    }
}
