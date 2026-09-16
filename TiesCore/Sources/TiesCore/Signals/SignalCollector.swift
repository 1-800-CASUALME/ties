import Foundation

/// Runs every enabled source collector over a batch of people and stores what they find: one
/// `LocalSignals` row per person, merged across the sources, streamed as `ScanProgress` the way
/// `Scanner` streams a research run (spec §3, §6).
///
/// The run brackets itself with each collector's `beginSession()`/`endSession()`, so a collector
/// backed by a large store copies it once for the whole batch rather than once per person. Only
/// one run can be active at a time; a `run(personIds:)` call while another is still in progress is
/// rejected with an immediate, single-event stream rather than disturbing the active run.
public actor SignalCollector {
    /// The `waitingFor` text of the one event a rejected second run yields.
    public static let busyNotice = "Another collection is running"

    private let store: Store
    private let collectors: [any SourceCollector]
    private let concurrency: Int

    private var cancelled = false
    private var continuation: AsyncStream<ScanProgress>.Continuation?
    /// The `Task` running the active `execute(personIds:)`, kept so a run in progress is visible
    /// beyond just the continuation.
    private var runTask: Task<Void, Never>?
    private var completed = 0
    private var total = 0

    public init(store: Store, collectors: [any SourceCollector], concurrency: Int = 3) {
        self.store = store
        self.collectors = collectors
        self.concurrency = concurrency
    }

    /// Starts collecting for `personIds` and returns immediately with a stream of progress events.
    /// The work runs in a `Task` owned by the actor, so the stream keeps delivering even if the
    /// caller doesn't stay suspended on this call. The final event always has `finished == true`.
    ///
    /// If a collection is already running, this call doesn't touch it: it returns a separate
    /// stream whose only event is `ScanProgress(completed: 0, total: 0, waitingFor: busyNotice,
    /// finished: true)`.
    public func run(personIds: [String]) -> AsyncStream<ScanProgress> {
        guard continuation == nil else {
            let (busyStream, busyContinuation) = AsyncStream<ScanProgress>.makeStream(of: ScanProgress.self)
            busyContinuation.yield(ScanProgress(completed: 0, total: 0, waitingFor: Self.busyNotice, finished: true))
            busyContinuation.finish()
            return busyStream
        }

        let (stream, continuation) = AsyncStream<ScanProgress>.makeStream(of: ScanProgress.self)
        self.continuation = continuation
        self.completed = 0
        self.total = personIds.count
        self.cancelled = false

        runTask = Task {
            await self.execute(personIds: personIds)
        }

        return stream
    }

    /// Stops scheduling any further people. People already in flight finish normally — a
    /// collector reads a capped slice of one local store, which takes no appreciable time — and
    /// the stream ends with its final `finished == true` event once nothing is left.
    public func cancel() {
        cancelled = true
    }

    /// Where each source stands right now, by collector id, for the Sources step and the Settings
    /// pane to show.
    public func statuses() -> [String: SourceStatus] {
        var result: [String: SourceStatus] = [:]
        for collector in collectors {
            result[collector.id] = collector.status()
        }
        return result
    }

    private func execute(personIds: [String]) async {
        do {
            try store.enqueue(kind: .collect, personIds: personIds)
        } catch {
            continuation?.yield(ScanProgress(completed: completed, total: total, waitingFor: "\(error)", finished: true))
            finishStream()
            return
        }

        // One session per source for the whole batch. A session that won't open is not fatal:
        // `collect` asks each collector's `status()` for itself and reports the same failure
        // against every person, which is where the user can see it.
        for collector in collectors {
            try? await collector.beginSession()
        }

        let maxInFlight = max(1, concurrency)

        await withTaskGroup(of: String.self) { group in
            var index = 0
            var inFlight = 0

            func startNext() {
                guard !cancelled, index < personIds.count else { return }
                let personId = personIds[index]
                index += 1
                inFlight += 1
                group.addTask {
                    await self.collectPerson(personId: personId)
                }
            }

            while inFlight < maxInFlight, index < personIds.count, !cancelled {
                startNext()
            }

            while let finishedName = await group.next() {
                inFlight -= 1
                completed += 1
                continuation?.yield(ScanProgress(
                    completed: completed, total: total, currentName: finishedName, finished: false
                ))
                startNext()
            }
        }

        for collector in collectors {
            await collector.endSession()
        }

        continuation?.yield(ScanProgress(completed: completed, total: total, finished: true))
        finishStream()
    }

    private func finishStream() {
        continuation?.finish()
        continuation = nil
        runTask = nil
    }

    /// Runs every collector for one person and upserts the merged row. Returns the person's
    /// display name, for progress reporting.
    ///
    /// The job ends `.done` once the person has been processed even when some sources failed —
    /// those are recorded in the job's error as `"<id>: <error>"` and skipped — and `.failed` only
    /// when the person cannot be read or the store write throws.
    private func collectPerson(personId: String) async -> String {
        let existingPerson = try? store.person(id: personId)
        let displayName = existingPerson?.displayName ?? personId

        continuation?.yield(ScanProgress(completed: completed, total: total, currentName: displayName, finished: false))

        do {
            try store.setJob(kind: .collect, personId: personId, state: .running)

            guard let person = existingPerson else {
                try? store.setJob(kind: .collect, personId: personId, state: .failed, error: "person \(personId) not found")
                return displayName
            }

            let channels = try store.channels(personId: personId)
            let input = ProbeInput(person: person, channels: channels)

            // The row is rebuilt from the sources rather than added to the stored one: a full
            // pass reads each source from the beginning, so merging into what a previous pass
            // wrote would count every message twice.
            var merged = LocalSignals(personId: personId)
            var errors: [String] = []
            var finishedStages: [String] = []

            for collector in collectors {
                continuation?.yield(ScanProgress(
                    completed: completed, total: total, currentName: displayName, finished: false,
                    stage: collector.displayName, finishedStages: finishedStages
                ))
                do {
                    let signals = try await collector.collect(for: input, since: nil)
                    merged = merged.merged(with: signals)
                    finishedStages.append(collector.displayName)
                } catch {
                    errors.append("\(collector.id): \(error)")
                }
            }

            merged.personId = personId
            merged.collectedAt = .now
            try store.upsertSignals(merged)
            try store.setJob(
                kind: .collect, personId: personId, state: .done,
                error: errors.isEmpty ? nil : errors.joined(separator: "; ")
            )
        } catch {
            try? store.setJob(kind: .collect, personId: personId, state: .failed, error: "\(error)")
        }

        return displayName
    }
}
