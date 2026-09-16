import Foundation
import GRDB

extension Store {
    /// Replaces the whole set of smart lists in one transaction. Regrouping produces a fresh
    /// set every time, so there is no per-list update: the old lists go, the new ones land.
    public func replaceSmartLists(_ lists: [SmartList]) throws {
        try writer.write { db in
            _ = try SmartListRow.deleteAll(db)
            for list in lists {
                try SmartListRow(list).insert(db)
            }
        }
    }

    /// Every smart list, oldest first, so the sidebar order is stable across reads.
    public func smartLists() throws -> [SmartList] {
        let rows = try writer.read { db in
            try SmartListRow.order(Column("createdAt"), Column("id")).fetchAll(db)
        }
        return try rows.map { try $0.asSmartList() }
    }
}
