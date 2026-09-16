import Foundation
import GRDB

extension Store {
    /// Replaces all candidates (and their evidence/pages, via cascade) for a person with a new set.
    public func replaceCandidates(personId: String, candidates: [Candidate], evidence: [Evidence], pages: [SourcePage]) throws {
        try writer.write { db in
            _ = try Candidate.filter(Column("personId") == personId).deleteAll(db)
            for candidate in candidates { try candidate.insert(db) }
            for item in evidence { try item.insert(db) }
            for page in pages { try page.insert(db) }
        }
    }

    public func candidates(personId: String) throws -> [Candidate] {
        try writer.read { db in
            try Candidate
                .filter(Column("personId") == personId)
                .order(Column("score").desc)
                .fetchAll(db)
        }
    }

    public func evidence(candidateId: String) throws -> [Evidence] {
        try writer.read { db in
            try Evidence.filter(Column("candidateId") == candidateId).fetchAll(db)
        }
    }

    /// A candidate's pages in a fixed order, so callers that quote only the first few — the
    /// candidate judge quotes two — always quote the same ones.
    ///
    /// The order is `kind` then `id`. Sorting on the raw kind strings happens to put the pages
    /// with real text first (`github`, `gravatar`, `page`) and the thin ones last (`serp`,
    /// `username`), which is the order worth quoting in; `id` makes it total.
    public func pages(candidateId: String) throws -> [SourcePage] {
        try writer.read { db in
            try SourcePage
                .filter(Column("candidateId") == candidateId)
                .order(Column("kind"), Column("id"))
                .fetchAll(db)
        }
    }

    /// Pages belonging to candidates of a person whose status is `.auto` or `.accepted`.
    public func pagesForAccepted(personId: String) throws -> [SourcePage] {
        try writer.read { db in
            let candidateIds = try Candidate
                .filter(Column("personId") == personId)
                .filter([Candidate.Status.auto, Candidate.Status.accepted].contains(Column("status")))
                .select(Column("id"), as: String.self)
                .fetchAll(db)
            guard !candidateIds.isEmpty else { return [] }
            return try SourcePage.filter(candidateIds.contains(Column("candidateId"))).fetchAll(db)
        }
    }

    /// Sets a candidate's status. Accepting one candidate rejects every other candidate for the
    /// same person.
    public func setCandidateStatus(id: String, status: Candidate.Status) throws {
        try writer.write { db in
            guard var candidate = try Candidate.fetchOne(db, key: id) else { return }
            candidate.status = status
            try candidate.update(db)

            if status == .accepted {
                try db.execute(
                    sql: "UPDATE candidate SET status = ? WHERE personId = ? AND id != ?",
                    arguments: [Candidate.Status.rejected, candidate.personId, id]
                )
            }
        }
    }

    /// The best candidate for a person: the accepted one if any, else the best-scoring `.auto`
    /// one, else the highest-scoring `.pending` one.
    public func bestCandidate(personId: String) throws -> Candidate? {
        try writer.read { db in try Self.bestCandidate(for: personId, db) }
    }

    public func bestCandidatesByPerson() throws -> [String: Candidate] {
        try writer.read { db in
            let personIds = try String.fetchAll(db, sql: "SELECT DISTINCT personId FROM candidate")
            var result: [String: Candidate] = [:]
            for personId in personIds {
                if let best = try Self.bestCandidate(for: personId, db) {
                    result[personId] = best
                }
            }
            return result
        }
    }

    private static func bestCandidate(for personId: String, _ db: Database) throws -> Candidate? {
        if let accepted = try Candidate
            .filter(Column("personId") == personId)
            .filter(Column("status") == Candidate.Status.accepted)
            .fetchOne(db) {
            return accepted
        }
        if let auto = try Candidate
            .filter(Column("personId") == personId)
            .filter(Column("status") == Candidate.Status.auto)
            .order(Column("score").desc)
            .fetchOne(db) {
            return auto
        }
        return try Candidate
            .filter(Column("personId") == personId)
            .filter(Column("status") == Candidate.Status.pending)
            .order(Column("score").desc)
            .fetchOne(db)
    }
}
