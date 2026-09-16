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

    /// At or above this `NameMatcher.similarity`, a push name is the Contacts name again rather
    /// than another name the person goes by.
    static let pushNameGate = 0.9

    /// WhatsApp's own suffix for a one-to-one address, and for a group's.
    static let userSuffix = "@s.whatsapp.net"
    static let groupSuffix = "@g.us"

    public let chatStorage: URL

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
        let fm = FileManager.default
        guard fm.fileExists(atPath: chatStorage.path) else { return .unavailable }
        guard fm.isReadableFile(atPath: chatStorage.path) else { return .needsAccess }
        return .ready
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

        switch status() {
        case .unavailable: throw SourceError.unavailable
        case .needsAccess: throw SourceError.needsAccess
        case .error(let message): throw SourceError.malformed(message)
        case .ready: break
        }

        let snapshot = try SourceSnapshot.open(chatStorage)
        defer { snapshot.close() }

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
            pushNames.filter { NameMatcher.similarity(personName: input.fullName, candidateName: $0) < Self.pushNameGate },
            SignalRules.aliases(in: text.byOtherMembers, names: names)
        )
        signals.links = SignalRules.links(in: text.byPerson)

        let tally = try tally(db, jids: jids, direct: sessions.direct, since: since)
        signals.lastContact = tally.lastContact
        signals.interactions = tally.interactions
        return signals
    }

    /// The person's chat sessions, split into the groups they are a member of and the one-to-one
    /// chats addressed to them. A session is a group when Core Data says so (`ZSESSIONTYPE == 1`)
    /// or when its address is a group address.
    private func sessionIds(_ db: Database, jids: [String]) throws -> (group: Set<Int64>, direct: Set<Int64>) {
        let list = Self.placeholders(jids.count)
        let rows = try Row.fetchAll(
            db,
            sql: """
                SELECT Z_PK, ZCONTACTJID, ZSESSIONTYPE FROM ZWACHATSESSION
                WHERE ZCONTACTJID IN (\(list))
                   OR Z_PK IN (SELECT ZCHATSESSION FROM ZWAGROUPMEMBER WHERE ZMEMBERJID IN (\(list)))
                """,
            arguments: StatementArguments(jids + jids)
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
