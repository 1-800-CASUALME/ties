import Foundation

/// Orchestrates a research scan across a batch of people: runs every `Probe` for each person,
/// groups and scores the resulting findings, writes the candidates to the `Store`, and streams
/// `ScanProgress` as the run proceeds. Supports pausing (stops starting new people, lets
/// in-flight ones finish) and cancelling (same, but the stream ends promptly afterward, even
/// mid-backoff). Only one run can be active at a time; a `run(personIds:)` call while another is
/// still in progress is rejected with an immediate, single-event stream rather than disturbing
/// the active run.
public actor Scanner {
    /// Shown once the search backend has challenged twice in a row and web search is off for
    /// the rest of the run.
    public static let searchSkippedNotice = "The search engine is blocking searches, so the rest of this run skips the web. Switch engine or research again later."

    private let store: Store
    private let probes: [any Probe]
    private let client: any HTTPClient
    private let weights: ScoringWeights
    /// How deeply each person is researched. Quick skips web search entirely for anyone whose
    /// own links already say who they are.
    private let mode: ScanMode
    private let concurrency: Int
    /// How long to back off after a `SearchBackendError.challenge` before retrying the probe
    /// once. An `init` parameter (rather than a hardcoded 300s) so tests can shorten it.
    private let challengeBackoff: Duration

    private var paused = false
    private var cancelled = false
    /// Consecutive backend challenges per probe in this run. After `maxChallenges` that probe
    /// is skipped for the remaining people instead of stalling every one of them.
    private var challenges: [String: Int] = [:]
    private let maxChallenges = 2
    private var skippedProbes: Set<String> = []
    private var continuation: AsyncStream<ScanProgress>.Continuation?
    /// The `Task` running the active `execute(personIds:)`. Kept so a run in progress is
    /// visible/trackable beyond just the continuation; `run(personIds:)` is rejected while this
    /// (or `continuation`) is non-nil.
    private var runTask: Task<Void, Never>?
    private var completed = 0
    private var total = 0

    public init(
        store: Store,
        probes: [any Probe],
        client: any HTTPClient,
        weights: ScoringWeights = .default,
        mode: ScanMode = .thorough,
        concurrency: Int = 4,
        challengeBackoff: Duration = .seconds(60)
    ) {
        self.store = store
        self.probes = probes
        self.client = client
        self.weights = weights
        self.mode = mode
        self.concurrency = concurrency
        self.challengeBackoff = challengeBackoff
    }

    /// Starts scanning `personIds` and returns immediately with a stream of progress events.
    /// The actual work runs in a `Task` owned by the actor (independent of the caller's task),
    /// so the stream keeps delivering events even if the caller doesn't stay suspended on this
    /// call. The stream's final event always has `finished == true` — whether the run completes
    /// normally, fails to enqueue, or (see below) is rejected outright.
    ///
    /// If a scan is already running, this call doesn't touch it: it returns a separate stream
    /// whose only event is `ScanProgress(completed: 0, total: 0, waitingFor: "Another scan is
    /// running", finished: true)`.
    public func run(personIds: [String]) -> AsyncStream<ScanProgress> {
        guard continuation == nil else {
            let (busyStream, busyContinuation) = AsyncStream<ScanProgress>.makeStream(of: ScanProgress.self)
            busyContinuation.yield(ScanProgress(completed: 0, total: 0, currentName: nil, waitingFor: "Another scan is running", finished: true))
            busyContinuation.finish()
            return busyStream
        }

        let (stream, continuation) = AsyncStream<ScanProgress>.makeStream(of: ScanProgress.self)
        self.continuation = continuation
        self.completed = 0
        self.total = personIds.count
        self.cancelled = false
        self.challenges = [:]
        self.skippedProbes = []
        self.paused = false

        runTask = Task {
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

    /// Stops scheduling any further people. People already in flight finish normally, but a
    /// probe currently backing off after a challenge/rate-limit response gives up its retry
    /// promptly (within one backoff-polling interval) rather than waiting out the full delay.
    /// The stream ends (with a final `finished == true` event) once nothing is left in flight.
    public func cancel() {
        cancelled = true
    }

    private func execute(personIds: [String]) async {
        do {
            try store.enqueue(kind: .scan, personIds: personIds)
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
                continuation?.yield(ScanProgress(completed: completed, total: total, currentName: finishedName, finished: false, notice: skippedProbes.isEmpty ? nil : Scanner.searchSkippedNotice))

                // The pause gate sits immediately before `startNext()` (not before this whole
                // block) so a completion that arrives while paused is still counted and
                // reported right away; only *starting the next person* waits on `resume()`.
                if !cancelled {
                    await waitWhilePaused()
                    if !cancelled {
                        startNext()
                    }
                }
            }
        }

        continuation?.yield(ScanProgress(completed: completed, total: total, finished: true, notice: skippedProbes.isEmpty ? nil : Scanner.searchSkippedNotice))
        finishStream()
    }

    /// Hosts where a link says nothing about who owns it: shorteners, and the stores of files
    /// and videos anyone can post to.
    private static let sharedHosts = [
        "bit.ly", "t.co", "lnkd.in", "goo.gl", "tinyurl.com", "wa.me", "t.me",
        "youtube.com", "youtu.be", "docs.google.com", "drive.google.com",
    ]

    /// True when a link the person shared themselves is worth fetching as their identity: a
    /// profile on linkedin.com, github.com or x.com, or their own domain. `SignalRules` only
    /// keeps identity-shaped URLs in the first place, so everything that isn't behind a
    /// shortener or on a file/video host is one of those two.
    static func isCandidateWorthy(_ url: String) -> Bool {
        guard let components = URLComponents(string: url),
              let scheme = components.scheme?.lowercased(),
              scheme == "https" || scheme == "http",
              let host = components.host?.lowercased() else { return false }
        return !sharedHosts.contains { host == $0 || host.hasSuffix("." + $0) }
    }

    private func waitWhilePaused() async {
        while paused && !cancelled {
            try? await Task.sleep(for: .milliseconds(200))
        }
    }

    /// Sleeps for `duration`, but in ≤250ms chunks, re-checking `cancelled` between each chunk —
    /// so a `cancel()` fired mid-backoff is observed within one chunk instead of only after the
    /// whole duration (which, for a 300s challenge backoff, would otherwise make `cancel()`
    /// effectively unusable for minutes).
    private func sleepUnlessCancelled(_ duration: Duration) async {
        var remaining = duration
        let chunk = Duration.milliseconds(250)
        while remaining > .zero, !cancelled {
            let step = min(remaining, chunk)
            try? await Task.sleep(for: step)
            remaining -= step
        }
    }

    private func finishStream() {
        continuation?.finish()
        continuation = nil
        runTask = nil
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
            let signals = try? store.signals(personId: personId)
            let probeInput = ProbeInput(person: person, channels: channels, signals: signals)

            var findings: [ProbeFinding] = []
            var errors: [String] = []
            var finishedStages: [String] = []

            // A link the person shared or signed with themselves settles who they are, so it is
            // fetched directly rather than hoped for in a search result. In quick mode that
            // makes the web search redundant — the expensive probe skipped for the one case
            // where its answer is already known.
            let selfLinks = (signals?.links ?? []).filter(Scanner.isCandidateWorthy)
            let skipSearch = mode == .quick && !selfLinks.isEmpty
            if !selfLinks.isEmpty {
                let pageProbe = probes.compactMap { $0 as? PageFetchProbe }.first ?? PageFetchProbe()
                continuation?.yield(ScanProgress(
                    completed: completed, total: total, currentName: displayName, finished: false,
                    stage: pageProbe.displayName, finishedStages: finishedStages,
                    notice: skippedProbes.isEmpty ? nil : Scanner.searchSkippedNotice
                ))
                findings += await pageProbe.fetchDirect(urls: selfLinks, input: probeInput, client: client)
            }

            for probe in probes {
                if skipSearch, probe.id == "search" {
                    continue
                }
                if skippedProbes.contains(probe.id) {
                    errors.append("\(probe.id): skipped after repeated challenges")
                    continue
                }
                continuation?.yield(ScanProgress(
                    completed: completed, total: total, currentName: displayName, finished: false,
                    stage: probe.displayName, finishedStages: finishedStages,
                    notice: skippedProbes.isEmpty ? nil : Scanner.searchSkippedNotice
                ))
                do {
                    let result = try await probe.run(probeInput, client: client)
                    findings.append(contentsOf: result)
                    challenges[probe.id] = 0
                    finishedStages.append(probe.displayName)
                } catch SearchBackendError.challenge {
                    challenges[probe.id, default: 0] += 1
                    if challenges[probe.id, default: 0] >= maxChallenges {
                        skippedProbes.insert(probe.id)
                        errors.append("\(probe.id): skipped after repeated challenges")
                        continuation?.yield(ScanProgress(
                            completed: completed, total: total, currentName: displayName, finished: false,
                            stage: probe.displayName, finishedStages: finishedStages,
                            notice: Scanner.searchSkippedNotice
                        ))
                        continue
                    }
                    continuation?.yield(ScanProgress(
                        completed: completed, total: total, currentName: displayName,
                        waitingFor: "DuckDuckGo", finished: false,
                        stage: probe.displayName, finishedStages: finishedStages
                    ))
                    await sleepUnlessCancelled(challengeBackoff)
                    if !cancelled {
                        do {
                            let retryResult = try await probe.run(probeInput, client: client)
                            findings.append(contentsOf: retryResult)
                            challenges[probe.id] = 0
                            finishedStages.append(probe.displayName)
                        } catch {
                            errors.append("\(probe.id): \(error)")
                            if case SearchBackendError.challenge = error {
                                challenges[probe.id, default: 0] += 1
                                if challenges[probe.id, default: 0] >= maxChallenges {
                                    skippedProbes.insert(probe.id)
                                }
                            }
                        }
                    }
                } catch HTTPError.rateLimited(let retryAfter) {
                    let clampedRetryAfter = min(retryAfter, 120)
                    await sleepUnlessCancelled(.seconds(clampedRetryAfter))
                    if !cancelled {
                        do {
                            let retryResult = try await probe.run(probeInput, client: client)
                            findings.append(contentsOf: retryResult)
                            finishedStages.append(probe.displayName)
                        } catch {
                            errors.append("\(probe.id): \(error)")
                        }
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
