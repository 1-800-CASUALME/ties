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

    public init(
        chatDB: URL = URL(fileURLWithPath: NSHomeDirectory() + "/Library/Messages/chat.db"),
        userNames: [String]
    ) {
        self.chatDB = chatDB
        self.userNames = userNames
    }

    // MARK: - Status

    /// `unavailable` when there is no Messages store, `needsAccess` when there is one the app
    /// may not open (Full Disk Access), `ready` otherwise.
    ///
    /// Decided by actually opening the file, because without Full Disk Access the store doesn't
    /// merely refuse to open: `stat` is denied too, so "file not found" and "not allowed" look
    /// alike until the error itself is read.
    public func status() -> SourceStatus {
        do {
            let handle = try FileHandle(forReadingFrom: chatDB)
            try? handle.close()
            return .ready
        } catch {
            if SourceSnapshot.isPermissionError(error) { return .needsAccess }
            return FileManager.default.fileExists(atPath: chatDB.path) ? .needsAccess : .unavailable
        }
    }

    // MARK: - Collection

    /// The person's signals from Messages, or empty signals when they have no handles here.
    /// `since` limits the read to messages newer than that date, for a repeat collection.
    public func collect(for input: ProbeInput, since: Date?) async throws -> LocalSignals {
        let handles = (input.phonesE164 + input.emails).map { $0.lowercased() }.filter { !$0.isEmpty }
        guard !handles.isEmpty else { return LocalSignals(personId: input.person.id) }

        // Ask first, so a store that is only hidden by a missing Full Disk Access grant is
        // reported as needing access rather than as missing.
        switch status() {
        case .ready: break
        case .needsAccess: throw SourceError.needsAccess
        case .unavailable: throw SourceError.unavailable
        case .error(let message): throw SourceError.malformed(message)
        }

        let snapshot = try SourceSnapshot.open(chatDB)
        defer { snapshot.close() }
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
                       m.is_from_me AS isFromMe, m.date AS date
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
        Self.lastVisited = rows.count
        #endif
        guard !rows.isEmpty else { return empty }

        let personHandles = Set(handleIds)
        var byOthers: [String] = []
        var byPerson: [String] = []
        var dates: [Date] = []
        for row in rows {
            let raw: Int64 = row["date"] ?? 0
            if let date = Self.date(fromAppleTime: raw) { dates.append(date) }
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
        let interactions = try interactions(scope: scope, arguments: scopeArguments, in: db)

        return LocalSignals(
            personId: input.person.id,
            aliases: SignalRules.aliases(in: othersText, names: names).filter { !isUserName($0) },
            honorifics: SignalRules.honorifics(in: othersText, names: names),
            companies: companies,
            links: SignalRules.links(in: byPerson.joined(separator: "\n")),
            lastContact: dates.max(),
            interactions: interactions,
            sources: [id]
        )
    }

    /// Messages in either direction in the last 365 days. Counted in SQL rather than from the
    /// capped read, so a busy year isn't reported as 500 messages.
    private func interactions(scope: String, arguments: StatementArguments, in db: Database) throws -> Int {
        var arguments = arguments
        arguments += [Date.now.addingTimeInterval(-Self.interactionWindow).timeIntervalSinceReferenceDate]
        return try Int.fetchOne(
            db,
            sql: """
                SELECT COUNT(*) FROM (
                    SELECT m.ROWID
                    FROM message m
                    LEFT JOIN chat_message_join cmj ON cmj.message_id = m.ROWID
                    WHERE \(scope) AND \(Self.secondsSince2001) >= ?
                    GROUP BY m.ROWID
                )
                """,
            arguments: arguments
        ) ?? 0
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
        where Self.looksLikeCompany(name) && !found.contains(name) {
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

    /// Group names holding one of these tokens name an organisation rather than a group of
    /// friends.
    private static let companyTokens: Set<String> = ["inc", "llc", "ltd", "team", "co", "شركة"]

    #if DEBUG
    /// How many message rows the last collection read — the cap, proved.
    nonisolated(unsafe) static var lastVisited = 0
    #endif

    /// A message's words: `text` when Messages stored it, otherwise the typedstream payload.
    private static func text(of row: Row) -> String? {
        if let text: String = row["text"], !text.trimmingCharacters(in: .whitespaces).isEmpty { return text }
        guard let body: Data = row["attributedBody"] else { return nil }
        return TypedStream.text(from: body)
    }

    static func date(fromAppleTime raw: Int64) -> Date? {
        guard raw > 0 else { return nil }
        let seconds = raw < nanosecondThreshold ? Double(raw) : Double(raw) / 1_000_000_000
        return Date(timeIntervalSinceReferenceDate: seconds)
    }

    static func looksLikeCompany(_ name: String) -> Bool {
        name.split(whereSeparator: { $0.isWhitespace || $0 == "," })
            .map { $0.trimmingCharacters(in: .punctuationCharacters).lowercased() }
            .contains { companyTokens.contains($0) }
    }

    /// `?, ?, ?` for an `IN` list — `NULL` when there is nothing to match, which `IN` reads as
    /// "no rows" instead of as a syntax error.
    private static func placeholders(_ count: Int) -> String {
        count == 0 ? "NULL" : Array(repeating: "?", count: count).joined(separator: ", ")
    }
}
