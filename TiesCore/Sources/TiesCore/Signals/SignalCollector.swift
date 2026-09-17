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

    /// How many people are collected before their rows are written. A pass covers the whole
    /// address book, and the write per person it used to do — job `.running`, the signal row
    /// with its FTS rewrite, job `.done` — was three fsync'd transactions each, six thousand of
    /// them for two thousand people, before any research had started. Fifty is small enough
    /// that a run stopped half way through has lost at most fifty people's work, and large
    /// enough that the transactions stop being the cost of the pass.
    static let chunkSize = 50

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
    ///
    /// `nonisolated`, and each `status()` runs in its own child task: answering means stat-ing a
    /// file or listing a directory, and on a mailbox that is slow to answer — a network home
    /// directory, a disk that has spun down — doing that on the actor would hold up a collection
    /// run that is already going.
    public nonisolated func statuses() async -> [String: SourceStatus] {
        await withTaskGroup(of: (String, SourceStatus).self) { group in
            for collector in collectors {
                group.addTask { (collector.id, collector.status()) }
            }
            var result: [String: SourceStatus] = [:]
            for await (id, status) in group { result[id] = status }
            return result
        }
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

        // A chunk at a time, so the whole chunk's rows go down in one transaction each. Inside
        // a chunk the people still run `concurrency` at a time, as they always did.
        for start in stride(from: 0, to: personIds.count, by: Self.chunkSize) {
            if cancelled { break }
            let chunk = Array(personIds[start..<min(start + Self.chunkSize, personIds.count)])
            try? store.setJobs(kind: .collect, states: chunk.map { ($0, .running, nil) })

            var outcomes: [Outcome] = []
            await withTaskGroup(of: Outcome.self) { group in
                var index = 0
                var inFlight = 0

                func startNext() {
                    guard !cancelled, index < chunk.count else { return }
                    let personId = chunk[index]
                    index += 1
                    inFlight += 1
                    group.addTask {
                        await self.collectPerson(personId: personId)
                    }
                }

                while inFlight < maxInFlight, index < chunk.count, !cancelled {
                    startNext()
                }

                while let outcome = await group.next() {
                    inFlight -= 1
                    completed += 1
                    outcomes.append(outcome)
                    continuation?.yield(ScanProgress(
                        completed: completed, total: total, currentName: outcome.displayName, finished: false
                    ))
                    startNext()
                }
            }

            write(outcomes)
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

    // MARK: - One chunk

    /// What collecting for one person came to, held until the rest of the chunk is done rather
    /// than written there and then.
    private struct Outcome: Sendable {
        let personId: String
        let displayName: String
        /// `nil` when there is nothing to write — the person could not be read at all.
        let signals: LocalSignals?
        let state: Job.State
        let error: String?
    }

    /// Writes a chunk: every person's merged row (with its FTS rewrite in the same transaction)
    /// and then every person's job state. A write that throws fails the chunk's people with the
    /// reason, which is what the per-person version did one at a time.
    private func write(_ outcomes: [Outcome]) {
        guard !outcomes.isEmpty else { return }
        do {
            try store.upsertSignalsBatch(outcomes.compactMap(\.signals))
            try store.setJobs(kind: .collect, states: outcomes.map { ($0.personId, $0.state, $0.error) })
        } catch {
            try? store.setJobs(
                kind: .collect,
                states: outcomes.map { ($0.personId, .failed, "\(error)") }
            )
        }
    }

    /// Runs every collector for one person and returns the merged row for the chunk to write.
    ///
    /// The job ends `.done` once the person has been processed even when some sources failed —
    /// those are recorded in the job's error as `"<id>: <error>"` and skipped — and `.failed` only
    /// when the person cannot be read or the chunk's store write throws.
    private func collectPerson(personId: String) async -> Outcome {
        let existingPerson = try? store.person(id: personId)
        let displayName = existingPerson?.displayName ?? personId

        continuation?.yield(ScanProgress(completed: completed, total: total, currentName: displayName, finished: false))

        do {
            guard let person = existingPerson else {
                return Outcome(
                    personId: personId, displayName: displayName, signals: nil,
                    state: .failed, error: "person \(personId) not found"
                )
            }

            let channels = try store.channels(personId: personId)
            let input = ProbeInput(person: person, channels: channels)

            // The row is rebuilt from the sources rather than added to the stored one: a full
            // pass reads each source from the beginning, so merging into what a previous pass
            // wrote would count every message twice and keep a source that has since been
            // switched off contributing for ever. What Contacts knows survives the rebuild
            // because `ContactsCollector` reads it back out of its own column, and
            // `upsertSignals` leaves that column alone.
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
            return Outcome(
                personId: personId, displayName: displayName, signals: merged,
                state: .done, error: errors.isEmpty ? nil : errors.joined(separator: "; ")
            )
        } catch {
            return Outcome(
                personId: personId, displayName: displayName, signals: nil,
                state: .failed, error: "\(error)"
            )
        }
    }
}
