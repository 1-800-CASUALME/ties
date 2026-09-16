import Foundation
import GRDB

/// Reads iMessage and SMS history for one person out of a temporary, read-only copy of
/// `~/Library/Messages/chat.db` (spec §3): how other people address them, the names they are
/// called in group chats, links they shared themselves, when you last talked, and how often.
///
/// Nothing here writes to the Messages store, and nothing leaves the Mac. Work is capped at the
/// 500 most recent messages across the person's handles.
public struct MessagesCollector: SourceCollector {
    public let id = "messages"
    public let displayName = "your chats"

    /// The Messages store to read. Tests point this at a fixture; it is only ever copied.
    public let chatDB: URL
    /// The user's own names, so the user's name never becomes an alias for someone else.
    public let userNames: [String]

    /// The one snapshot a whole collection run shares (spec §3: a multi-gigabyte `chat.db` is
    /// copied once, not once per person).
    private let session = SnapshotSession()

    public init(
        chatDB: URL = URL(fileURLWithPath: NSHomeDirectory() + "/Library/Messages/chat.db"),
        userNames: [String]
    ) {
        self.chatDB = chatDB
        self.userNames = userNames
    }

    // MARK: - Session

    /// Copies `chat.db` once for the whole run. Reports the same errors `collect` would.
    public func beginSession() async throws {
        try check(status())
        try session.begin(chatDB)
    }

    public func endSession() async {
        session.end()
    }

    // MARK: - Status

    /// `unavailable` when there is no Messages store, `needsAccess` when there is one the app
    /// may not open (Full Disk Access), `ready` otherwise.
    ///
    /// Decided by actually opening the file, because without Full Disk Access the store doesn't
    /// merely refuse to open: `stat` is denied too, so "file not found" and "not allowed" look
    /// alike until the error itself is read.
    public func status() -> SourceStatus {
        .ofFile(at: chatDB)
    }

    // MARK: - Collection

    /// The person's signals from Messages, or empty signals when they have no handles here.
    /// `since` limits the read to messages newer than that date, for a repeat collection.
    public func collect(for input: ProbeInput, since: Date?) async throws -> LocalSignals {
        let handles = (input.phonesE164 + input.emails).map { $0.lowercased() }.filter { !$0.isEmpty }
        guard !handles.isEmpty else { return LocalSignals(personId: input.person.id) }

        // Ask first, so a store that is only hidden by a missing Full Disk Access grant is
        // reported as needing access rather than as missing.
        try check(status())

        // Inside a run the snapshot the session opened is reused; on its own, `collect` copies
        // the store for this one call and closes the copy again.
        if let snapshot = session.current {
            return try await read(input: input, handles: handles, since: since, from: snapshot)
        }
        let snapshot = try session.single(chatDB)
        defer { snapshot.close() }
        return try await read(input: input, handles: handles, since: since, from: snapshot)
    }

    private func read(
        input: ProbeInput,
        handles: [String],
        since: Date?,
        from snapshot: SourceSnapshot
    ) async throws -> LocalSignals {
        do {
            return try await snapshot.reader.read { db in
                try signals(for: input, handles: Array(Set(handles)).sorted(), since: since, in: db)
            }
        } catch let error as SourceError {
            throw error
        } catch {
            // A chat.db we can't read the way we expect is malformed, not a crash.
            throw SourceError.malformed(error.localizedDescription)
        }
    }

    /// Turns a status into the error `collect`/`beginSession` throw for it.
    private func check(_ status: SourceStatus) throws {
        switch status {
        case .ready: return
        case .needsAccess: throw SourceError.needsAccess
        case .unavailable: throw SourceError.unavailable
        case .error(let message): throw SourceError.malformed(message)
        }
    }

    private func signals(for input: ProbeInput, handles: [String], since: Date?, in db: Database) throws -> LocalSignals {
        let empty = LocalSignals(personId: input.person.id)

        let handleIds = try Int64.fetchAll(
            db,
            sql: "SELECT ROWID FROM handle WHERE LOWER(id) IN (\(Self.placeholders(handles.count)))",
            arguments: StatementArguments(handles)
        )
        guard !handleIds.isEmpty else { return empty }
        let chatIds = try Int64.fetchAll(
            db,
            sql: "SELECT DISTINCT chat_id FROM chat_handle_join WHERE handle_id IN (\(Self.placeholders(handleIds.count)))",
            arguments: StatementArguments(handleIds)
        )
        let directChatIds = try oneToOneChats(among: chatIds, in: db)

        // Everything the person said, plus everything said in the chats they are in — that is
        // where other people address them by name.
        var scope = """
            (m.handle_id IN (\(Self.placeholders(handleIds.count))) \
            OR cmj.chat_id IN (\(Self.placeholders(chatIds.count))))
            """
        var scopeArguments = StatementArguments(handleIds)
        scopeArguments += StatementArguments(chatIds)
        if let since {
            scope += " AND \(Self.secondsSince2001) >= ?"
            scopeArguments += [since.timeIntervalSinceReferenceDate]
        }

        let rows = try Row.fetchAll(
            db,
            sql: """
                SELECT m.text AS text, m.attributedBody AS attributedBody, m.handle_id AS handleId,
                       m.is_from_me AS isFromMe
                FROM message m
                LEFT JOIN chat_message_join cmj ON cmj.message_id = m.ROWID
                WHERE \(scope)
                GROUP BY m.ROWID
                ORDER BY \(Self.secondsSince2001) DESC
                LIMIT \(Self.messageCap)
                """,
            arguments: scopeArguments
        )
        #if DEBUG
        visits.record(rows.count)
        #endif
        guard !rows.isEmpty else { return empty }

        let personHandles = Set(handleIds)
        var byOthers: [String] = []
        var byPerson: [String] = []
        for row in rows {
            // The user's own messages say nothing about how the person is seen, and their links
            // are the user's own.
            let isFromMe: Bool = row["isFromMe"] ?? false
            guard !isFromMe, let text = Self.text(of: row) else { continue }
            let handleId: Int64 = row["handleId"] ?? 0
            if personHandles.contains(handleId) {
                byPerson.append(text)
            } else {
                byOthers.append(text)
            }
        }

        let names = [input.person.givenName, input.person.familyName, input.fullName]
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        let othersText = byOthers.joined(separator: "\n")
        let companies = try companies(chatIds: chatIds, in: db)
        let tally = try tally(handleIds: handleIds, directChatIds: directChatIds, since: since, in: db)

        return LocalSignals(
            personId: input.person.id,
            aliases: SignalRules.aliases(in: othersText, names: names).filter { !isUserName($0) },
            honorifics: SignalRules.honorifics(in: othersText, names: names),
            companies: companies,
            links: SignalRules.links(in: byPerson.joined(separator: "\n")),
            lastContact: tally.lastContact,
            interactions: tally.interactions,
            sources: [id]
        )
    }

    /// The chats among `chatIds` with exactly one other participant — the person's one-to-one
    /// threads. Everything else they are in is a group, where the other members' chatter is not
    /// contact with them.
    private func oneToOneChats(among chatIds: [Int64], in db: Database) throws -> [Int64] {
        guard !chatIds.isEmpty else { return [] }
        return try Int64.fetchAll(
            db,
            sql: """
                SELECT chat_id FROM chat_handle_join
                WHERE chat_id IN (\(Self.placeholders(chatIds.count)))
                GROUP BY chat_id HAVING COUNT(DISTINCT handle_id) = 1
                """,
            arguments: StatementArguments(chatIds)
        )
    }

    /// `lastContact` and `interactions` over the messages that are actually *with* the person:
    /// anything they wrote, plus both directions of their one-to-one chats (the same rule
    /// `WhatsAppCollector` counts by). A group chat's other members talking among themselves is
    /// not an interaction with the person, so a busy group no longer inflates their count.
    ///
    /// Counted in SQL rather than from the capped read, so a busy year isn't reported as 500
    /// messages, and de-duplicated by `ROWID` so a message in two chats counts once.
    private func tally(
        handleIds: [Int64],
        directChatIds: [Int64],
        since: Date?,
        in db: Database
    ) throws -> (lastContact: Date?, interactions: Int) {
        var involved = ["(m.is_from_me = 0 AND m.handle_id IN (\(Self.placeholders(handleIds.count))))"]
        var arguments: [any DatabaseValueConvertible] = handleIds
        if !directChatIds.isEmpty {
            involved.append("cmj.chat_id IN (\(Self.placeholders(directChatIds.count)))")
            arguments += directChatIds
        }
        // An incremental pass counts only what it read, so merged signals stay additive.
        let window = max(since ?? .distantPast, Date.now.addingTimeInterval(-Self.interactionWindow))
        var sinceClause = ""
        var sinceArguments: [any DatabaseValueConvertible] = []
        if let since {
            sinceClause = " AND \(Self.secondsSince2001) >= ?"
            sinceArguments = [since.timeIntervalSinceReferenceDate]
        }

        let row = try Row.fetchOne(
            db,
            sql: """
                SELECT MAX(at) AS last, SUM(recent) AS recent FROM (
                    SELECT \(Self.secondsSince2001) AS at,
                           CASE WHEN \(Self.secondsSince2001) >= ? THEN 1 ELSE 0 END AS recent
                    FROM message m
                    LEFT JOIN chat_message_join cmj ON cmj.message_id = m.ROWID
                    WHERE (\(involved.joined(separator: " OR ")))\(sinceClause)
                    GROUP BY m.ROWID
                )
                """,
            arguments: StatementArguments(
                [window.timeIntervalSinceReferenceDate] + arguments + sinceArguments
            )
        )
        guard let row, let last: Double = row["last"] else { return (nil, row?["recent"] ?? 0) }
        return (Date(timeIntervalSinceReferenceDate: last), row["recent"] ?? 0)
    }

    /// Group-chat names that read like an organisation ("Acme Inc", "شركة النور").
    private func companies(chatIds: [Int64], in db: Database) throws -> [String] {
        guard !chatIds.isEmpty else { return [] }
        let names = try String.fetchAll(
            db,
            sql: """
                SELECT display_name FROM chat
                WHERE ROWID IN (\(Self.placeholders(chatIds.count)))
                  AND display_name IS NOT NULL AND TRIM(display_name) <> ''
                """,
            arguments: StatementArguments(chatIds)
        )
        var found: [String] = []
        for name in names.map({ $0.trimmingCharacters(in: .whitespaces) })
        where SignalRules.looksLikeCompany(name) && !found.contains(name) {
            found.append(name)
        }
        return found
    }

    private func isUserName(_ candidate: String) -> Bool {
        userNames.contains { NameMatcher.similarity(personName: $0, candidateName: candidate) >= NameMatcher.gate }
    }

    // MARK: - Reading rules

    /// Spec §3: at most this many messages per person, newest first.
    static let messageCap = 500
    /// Spec §4.1: `interactions` counts the last year.
    static let interactionWindow: TimeInterval = 365 * 24 * 60 * 60
    /// Apple writes `message.date` as nanoseconds since 2001; rows older than macOS 10.13 hold
    /// plain seconds, which are always far below this.
    static let nanosecondThreshold: Int64 = 1_000_000_000_000
    /// `message.date` in seconds since the reference date, whichever unit the row uses.
    static let secondsSince2001 =
        "(CASE WHEN m.date < \(nanosecondThreshold) THEN m.date ELSE m.date / 1000000000 END)"

    #if DEBUG
    /// How many message rows this collector's last `collect(for:since:)` read — how the cap is
    /// asserted without a counting database. Per collector, not global, so tests running in
    /// parallel don't overwrite each other's count.
    public var lastVisited: Int { visits.value }

    /// How many snapshots of `chat.db` this collector has opened.
    public var snapshotsOpened: Int { session.snapshotsOpened }

    private let visits = Visits()

    private final class Visits: @unchecked Sendable {
        private let lock = NSLock()
        private var visited = 0

        var value: Int { lock.withLock { visited } }
        func record(_ count: Int) { lock.withLock { visited = count } }
    }
    #endif

    /// A message's words: `text` when Messages stored it, otherwise the typedstream payload.
    private static func text(of row: Row) -> String? {
        if let text: String = row["text"], !text.trimmingCharacters(in: .whitespaces).isEmpty { return text }
        guard let body: Data = row["attributedBody"] else { return nil }
        return TypedStream.text(from: body)
    }

    /// `?, ?, ?` for an `IN` list — `NULL` when there is nothing to match, which `IN` reads as
    /// "no rows" instead of as a syntax error.
    private static func placeholders(_ count: Int) -> String {
        count == 0 ? "NULL" : Array(repeating: "?", count: count).joined(separator: ", ")
    }
}
