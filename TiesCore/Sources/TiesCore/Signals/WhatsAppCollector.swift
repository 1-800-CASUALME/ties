import Foundation
import GRDB

/// Reads WhatsApp Desktop's `ChatStorage.sqlite` for what it knows about one person: the push
/// name they chose for themselves, how the other members of their groups address them, the links
/// they shared, and how recently and how often the user and they have talked (spec §3, §4.2).
///
/// The store is never opened in place — `SourceSnapshot` copies it, so WhatsApp is never locked
/// and nothing is ever written back. Nothing here leaves the Mac.
public struct WhatsAppCollector: SourceCollector {
    /// Messages read per person in one pass (spec §3), applied in SQL over the person's sessions.
    static let messageCap = 500

    /// The window `interactions` counts over.
    static let interactionWindow: TimeInterval = 365 * 86_400

    /// WhatsApp's own suffix for a one-to-one address, and for a group's.
    static let userSuffix = "@s.whatsapp.net"
    static let groupSuffix = "@g.us"

    public let chatStorage: URL

    /// The one snapshot a whole collection run shares, so a large `ChatStorage.sqlite` is copied
    /// once rather than once per person.
    private let session = SnapshotSession()

    public init(
        chatStorage: URL = URL(
            fileURLWithPath: NSHomeDirectory()
                + "/Library/Group Containers/group.net.whatsapp.WhatsApp.shared/ChatStorage.sqlite"
        )
    ) {
        self.chatStorage = chatStorage
    }

    public var id: String { "whatsapp" }
    public var displayName: String { "WhatsApp" }

    public func status() -> SourceStatus {
        .ofFile(at: chatStorage)
    }

    // MARK: - Session

    /// Copies the store once for the whole run. Reports the same errors `collect` would.
    public func beginSession() async throws {
        try check(status())
        try session.begin(chatStorage)
    }

    public func endSession() async {
        session.end()
    }

    /// Turns a status into the error `collect`/`beginSession` throw for it.
    private func check(_ status: SourceStatus) throws {
        switch status {
        case .ready: return
        case .unavailable: throw SourceError.unavailable
        case .needsAccess: throw SourceError.needsAccess
        case .error(let message): throw SourceError.malformed(message)
        }
    }

    /// WhatsApp addresses a phone by its E.164 digits without the `+`, so `+966501234567`
    /// becomes `966501234567@s.whatsapp.net`. Returns `nil` for a value holding no digits.
    static func jid(forPhone phone: String) -> String? {
        let digits = phone.filter(\.isNumber)
        return digits.isEmpty ? nil : digits + userSuffix
    }

    public func collect(for input: ProbeInput, since: Date?) async throws -> LocalSignals {
        let empty = LocalSignals(personId: input.person.id)
        let jids = Set(input.phonesE164.compactMap(Self.jid(forPhone:))).sorted()
        // No phone number means no WhatsApp address to look for; don't even copy the store.
        guard !jids.isEmpty else { return empty }

        // Ask first: without Full Disk Access the store's own existence is hidden, so opening it
        // first would report a missing store where access is what is missing.
        try check(status())

        // Inside a run the session's snapshot is reused; on its own, `collect` copies the store
        // for this one call and closes the copy again.
        if let snapshot = session.current {
            return try await read(from: snapshot, jids: jids, input: input, since: since, empty: empty)
        }
        let snapshot = try session.single(chatStorage)
        defer { snapshot.close() }
        return try await read(from: snapshot, jids: jids, input: input, since: since, empty: empty)
    }

    private func read(
        from snapshot: SourceSnapshot,
        jids: [String],
        input: ProbeInput,
        since: Date?,
        empty: LocalSignals
    ) async throws -> LocalSignals {
        do {
            return try await snapshot.reader.read { db in
                try read(db, jids: jids, input: input, since: since, empty: empty)
            }
        } catch let error as DatabaseError {
            // A store whose Core Data shape has moved on is not an access problem.
            throw SourceError.malformed(error.message ?? "unreadable ChatStorage.sqlite")
        }
    }

    // MARK: - Reading

    private func read(
        _ db: Database,
        jids: [String],
        input: ProbeInput,
        since: Date?,
        empty: LocalSignals
    ) throws -> LocalSignals {
        let sessions = try sessionIds(db, jids: jids)
        let pushNames = try pushNames(db, jids: jids)
        guard !sessions.group.isEmpty || !sessions.direct.isEmpty || !pushNames.isEmpty else { return empty }

        var signals = empty
        signals.sources = [id]

        // A capitalised word only reads as a nickname next to a mention of a name we already
        // know, so the person's Contacts name is the anchor for both text rules.
        let names = [input.fullName]

        let text = try messageText(db, jids: Set(jids), sessions: sessions, since: since)
        signals.honorifics = SignalRules.honorifics(in: text.byOtherMembers, names: names)
        signals.aliases = Self.union(
            pushNames.filter {
                NameMatcher.similarity(personName: input.fullName, candidateName: $0) < SignalRules.aliasNameGate
            },
            SignalRules.aliases(in: text.byOtherMembers, names: names)
        )
        signals.links = SignalRules.links(in: text.byPerson)
        signals.companies = try companies(db, groups: sessions.group)

        let tally = try tally(db, jids: jids, direct: sessions.direct, since: since)
        signals.lastContact = tally.lastContact
        signals.interactions = tally.interactions
        return signals
    }

    /// The person's chat sessions, split into the groups they are a member of and the one-to-one
    /// chats addressed to them. A session is a group when Core Data says so (`ZSESSIONTYPE == 1`)
    /// or when its address is a group address.
    ///
    /// Membership comes from `ZWAGROUPMEMBER`, plus a fallback for the stores where that table is
    /// absent or empty (WhatsApp prunes it, and then a group the person is plainly in would be
    /// invisible): a session holding a message whose `ZFROMJID` is theirs is a session they are
    /// in, whatever the membership table says.
    private func sessionIds(_ db: Database, jids: [String]) throws -> (group: Set<Int64>, direct: Set<Int64>) {
        let list = Self.placeholders(jids.count)
        var clauses = ["ZCONTACTJID IN (\(list))"]
        var arguments = jids
        if try db.tableExists("ZWAGROUPMEMBER") {
            clauses.append("Z_PK IN (SELECT ZCHATSESSION FROM ZWAGROUPMEMBER WHERE ZMEMBERJID IN (\(list)))")
            arguments += jids
        }
        clauses.append("Z_PK IN (SELECT ZCHATSESSION FROM ZWAMESSAGE WHERE ZFROMJID IN (\(list)))")
        arguments += jids

        let rows = try Row.fetchAll(
            db,
            sql: """
                SELECT Z_PK, ZCONTACTJID, ZSESSIONTYPE FROM ZWACHATSESSION
                WHERE \(clauses.joined(separator: " OR "))
                """,
            arguments: StatementArguments(arguments)
        )

        var group: Set<Int64> = []
        var direct: Set<Int64> = []
        for row in rows {
            let pk: Int64 = row["Z_PK"]
            let contactJID: String? = row["ZCONTACTJID"]
            let type: Int64? = row["ZSESSIONTYPE"]
            if type == 1 || contactJID?.hasSuffix(Self.groupSuffix) == true {
                group.insert(pk)
            } else {
                direct.insert(pk)
            }
        }
        return (group, direct)
    }

    /// The names of the person's groups that read like an organisation ("Clinic Team"), by the
    /// same rule `MessagesCollector` applies to a group chat's display name.
    private func companies(_ db: Database, groups: Set<Int64>) throws -> [String] {
        guard !groups.isEmpty else { return [] }
        let names = try String.fetchAll(
            db,
            sql: """
                SELECT ZPARTNERNAME FROM ZWACHATSESSION
                WHERE Z_PK IN (\(Self.placeholders(groups.count)))
                  AND ZPARTNERNAME IS NOT NULL AND TRIM(ZPARTNERNAME) <> ''
                """,
            arguments: StatementArguments(groups.sorted())
        )
        return Self.union(
            names.map { $0.trimmingCharacters(in: .whitespaces) }.filter(SignalRules.looksLikeCompany),
            []
        )
    }

    /// The display names the person set for themselves, first-seen order, duplicates dropped.
    private func pushNames(_ db: Database, jids: [String]) throws -> [String] {
        let names = try String.fetchAll(
            db,
            sql: "SELECT ZPUSHNAME FROM ZWAPROFILEPUSHNAME WHERE ZJID IN (\(Self.placeholders(jids.count))) AND ZPUSHNAME IS NOT NULL",
            arguments: StatementArguments(jids)
        )
        return Self.union(names.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }, [])
    }

    /// The two blobs the text rules run over: what *other* members of the person's groups wrote
    /// (never the user, never the person — that is what makes an honorific or a nickname evidence
    /// about them), and what the person themselves wrote (the only place a shared link counts).
    ///
    /// Capped at the 500 most recent messages with text, in SQL, across the person's sessions.
    private func messageText(
        _ db: Database,
        jids: Set<String>,
        sessions: (group: Set<Int64>, direct: Set<Int64>),
        since: Date?
    ) throws -> (byOtherMembers: String, byPerson: String) {
        let ids = (sessions.group.union(sessions.direct)).sorted()
        guard !ids.isEmpty else { return ("", "") }

        var arguments: [any DatabaseValueConvertible] = ids
        var sinceClause = ""
        if let since {
            sinceClause = " AND ZMESSAGEDATE >= ?"
            arguments.append(since.timeIntervalSinceReferenceDate)
        }
        let rows = try Row.fetchAll(
            db,
            sql: """
                SELECT ZCHATSESSION, ZTEXT, ZISFROMME, ZFROMJID FROM ZWAMESSAGE
                WHERE ZCHATSESSION IN (\(Self.placeholders(ids.count))) AND ZTEXT IS NOT NULL\(sinceClause)
                ORDER BY ZMESSAGEDATE DESC LIMIT \(Self.messageCap)
                """,
            arguments: StatementArguments(arguments)
        )

        var byOtherMembers: [String] = []
        var byPerson: [String] = []
        // Chronological order, so a nickname sits next to the mention that introduced it.
        for row in rows.reversed() {
            guard let text: String = row["ZTEXT"], !text.isEmpty else { continue }
            let session: Int64 = row["ZCHATSESSION"]
            let fromJID: String? = row["ZFROMJID"]
            let isFromMe = ((row["ZISFROMME"] as Int64?) ?? 0) != 0
            let isFromPerson = fromJID.map { jids.contains($0) } ?? false

            if isFromPerson || (!isFromMe && sessions.direct.contains(session)) {
                byPerson.append(text)
            } else if sessions.group.contains(session), !isFromMe, !isFromPerson {
                byOtherMembers.append(text)
            }
        }
        return (byOtherMembers.joined(separator: "\n"), byPerson.joined(separator: "\n"))
    }

    /// `lastContact` and `interactions` over the messages that are actually *with* the person:
    /// anything they wrote, plus both directions of their one-to-one chats. Other members'
    /// chatter in a shared group is not an interaction with them.
    private func tally(
        _ db: Database,
        jids: [String],
        direct: Set<Int64>,
        since: Date?
    ) throws -> (lastContact: Date?, interactions: Int) {
        var involved = ["ZFROMJID IN (\(Self.placeholders(jids.count)))"]
        var arguments: [any DatabaseValueConvertible] = jids
        if !direct.isEmpty {
            involved.append("ZCHATSESSION IN (\(Self.placeholders(direct.count)))")
            arguments += direct.sorted()
        }
        // An incremental pass counts only what it read, so merged signals stay additive.
        let window = max(since ?? .distantPast, Date.now.addingTimeInterval(-Self.interactionWindow))
        let sinceClause = since == nil ? "" : " AND ZMESSAGEDATE >= ?"

        let row = try Row.fetchOne(
            db,
            sql: """
                SELECT MAX(ZMESSAGEDATE) AS last, SUM(CASE WHEN ZMESSAGEDATE >= ? THEN 1 ELSE 0 END) AS recent
                FROM ZWAMESSAGE WHERE (\(involved.joined(separator: " OR ")))\(sinceClause)
                """,
            arguments: StatementArguments(
                [window.timeIntervalSinceReferenceDate] + arguments
                    + (since.map { [$0.timeIntervalSinceReferenceDate] } ?? [])
            )
        )
        guard let row else { return (nil, 0) }
        // Core Data keeps its dates as seconds since 2001-01-01 — Foundation's reference date.
        let last: Double? = row["last"]
        let recent: Int? = row["recent"]
        return (last.map(Date.init(timeIntervalSinceReferenceDate:)), recent ?? 0)
    }

    // MARK: - Register sample

    /// The user's own last `limit` messages to this person, newest first, for learning how they
    /// write to them (spec §7.4). Text only, never stored, never leaves the Mac unless the
    /// caller sends it.
    ///
    /// Only the user's own side of the person's one-to-one chats: a group message is addressed
    /// to the room rather than to them, so it says nothing about the register the user writes to
    /// *this* person in. Newest first, capped in SQL, and each message cut to
    /// `MessagesCollector.sampleLength` characters — the same sample the Messages collector
    /// produces, from the other store.
    public func registerSample(for input: ProbeInput, limit: Int = 20) async throws -> [String] {
        let jids = Set(input.phonesE164.compactMap(Self.jid(forPhone:))).sorted()
        // No phone number means no WhatsApp address to look for; don't even copy the store.
        guard !jids.isEmpty, limit > 0 else { return [] }

        // Ask first, exactly as `collect` does: without Full Disk Access the store's own
        // existence is hidden, so opening it first would report a missing store where access is
        // what is missing.
        try check(status())

        if let snapshot = session.current {
            return try await readSample(from: snapshot, jids: jids, limit: limit)
        }
        let snapshot = try session.single(chatStorage)
        defer { snapshot.close() }
        return try await readSample(from: snapshot, jids: jids, limit: limit)
    }

    private func readSample(from snapshot: SourceSnapshot, jids: [String], limit: Int) async throws -> [String] {
        do {
            return try await snapshot.reader.read { db in
                try sample(db, jids: jids, limit: limit)
            }
        } catch let error as DatabaseError {
            // A store whose Core Data shape has moved on is not an access problem.
            throw SourceError.malformed(error.message ?? "unreadable ChatStorage.sqlite")
        }
    }

    private func sample(_ db: Database, jids: [String], limit: Int) throws -> [String] {
        let direct = try sessionIds(db, jids: jids).direct.sorted()
        guard !direct.isEmpty else { return [] }

        // Messages with nothing to read are dropped here rather than after the fact, so the
        // limit counts messages the drafter can actually learn from.
        var arguments: [any DatabaseValueConvertible] = direct
        arguments.append(limit)
        let texts = try String.fetchAll(
            db,
            sql: """
                SELECT ZTEXT FROM ZWAMESSAGE
                WHERE ZCHATSESSION IN (\(Self.placeholders(direct.count)))
                  AND ZISFROMME = 1 AND ZTEXT IS NOT NULL AND TRIM(ZTEXT) <> ''
                ORDER BY ZMESSAGEDATE DESC LIMIT ?
                """,
            arguments: StatementArguments(arguments)
        )
        return texts.compactMap { text in
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : String(trimmed.prefix(MessagesCollector.sampleLength))
        }
    }

    // MARK: - Test support

    #if DEBUG
    /// How many snapshots of `ChatStorage.sqlite` this collector has opened: one for a whole
    /// run bracketed by `beginSession()`/`endSession()`, otherwise one per `collect`.
    public var snapshotsOpened: Int { session.snapshotsOpened }
    #endif

    // MARK: - Helpers

    /// `?, ?, …` for an `IN` list. An empty list becomes `NULL`, which matches nothing and binds
    /// nothing, rather than a placeholder with no argument behind it.
    private static func placeholders(_ count: Int) -> String {
        count == 0 ? "NULL" : Array(repeating: "?", count: count).joined(separator: ", ")
    }

    /// `a` followed by the members of `b` it doesn't already hold, each kept once.
    private static func union(_ a: [String], _ b: [String]) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for value in a + b where seen.insert(value).inserted {
            result.append(value)
        }
        return result
    }
}
