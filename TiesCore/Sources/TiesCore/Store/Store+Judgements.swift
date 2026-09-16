import Foundation
import GRDB

extension Store {
    /// Records a provider's verdict for a person, replacing any previous one — `personId` is the
    /// primary key, so only the latest judgement survives.
    public func upsertJudgement(_ j: Judgement) throws {
        try writer.write { db in try j.save(db) }
    }

    public func judgement(personId: String) throws -> Judgement? {
        try writer.read { db in try Judgement.fetchOne(db, key: personId) }
    }

    public func judgementsByPerson() throws -> [String: Judgement] {
        let all = try writer.read { db in try Judgement.fetchAll(db) }
        return Dictionary(all.map { ($0.personId, $0) }, uniquingKeysWith: { _, latest in latest })
    }
}
