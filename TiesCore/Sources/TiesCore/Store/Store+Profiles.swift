import Foundation
import GRDB

extension Store {
    /// Upserts a profile and rewrites its `profile_fts` row in the same transaction.
    public func upsertProfile(_ profile: Profile) throws {
        try writer.write { db in
            let row = try ProfileRow(profile)
            try row.save(db)
            try Self.rewriteFTS(db, personId: profile.personId)
        }
    }

    public func profile(personId: String) throws -> Profile? {
        let row = try writer.read { db in try ProfileRow.fetchOne(db, key: personId) }
        return try row?.asProfile()
    }

    public func profilesByPerson() throws -> [String: Profile] {
        let rows = try writer.read { db in try ProfileRow.fetchAll(db) }
        var result: [String: Profile] = [:]
        for row in rows {
            result[row.personId] = try row.asProfile()
        }
        return result
    }

    /// Upserts a note and rewrites its `profile_fts` row in the same transaction.
    public func upsertNote(_ note: Note) throws {
        try writer.write { db in
            try note.save(db)
            try Self.rewriteFTS(db, personId: note.personId)
        }
    }

    public func note(personId: String) throws -> Note? {
        try writer.read { db in try Note.fetchOne(db, key: personId) }
    }

    /// Full-text search over profile/note content, using an all-prefixes FTS5 pattern.
    /// Returns an empty array when no usable pattern can be built from `query`.
    public func ftsSearch(_ query: String, limit: Int = 50) throws -> [(personId: String, rank: Double)] {
        guard let pattern = FTS5Pattern(matchingAllPrefixesIn: query) else { return [] }
        return try writer.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: """
                SELECT personId, bm25(profile_fts) AS rank FROM profile_fts
                WHERE profile_fts MATCH ? ORDER BY rank LIMIT ?
                """,
                arguments: [pattern, limit]
            )
            return rows.map { (personId: $0["personId"] as String, rank: $0["rank"] as Double) }
        }
    }

    public func allEmbeddings() throws -> [(personId: String, vector: [Float])] {
        let rows = try writer.read { db in try ProfileRow.fetchAll(db) }
        return rows.compactMap { row in
            guard let data = row.embedding else { return nil }
            return (personId: row.personId, vector: ProfileRow.decodeEmbedding(data))
        }
    }

    /// Rebuilds the `profile_fts` row for a person from their display name, organization,
    /// job title, profile facts, note, and collected aliases and titles. Must run inside the
    /// same write transaction as the profile/note/signal upsert that triggered it.
    static func rewriteFTS(_ db: Database, personId: String) throws {
        try db.execute(sql: "DELETE FROM profile_fts WHERE personId = ?", arguments: [personId])

        guard let person = try Person.fetchOne(db, key: personId) else { return }

        var parts: [String] = [person.displayName]
        if let organization = person.organization { parts.append(organization) }
        if let jobTitle = person.jobTitle { parts.append(jobTitle) }
        if let profileRow = try ProfileRow.fetchOne(db, key: personId) {
            let facts = try JSONDecoder().decode(ProfileFacts.self, from: Data(profileRow.facts.utf8))
            parts.append(facts.searchableText)
        }
        if let note = try Note.fetchOne(db, key: personId) {
            parts.append(note.body)
        }
        // Locally collected names and titles are often the only searchable text a person has —
        // someone with no profile is still findable by the alias their friends use. Not every
        // person has a signal row, and rewriteFTS runs on people who never will, so a missing
        // row is normal rather than an error.
        if let signalRow = try SignalRow.fetchOne(db, key: personId) {
            let signals = try signalRow.asSignals()
            parts += signals.aliases
            parts += signals.titles
            // The address book's contribution sits in its own column until a collection pass
            // folds it into the merged ones, and a nickname is exactly what someone searches by.
            if let contacts = try signalRow.contacts() {
                parts += contacts.aliases
            }
        }

        let content = parts.joined(separator: "\n")
        try db.execute(
            sql: "INSERT INTO profile_fts (personId, content) VALUES (?, ?)",
            arguments: [personId, content]
        )
    }
}
