import Foundation

/// Orchestrates AI extraction across a batch of people: for each, gathers the accepted
/// candidate's pages, runs the chosen `AIProvider` to pull out `ProfileFacts`, embeds the
/// result, and writes a `Profile` to the `Store`. Streams `ScanProgress` as the run proceeds.
///
/// Mirrors `Scanner`'s `AsyncStream`/continuation/cancellation pattern exactly: only one run
/// can be active at a time, and a `run(personIds:)` call while another is still in progress is
/// rejected with an immediate, single-event stream rather than disturbing the active run.
/// Cancelling stops starting new people; people already in flight finish normally.
public actor Extractor {
    private let store: Store
    private let provider: any AIProvider
    private let embedder: any Embedder
    private let concurrency: Int

    private var cancelled = false
    private var continuation: AsyncStream<ScanProgress>.Continuation?
    /// The `Task` running the active `execute(personIds:)`. Kept so a run in progress is
    /// visible/trackable beyond just the continuation; `run(personIds:)` is rejected while this
    /// (or `continuation`) is non-nil.
    private var runTask: Task<Void, Never>?
    private var completed = 0
    private var total = 0

    public init(store: Store, provider: any AIProvider, embedder: any Embedder, concurrency: Int = 2) {
        self.store = store
        self.provider = provider
        self.embedder = embedder
        self.concurrency = concurrency
    }

    /// Starts extracting `personIds` and returns immediately with a stream of progress events.
    /// The actual work runs in a `Task` owned by the actor, so the stream keeps delivering
    /// events even if the caller doesn't stay suspended on this call. The stream's final event
    /// always has `finished == true`.
    ///
    /// If a run is already active, this call doesn't touch it: it returns a separate stream
    /// whose only event is `ScanProgress(completed: 0, total: 0, waitingFor: "Another
    /// extraction is running", finished: true)`.
    public func run(personIds: [String]) -> AsyncStream<ScanProgress> {
        guard continuation == nil else {
            let (busyStream, busyContinuation) = AsyncStream<ScanProgress>.makeStream(of: ScanProgress.self)
            busyContinuation.yield(ScanProgress(completed: 0, total: 0, currentName: nil, waitingFor: "Another extraction is running", finished: true))
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

    /// Stops scheduling any further people once already-in-flight ones finish; the stream ends
    /// (with a final `finished == true` event) once nothing is left in flight.
    public func cancel() {
        cancelled = true
    }

    private func execute(personIds: [String]) async {
        do {
            try store.enqueue(kind: .extract, personIds: personIds)
        } catch {
            continuation?.yield(ScanProgress(completed: completed, total: total, waitingFor: "\(error)", finished: true))
            finishStream()
            return
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
                    await self.extractPerson(personId: personId)
                }
            }

            while inFlight < maxInFlight, index < personIds.count {
                if cancelled { break }
                startNext()
            }

            while let finishedName = await group.next() {
                inFlight -= 1
                completed += 1
                continuation?.yield(ScanProgress(completed: completed, total: total, currentName: finishedName, finished: false))

                if !cancelled {
                    startNext()
                }
            }
        }

        continuation?.yield(ScanProgress(completed: completed, total: total, finished: true))
        finishStream()
    }

    private func finishStream() {
        continuation?.finish()
        continuation = nil
        runTask = nil
    }

    /// Runs extraction for one person: skips people with nothing to go on, otherwise calls the
    /// provider, embeds the result, and writes the `Profile`. Returns the person's display name
    /// (for progress reporting). Job state ends `.done` once a profile is written, `.skipped`
    /// when there's nothing to extract from, and `.failed` only if the store write or the
    /// provider call throws — an embedding failure alone does not fail the job (the profile is
    /// still saved, with `embedding: nil`).
    private func extractPerson(personId: String) async -> String {
        let existingPerson = try? store.person(id: personId)
        let displayName = existingPerson?.displayName ?? personId

        continuation?.yield(ScanProgress(completed: completed, total: total, currentName: displayName, finished: false))

        do {
            try store.setJob(kind: .extract, personId: personId, state: .running)

            guard let person = existingPerson else {
                try? store.setJob(kind: .extract, personId: personId, state: .failed, error: "person \(personId) not found")
                return displayName
            }

            let pages = try store.pagesForAccepted(personId: personId)

            // Nothing to extract from: no pages, and the address book itself has no
            // organization/job title either.
            if pages.isEmpty, person.organization == nil, person.jobTitle == nil {
                try store.setJob(kind: .extract, personId: personId, state: .skipped)
                return displayName
            }

            let channels = try store.channels(personId: personId)
            let input = ExtractionInput(person: person, channels: channels, pages: pages)
            let facts = try await provider.extract(input)

            let confidence = pages.isEmpty ? 0.3 : min(1.0, 0.4 + 0.1 * Double(pages.count))

            var embedding: [Float]?
            do {
                embedding = try await embedder.embed(person.displayName + "\n" + facts.searchableText)
            } catch {
                // The embedding is a nice-to-have on top of the extracted facts, not something
                // worth failing the whole job over — save the profile without one and surface
                // the failure through `waitingFor` once, so observers can see it happened.
                embedding = nil
                continuation?.yield(ScanProgress(completed: completed, total: total, currentName: displayName, waitingFor: "\(error)", finished: false))
            }

            let profile = Profile(
                personId: personId,
                facts: facts,
                confidence: confidence,
                providerId: provider.spec.id,
                model: nil,
                embedding: embedding
            )
            try store.upsertProfile(profile)
            try store.setJob(kind: .extract, personId: personId, state: .done)
        } catch {
            try? store.setJob(kind: .extract, personId: personId, state: .failed, error: "\(error)")
        }

        return displayName
    }
}
