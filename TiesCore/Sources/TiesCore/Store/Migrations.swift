import Foundation
import GRDB

enum Migrations {
    static var migrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()

        migrator.registerMigration("v1") { db in
            try db.create(table: "person") { t in
                t.primaryKey("id", .text)
                t.column("cnIdentifier", .text).unique()
                t.column("givenName", .text).notNull()
                t.column("familyName", .text).notNull()
                t.column("displayName", .text).notNull()
                t.column("organization", .text)
                t.column("jobTitle", .text)
                t.column("thumbnail", .blob)
                t.column("source", .text).notNull()
                t.column("createdAt", .datetime).notNull()
                t.column("updatedAt", .datetime).notNull()
            }
            try db.create(table: "channel") { t in
                t.autoIncrementedPrimaryKey("rowid")
                t.belongsTo("person", onDelete: .cascade).notNull()
                t.column("kind", .text).notNull()
                t.column("label", .text)
                t.column("value", .text).notNull()
                t.column("normalized", .text).notNull()
            }
            try db.create(table: "candidate") { t in
                t.primaryKey("id", .text)
                t.belongsTo("person", onDelete: .cascade).notNull()
                t.column("score", .double).notNull()
                t.column("status", .text).notNull()
                t.column("displayName", .text)
                t.column("headline", .text)
                t.column("company", .text)
                t.column("location", .text)
                t.column("avatarURL", .text)
                t.column("primaryURL", .text).notNull()
            }
            try db.create(table: "evidence") { t in
                t.primaryKey("id", .text)
                t.belongsTo("candidate", onDelete: .cascade).notNull()
                t.column("kind", .text).notNull()
                t.column("weight", .double).notNull()
                t.column("detail", .text).notNull()
                t.column("sourceURL", .text)
            }
            try db.create(table: "sourcePage") { t in
                t.primaryKey("id", .text)
                t.belongsTo("candidate", onDelete: .cascade).notNull()
                t.column("url", .text).notNull()
                t.column("title", .text)
                t.column("snippet", .text)
                t.column("bodyText", .text)
                t.column("fetchedAt", .datetime).notNull()
                t.column("kind", .text).notNull()
            }
            try db.create(table: "profile") { t in
                t.primaryKey("personId", .text).references("person", onDelete: .cascade)
                t.column("facts", .text).notNull()
                t.column("confidence", .double).notNull()
                t.column("providerId", .text).notNull()
                t.column("model", .text)
                t.column("extractedAt", .datetime).notNull()
                t.column("embedding", .blob)
            }
            try db.create(table: "note") { t in
                t.primaryKey("personId", .text).references("person", onDelete: .cascade)
                t.column("body", .text).notNull()
                t.column("updatedAt", .datetime).notNull()
            }
            try db.create(virtualTable: "profile_fts", using: FTS5()) { t in
                t.tokenizer = .unicode61(diacritics: .remove)
                t.column("personId").notIndexed()
                t.column("content")
            }
            try db.create(table: "job") { t in
                t.primaryKey("id", .text)
                t.column("kind", .text).notNull()
                t.column("personId", .text).notNull()
                t.column("state", .text).notNull()
                t.column("error", .text)
                t.column("updatedAt", .datetime).notNull()
                t.uniqueKey(["kind", "personId"])
            }
        }

        migrator.registerMigration("v2") { db in
            try db.create(table: "signal") { t in
                t.primaryKey("personId", .text).references("person", onDelete: .cascade)
                for c in ["aliases", "honorifics", "titles", "companies", "links", "phones", "emails", "sources"] {
                    t.column(c, .text).notNull().defaults(to: "[]")
                }
                t.column("location", .text)
                t.column("lastContact", .datetime)
                t.column("interactions", .integer).notNull().defaults(to: 0)
                t.column("collectedAt", .datetime).notNull()
                // The address book's own contribution, as a JSON `LocalSignals`, kept apart from
                // the merged columns. `ContactSync` writes it when contacts are imported and
                // `ContactsCollector` reads it back, so a collection pass can rebuild the merged
                // columns from nothing without either losing what Contacts knows or re-injecting
                // the previous pass's chat and mail values forever.
                t.column("contactsSignals", .text)
            }
            try db.create(table: "smartList") { t in
                t.primaryKey("id", .text)
                t.column("name", .text).notNull()
                t.column("systemImage", .text).notNull()
                t.column("personIds", .text).notNull()
                t.column("createdAt", .datetime).notNull()
            }
            try db.create(table: "judgement") { t in
                t.primaryKey("personId", .text).references("person", onDelete: .cascade)
                t.column("candidateId", .text).notNull()
                t.column("confidence", .double).notNull()
                t.column("reason", .text).notNull()
                t.column("providerId", .text).notNull()
                t.column("judgedAt", .datetime).notNull()
            }
        }

        return migrator
    }
}
