import Foundation
import GRDB

/// The GRDB-backed persistence layer for Ties: people, channels, research
/// candidates, profiles, notes, and background jobs.
public final class Store: Sendable {
    public let writer: any DatabaseWriter

    init(writer: any DatabaseWriter) {
        self.writer = writer
    }

    /// Opens (creating if needed) a SQLite database file at `url`, running migrations.
    public static func open(at url: URL) throws -> Store {
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let pool = try DatabasePool(path: url.path)
        try Migrations.migrator.migrate(pool)
        return Store(writer: pool)
    }

    /// An in-memory database, primarily for tests.
    public static func inMemory() throws -> Store {
        let queue = try DatabaseQueue()
        try Migrations.migrator.migrate(queue)
        return Store(writer: queue)
    }

    public static var defaultURL: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return appSupport.appendingPathComponent("Ties", isDirectory: true).appendingPathComponent("ties.sqlite")
    }

    /// Drops all rows from every table, but leaves the database file (and schema) in place.
    public func deleteEverything() throws {
        try writer.write { db in
            _ = try Job.deleteAll(db)
            try db.execute(sql: "DELETE FROM profile_fts")
            _ = try Person.deleteAll(db)
        }
    }

    public func databaseSizeBytes() -> Int64 {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: writer.path),
              let size = attrs[.size] as? Int64
        else { return 0 }
        return size
    }

    struct ExportEntry: Codable {
        var person: Person
        var channels: [Channel]
        var profile: ProfileFacts?
        var note: String?
    }

    /// Exports every person (with channels, profile facts, and note) as pretty-printed, sorted-key JSON.
    public func exportJSON() throws -> Data {
        let entries: [ExportEntry] = try writer.read { db in
            let people = try Person.order(Column("displayName")).fetchAll(db)
            return try people.map { person in
                let channels = try Channel
                    .filter(Column("personId") == person.id)
                    .fetchAll(db)
                let profileRow = try ProfileRow.fetchOne(db, key: person.id)
                let note = try Note.fetchOne(db, key: person.id)
                return ExportEntry(
                    person: person,
                    channels: channels,
                    profile: try profileRow?.asProfile().facts,
                    note: note?.body
                )
            }
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(entries)
    }
}
