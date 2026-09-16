import Foundation
import GRDB

extension Store {
    /// Upserts a batch of people, matching each existing row by `cnIdentifier` when present,
    /// falling back to `id`. Each matched person keeps its existing (stable) `id`, and the
    /// channels passed alongside the batch replace that person's stored channels.
    public func upsertPeople(_ people: [Person], channels: [Channel]) throws {
        try writer.write { db in
            var resolvedIds: [String: String] = [:]  // incoming person.id -> id actually stored

            for person in people {
                var existing: Person?
                if let cnIdentifier = person.cnIdentifier {
                    existing = try Person.filter(Column("cnIdentifier") == cnIdentifier).fetchOne(db)
                }
                if existing == nil {
                    existing = try Person.fetchOne(db, key: person.id)
                }

                var toSave = person
                toSave.id = existing?.id ?? person.id
                if let existing {
                    // Preserve the original creation time across re-syncs; everything else
                    // (including updatedAt) comes from the incoming person.
                    toSave.createdAt = existing.createdAt
                }
                resolvedIds[person.id] = toSave.id
                try toSave.save(db)
            }

            let channelsByResolvedId = Dictionary(grouping: channels) { resolvedIds[$0.personId] ?? $0.personId }
            for resolvedId in Set(resolvedIds.values) {
                try Self.saveChannels(channelsByResolvedId[resolvedId] ?? [], personId: resolvedId, db: db)
                // The FTS row is built from the person's own name/organization/job title, so a
                // re-sync that renames or re-companies someone has to rewrite it here too —
                // otherwise the index keeps answering with the old text.
                try Self.rewriteFTS(db, personId: resolvedId)
            }
        }
    }

    /// Inserts a manually-added person (not sourced from Contacts) along with their channels.
    public func insertManualPerson(_ person: Person, channels: [Channel]) throws {
        try writer.write { db in
            try person.insert(db)
            try Self.saveChannels(channels, personId: person.id, db: db)
            // Without this a manually added person has no `profile_fts` row at all until they
            // are researched, so `ask` cannot see them even by name.
            try Self.rewriteFTS(db, personId: person.id)
        }
    }

    /// Updates an existing person's fields by `id`, replacing their channels.
    public func updatePerson(_ person: Person, channels: [Channel]) throws {
        try writer.write { db in
            try person.update(db)
            try Self.saveChannels(channels, personId: person.id, db: db)
            try Self.rewriteFTS(db, personId: person.id)
        }
    }

    /// Replaces the stored channels for `personId` with `channels`, remapping each channel's
    /// `personId` to the resolved id first.
    private static func saveChannels(_ channels: [Channel], personId: String, db: Database) throws {
        _ = try Channel.filter(Column("personId") == personId).deleteAll(db)
        for channel in channels {
            var toSave = channel
            toSave.personId = personId
            try toSave.insert(db)
        }
    }

    /// Deletes a person. Channels, candidates (and their evidence/pages), the profile, and the
    /// note all cascade via foreign keys; the FTS row has no foreign key, so it's removed explicitly.
    public func deletePerson(id: String) throws {
        try writer.write { db in
            _ = try Job.filter(Column("personId") == id).deleteAll(db)
            _ = try Person.deleteOne(db, key: id)
            // The person (and its FK-cascaded rows) are gone; rewriteFTS deletes the stale
            // fts row and, finding no person, stops without re-inserting one.
            try Store.rewriteFTS(db, personId: id)
        }
    }

    /// All people, sorted by display name (localized, case-insensitive).
    public func allPeople() throws -> [Person] {
        let people = try writer.read { db in try Person.fetchAll(db) }
        return people.sorted {
            $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending
        }
    }

    public func person(id: String) throws -> Person? {
        try writer.read { db in try Person.fetchOne(db, key: id) }
    }

    public func channels(personId: String) throws -> [Channel] {
        try writer.read { db in
            try Channel.filter(Column("personId") == personId).fetchAll(db)
        }
    }

    public func channelsByPerson(ids: [String]) throws -> [String: [Channel]] {
        let all = try writer.read { db in
            try Channel.filter(ids.contains(Column("personId"))).fetchAll(db)
        }
        return Dictionary(grouping: all, by: \.personId)
    }

    /// Matches people whose display name or organization contains `query` (diacritic- and
    /// case-insensitive), or, when `query` is purely digits (ignoring `+ - ( )` and whitespace),
    /// whose phone channels' normalized value contains those digits.
    public func people(matchingNameOrDigits query: String) throws -> [Person] {
        let all = try allPeople()
        let q = query.trimmingCharacters(in: .whitespaces)
        if q.isEmpty { return all }

        let digits = q.filter(\.isNumber)
        let strippedCount = q.filter { !$0.isWhitespace && $0 != "+" && $0 != "-" && $0 != "(" && $0 != ")" }.count
        let isDigits = !digits.isEmpty && digits.count == strippedCount

        if isDigits {
            let byPerson = try channelsByPerson(ids: all.map(\.id))
            return all.filter { person in
                byPerson[person.id]?.contains { $0.kind == .phone && $0.normalized.contains(digits) } ?? false
            }
        }

        return all.filter { person in
            person.displayName.range(of: q, options: [.caseInsensitive, .diacriticInsensitive]) != nil
                || (person.organization ?? "").range(of: q, options: [.caseInsensitive, .diacriticInsensitive]) != nil
        }
    }
}
