import Foundation
import GRDB

extension Store {
    /// Enqueues one queued job per person, replacing any existing job of that kind for that person.
    public func enqueue(kind: Job.Kind, personIds: [String]) throws {
        try writer.write { db in
            for personId in personIds {
                // Any existing job of this kind for this person conflicts on the
                // (kind, personId) unique index; upsert overwrites it in place,
                // keeping the existing row's id.
                let job = Job(kind: kind, personId: personId, state: .queued)
                try job.upsert(db)
            }
        }
    }

    public func setJob(kind: Job.Kind, personId: String, state: Job.State, error: String? = nil) throws {
        try writer.write { db in
            guard var job = try Job
                .filter(Column("kind") == kind)
                .filter(Column("personId") == personId)
                .fetchOne(db)
            else { return }
            job.state = state
            job.error = error
            job.updatedAt = .now
            try job.update(db)
        }
    }

    public func jobs(kind: Job.Kind) throws -> [Job] {
        try writer.read { db in
            try Job.filter(Column("kind") == kind).fetchAll(db)
        }
    }

    public func counts(kind: Job.Kind) throws -> [Job.State: Int] {
        try writer.read { db in
            let jobs = try Job.filter(Column("kind") == kind).fetchAll(db)
            return Dictionary(grouping: jobs, by: \.state).mapValues(\.count)
        }
    }
}
