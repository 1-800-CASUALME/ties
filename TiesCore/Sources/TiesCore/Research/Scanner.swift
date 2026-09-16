import Foundation

/// Orchestrates a research scan across a batch of people: runs every `Probe` for each person,
/// groups and scores the resulting findings, writes the candidates to the `Store`, and streams
/// `ScanProgress` as the run proceeds. Supports pausing (stops starting new people, lets
/// in-flight ones finish) and cancelling (same, but the stream ends promptly afterward).
public actor Scanner {
    private let store: Store
    private let probes: [any Probe]
    private let client: any HTTPClient
    private let weights: ScoringWeights
    private let concurrency: Int
    /// How long to back off after a `SearchBackendError.challenge` before retrying the probe
    /// once. An `init` parameter (rather than a hardcoded 300s) so tests can shorten it.
    private let challengeBackoff: Duration

    private var paused = false
    private var cancelled = false
    private var continuation: AsyncStream<ScanProgress>.Continuation?
    private var completed = 0
    private var total = 0

    public init(
        store: Store,
        probes: [any Probe],
        client: any HTTPClient,
        weights: ScoringWeights = .default,
        concurrency: Int = 4,
        challengeBackoff: Duration = .seconds(300)
    ) {
        self.store = store
        self.probes = probes
        self.client = client
        self.weights = weights
        self.concurrency = concurrency
        self.challengeBackoff = challengeBackoff
    }

    /// Starts scanning `personIds` and returns immediately with a stream of progress events.
    /// The actual work runs in a `Task` owned by the actor (independent of the caller's task),
    /// so the stream keeps delivering events even if the caller doesn't stay suspended on this
    /// call. The stream's final event always has `finished == true`.
    public func run(personIds: [String]) -> AsyncStream<ScanProgress> {
        let (stream, continuation) = AsyncStream<ScanProgress>.makeStream(of: ScanProgress.self)
        self.continuation = continuation
        self.completed = 0
        self.total = personIds.count
        self.cancelled = false
        self.paused = false

        Task {
            await self.execute(personIds: personIds)
        }

        return stream
    }

    /// Stops starting new people once the current batch finishes; in-flight people run to
    /// completion. Checked before every new person is scheduled.
    public func pause() {
        paused = true
    }

    public func resume() {
        paused = false
    }

    /// Stops scheduling any further people. People already in flight finish normally; the
    /// stream ends (with a final `finished == true` event) once they do.
    public func cancel() {
        cancelled = true
    }

    private func execute(personIds: [String]) async {
        do {
            try store.enqueue(kind: .scan, personIds: personIds)
        } catch {
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
                    await self.scanPerson(personId: personId)
                }
            }

            while inFlight < maxInFlight, index < personIds.count {
                await waitWhilePaused()
                if cancelled { break }
                startNext()
            }

            while let finishedName = await group.next() {
                inFlight -= 1
                completed += 1
                continuation?.yield(ScanProgress(completed: completed, total: total, currentName: finishedName, finished: false))

                if !cancelled {
                    await waitWhilePaused()
                }
                if !cancelled {
                    startNext()
                }
            }
        }

        continuation?.yield(ScanProgress(completed: completed, total: total, finished: true))
        finishStream()
    }

    private func waitWhilePaused() async {
        while paused && !cancelled {
            try? await Task.sleep(for: .milliseconds(200))
        }
    }

    private func finishStream() {
        continuation?.finish()
        continuation = nil
    }

    /// Runs every probe for one person, scores the findings, and writes the resulting
    /// candidates to the store. Returns the person's display name (for progress reporting).
    /// Job state ends `.done` once the person has been processed, even if some probes failed
    /// (those are logged and skipped); it ends `.failed` only if the store write throws or
    /// building the `ProbeInput` throws.
    private func scanPerson(personId: String) async -> String {
        let existingPerson = try? store.person(id: personId)
        let displayName = existingPerson?.displayName ?? personId

        continuation?.yield(ScanProgress(completed: completed, total: total, currentName: displayName, finished: false))

        do {
            try store.setJob(kind: .scan, personId: personId, state: .running)

            guard let person = existingPerson else {
                try? store.setJob(kind: .scan, personId: personId, state: .failed, error: "person \(personId) not found")
                return displayName
            }

            let channels = try store.channels(personId: personId)
            let probeInput = ProbeInput(person: person, channels: channels)

            var findings: [ProbeFinding] = []
            var errors: [String] = []

            for probe in probes {
                do {
                    let result = try await probe.run(probeInput, client: client)
                    findings.append(contentsOf: result)
                } catch SearchBackendError.challenge {
                    continuation?.yield(ScanProgress(completed: completed, total: total, currentName: displayName, waitingFor: "DuckDuckGo", finished: false))
                    try? await Task.sleep(for: challengeBackoff)
                    do {
                        let retryResult = try await probe.run(probeInput, client: client)
                        findings.append(contentsOf: retryResult)
                    } catch {
                        errors.append("\(probe.id): \(error)")
                    }
                } catch HTTPError.rateLimited(let retryAfter) {
                    try? await Task.sleep(for: .seconds(retryAfter))
                    do {
                        let retryResult = try await probe.run(probeInput, client: client)
                        findings.append(contentsOf: retryResult)
                    } catch {
                        errors.append("\(probe.id): \(error)")
                    }
                } catch {
                    errors.append("\(probe.id): \(error)")
                }
            }

            let groups = CandidateGrouper.group(findings)
            let scored = CandidateScorer.score(groups: groups, input: probeInput, weights: weights)

            try store.replaceCandidates(
                personId: personId,
                candidates: scored.map(\.candidate),
                evidence: scored.flatMap(\.evidence),
                pages: scored.flatMap(\.pages)
            )
            try store.setJob(kind: .scan, personId: personId, state: .done)
        } catch {
            try? store.setJob(kind: .scan, personId: personId, state: .failed, error: "\(error)")
        }

        return displayName
    }
}
