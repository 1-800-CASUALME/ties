import Foundation
import GRDB

extension Store {
    /// Upserts a person's locally collected signals and rewrites their `profile_fts` row in the
    /// same transaction, so the aliases and titles just collected are searchable immediately.
    ///
    /// The address book's own contribution is *not* part of what this writes: a collection pass
    /// rebuilds the merged columns from nothing, and `contactsSignals` is carried across
    /// untouched so that rebuild neither drops what Contacts knows nor has to re-derive it.
    public func upsertSignals(_ s: LocalSignals) throws {
        try upsertSignalsBatch([s])
    }

    /// The same for a chunk of a collection pass, in one transaction. A pass covers the whole
    /// address book, and a write plus an FTS rewrite each would be thousands of fsync'd
    /// transactions on the front of the wizard's slowest screen.
    public func upsertSignalsBatch(_ batch: [LocalSignals]) throws {
        guard !batch.isEmpty else { return }
        try writer.write { db in
            for signals in batch {
                let contacts = try SignalRow.fetchOne(db, key: signals.personId)?.contactsSignals
                try SignalRow(signals, contactsSignals: contacts).save(db)
                try Self.rewriteFTS(db, personId: signals.personId)
            }
        }
    }

    public func signals(personId: String) throws -> LocalSignals? {
        let row = try writer.read { db in try SignalRow.fetchOne(db, key: personId) }
        return try row?.asSignals()
    }

    public func signalsByPerson() throws -> [String: LocalSignals] {
        let rows = try writer.read { db in try SignalRow.fetchAll(db) }
        var result: [String: LocalSignals] = [:]
        for row in rows {
            result[row.personId] = try row.asSignals()
        }
        return result
    }

    // MARK: - The Contacts contribution

    /// What the address book alone says about this person, as `ContactSync` last wrote it.
    public func contactsSignals(personId: String) throws -> LocalSignals? {
        let row = try writer.read { db in try SignalRow.fetchOne(db, key: personId) }
        return try row?.contacts()
    }

    /// Writes only the address book's contribution for one person, leaving every merged column
    /// as the last collection pass left it.
    public func upsertContactsSignals(personId: String, _ signals: LocalSignals) throws {
        try upsertContactsSignalsBatch([(personId: personId, signals: signals)])
    }

    /// The same for a whole import, in one transaction: a contact sync touches every person in
    /// the address book, and a write plus an FTS rewrite each would be thousands of them.
    public func upsertContactsSignalsBatch(_ rows: [(personId: String, signals: LocalSignals)]) throws {
        guard !rows.isEmpty else { return }
        try writer.write { db in
            for (personId, signals) in rows {
                let encoded = String(decoding: try JSONEncoder().encode(signals), as: UTF8.self)
                if var existing = try SignalRow.fetchOne(db, key: personId) {
                    existing.contactsSignals = encoded
                    try existing.update(db)
                } else {
                    // No collection pass has run for this person yet; the merged columns stay
                    // empty until one does, and the contribution waits here for it.
                    var fresh = try SignalRow(LocalSignals(personId: personId), contactsSignals: encoded)
                    fresh.collectedAt = signals.collectedAt
                    try fresh.insert(db)
                }
                try Self.rewriteFTS(db, personId: personId)
            }
        }
    }
}
