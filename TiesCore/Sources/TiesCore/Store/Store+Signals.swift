import Foundation
import GRDB

extension Store {
    /// Upserts a person's locally collected signals and rewrites their `profile_fts` row in the
    /// same transaction, so the aliases and titles just collected are searchable immediately.
    public func upsertSignals(_ s: LocalSignals) throws {
        try writer.write { db in
            try SignalRow(s).save(db)
            try Self.rewriteFTS(db, personId: s.personId)
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
}
