import Testing
import Foundation
@testable import TiesCore

// MARK: - Fakes

/// Which worker answered which query, in the order the pool called them — the one thing every
/// round-robin assertion is really about. Shared by the fake workers of a single pool.
final class CallLog: @unchecked Sendable {
    private let lock = NSLock()
    private var calls: [(worker: String, query: String)] = []

    func record(worker: String, query: String) {
        lock.lock()
        calls.append((worker, query))
        lock.unlock()
    }

    var workerIds: [String] {
        lock.lock()
        defer { lock.unlock() }
        return calls.map(\.worker)
    }

    var queries: [String] {
        lock.lock()
        defer { lock.unlock() }
        return calls.map(\.query)
    }
}

/// A `SearchBackend` that answers instantly, so the pool's dispatching can be tested without a
/// web view anywhere near it. `challenges` searches throw `.challenge` before the rest succeed;
/// `failures` (checked first) throw a transport error instead.
final class FakeWorker: SearchEngineSwitching, @unchecked Sendable {
    let id: String
    private let log: CallLog
    private let lock = NSLock()
    private var remainingChallenges: Int
    private var remainingFailures: Int
    private var switches: [SearchEngine] = []

    init(id: String, log: CallLog = CallLog(), challenges: Int = 0, failures: Int = 0) {
        self.id = id
        self.log = log
        self.remainingChallenges = challenges
        self.remainingFailures = failures
    }

    /// The engines this worker has been moved onto, in order.
    var engineSwitches: [SearchEngine] {
        lock.lock()
        defer { lock.unlock() }
        return switches
    }

    func search(_ query: String) async throws -> [SearchHit] {
        try answer(query)
    }

    func switchEngine(_ engine: SearchEngine) {
        lock.lock()
        switches.append(engine)
        lock.unlock()
    }

    // `NSLock` is `noasync`, so the bookkeeping happens in a plain synchronous helper.
    private func answer(_ query: String) throws -> [SearchHit] {
        log.record(worker: id, query: query)
        lock.lock()
        let failing = remainingFailures > 0
        if failing { remainingFailures -= 1 }
        let challenging = !failing && remainingChallenges > 0
        if challenging { remainingChallenges -= 1 }
        lock.unlock()

        if failing { throw SearchBackendError.transport("boom") }
        if challenging { throw SearchBackendError.challenge }
        return [SearchHit(url: "https://example.com/\(id)", title: query, snippet: "")]
    }
}

private func testEngine(_ id: String) -> SearchEngine {
    SearchEngine(
        id: id,
        name: id,
        urlTemplate: "https://\(id).example/?q=%@",
        resultScript: "[]",
        challengeMarkers: []
    )
}

private let threeEngines = [testEngine("one"), testEngine("two"), testEngine("three")]

// MARK: - Dispatch

@Test func poolDispatchesQueriesRoundRobinOverItsWorkers() async throws {
    let log = CallLog()
    let workers = ["a", "b", "c"].map { FakeWorker(id: $0, log: log) }
    let pool = SearchPool(workers: workers, engines: threeEngines)

    for i in 0..<6 {
        let hits = try await pool.search("q\(i)")
        #expect(hits.count == 1)
    }

    #expect(pool.id == "pool")
    #expect(log.workerIds == ["a", "b", "c", "a", "b", "c"])
    #expect(log.queries == ["q0", "q1", "q2", "q3", "q4", "q5"])
}

@Test func poolIgnoresDisabledEnginesAndEmptyWorkerLists() async throws {
    let pool = SearchPool(workers: [], engines: threeEngines)
    await #expect(throws: SearchBackendError.self) { _ = try await pool.search("q") }
}

/// A worker that records how many queries it is answering at the same time — the one thing
/// "a worker is given one query at a time" is really about.
final class OverlapWorker: SearchBackend, @unchecked Sendable {
    let id: String
    private let lock = NSLock()
    private var running = 0
    private var peak = 0
    private var answered = 0

    init(id: String) {
        self.id = id
    }

    /// The most queries this worker ever had in flight at once.
    var maxOverlap: Int {
        lock.withLock { peak }
    }

    var callCount: Int {
        lock.withLock { answered }
    }

    func search(_ query: String) async throws -> [SearchHit] {
        enter()
        defer { leave() }
        try await Task.sleep(for: .milliseconds(20))
        return [SearchHit(url: "https://example.com/\(id)", title: query, snippet: "")]
    }

    private func enter() {
        lock.withLock {
            running += 1
            answered += 1
            peak = max(peak, running)
        }
    }

    private func leave() {
        lock.withLock { running -= 1 }
    }
}

@Test func aWorkerIsNeverGivenTwoQueriesAtOnce() async throws {
    // The app runs `2 × poolSize` people at a time, so this is the ordinary case rather than a
    // corner one: six callers, two web views.
    let workers = ["a", "b"].map { OverlapWorker(id: $0) }
    let pool = SearchPool(workers: workers, engines: threeEngines)

    let hits = try await withThrowingTaskGroup(of: Int.self) { group in
        for index in 0..<6 {
            group.addTask { try await pool.search("q\(index)").count }
        }
        var total = 0
        for try await count in group { total += count }
        return total
    }

    // Every query was answered, and no web view was ever asked two things at once.
    #expect(hits == 6)
    #expect(workers.map(\.maxOverlap) == [1, 1])
    #expect(workers.reduce(0) { $0 + $1.callCount } == 6)
}

@Test func aQueryWaitingForAWorkerGivesUpWhenItsCallerIsCancelled() async throws {
    let worker = BlockingWorker()
    let pool = SearchPool(workers: [worker], engines: threeEngines)

    let first = Task { try await pool.search("holds the worker") }
    while !worker.started { await Task.yield() }

    // The only worker is taken, so this one parks inside the pool rather than piling onto it.
    let queued = Task { try await pool.search("waits for it") }
    await Task.yield()
    queued.cancel()
    await #expect(throws: CancellationError.self) { try await queued.value }

    first.cancel()
    await #expect(throws: CancellationError.self) { try await first.value }
}

// MARK: - Failover

@Test func aChallengedWorkerIsSkippedForTheCooldownAndTheQueryRetriedOnAnother() async throws {
    let log = CallLog()
    let a = FakeWorker(id: "a", log: log, challenges: 1)
    let b = FakeWorker(id: "b", log: log)
    let pool = SearchPool(workers: [a, b], engines: threeEngines, failoverCooldown: .seconds(600))

    let hits = try await pool.search("one")
    #expect(hits.first?.url == "https://example.com/b")

    _ = try await pool.search("two")
    _ = try await pool.search("three")

    // "a" answered once (with the challenge) and was skipped from then on; the challenged
    // query was retried on "b" rather than lost.
    #expect(log.workerIds == ["a", "b", "b", "b"])
    #expect(log.queries == ["one", "one", "two", "three"])
}

@Test func aWorkerComesBackOnceItsCooldownHasPassed() async throws {
    let log = CallLog()
    let a = FakeWorker(id: "a", log: log, challenges: 1)
    let b = FakeWorker(id: "b", log: log)
    let pool = SearchPool(workers: [a, b], engines: threeEngines, failoverCooldown: .milliseconds(50))

    _ = try await pool.search("one")
    try await Task.sleep(for: .milliseconds(120))
    _ = try await pool.search("two")

    #expect(log.workerIds == ["a", "b", "a"])
}

@Test func aChallengeMovesThatWorkerToTheNextEngine() async throws {
    let log = CallLog()
    let a = FakeWorker(id: "a", log: log, challenges: 1)
    let b = FakeWorker(id: "b", log: log)
    let pool = SearchPool(workers: [a, b], engines: threeEngines, failoverCooldown: .seconds(600))

    _ = try await pool.search("one")

    #expect(a.engineSwitches.map(\.id) == ["two"])
    #expect(b.engineSwitches.isEmpty)
    #expect(pool.id == "pool")
}

@Test func engineFailoverWrapsAroundTheEngineList() async throws {
    let worker = FakeWorker(id: "solo", challenges: 3)
    // A zero cooldown is what lets one worker be asked again inside the same test; the
    // wrap-around it proves is the same one a 10-minute cooldown reaches an hour later.
    let pool = SearchPool(workers: [worker], engines: threeEngines, failoverCooldown: .zero)

    await #expect(throws: SearchBackendError.self) { _ = try await pool.search("one") }
    _ = try await pool.search("two")

    #expect(worker.engineSwitches.map(\.id) == ["two", "three", "one"])
}

@Test func aLoneEngineIsNeverSwitchedAwayFrom() async throws {
    let worker = FakeWorker(id: "solo", challenges: 1)
    let pool = SearchPool(workers: [worker], engines: [testEngine("one")], failoverCooldown: .seconds(600))

    await #expect(throws: SearchBackendError.self) { _ = try await pool.search("one") }

    // There is nowhere to fail over to, so the worker is cooled down and left where it is.
    #expect(worker.engineSwitches.isEmpty)
}

@Test func aPoolWhoseWorkersAreAllCoolingDownThrowsChallenge() async throws {
    let log = CallLog()
    let a = FakeWorker(id: "a", log: log, challenges: 1)
    let b = FakeWorker(id: "b", log: log)
    let pool = SearchPool(workers: [a, b], engines: threeEngines, failoverCooldown: .seconds(600))

    _ = try await pool.search("one")

    // Now put the second one on the wall too, and the pool has nothing left to ask.
    let both = SearchPool(
        workers: [FakeWorker(id: "c", log: log, challenges: 1), FakeWorker(id: "d", log: log, challenges: 1)],
        engines: threeEngines,
        failoverCooldown: .seconds(600)
    )
    await #expect(throws: SearchBackendError.self) { _ = try await both.search("two") }
    await #expect(throws: SearchBackendError.self) { _ = try await both.search("three") }

    // The last search asked nobody: every worker was still cooling down.
    #expect(log.workerIds == ["a", "b", "c", "d"])
}

@Test func anErrorThatIsNotAChallengeIsNotRetriedAndNotCooledDown() async throws {
    let log = CallLog()
    let a = FakeWorker(id: "a", log: log, failures: 1)
    let b = FakeWorker(id: "b", log: log)
    let pool = SearchPool(workers: [a, b], engines: threeEngines)

    await #expect(throws: SearchBackendError.self) { _ = try await pool.search("one") }
    _ = try await pool.search("two")
    _ = try await pool.search("three")

    // A timeout says nothing about bot walls: "a" keeps its turn in the rotation.
    #expect(log.workerIds == ["a", "b", "a"])
    #expect(a.engineSwitches.isEmpty)
}

// MARK: - Pacing

@Test func jitteredIntervalStaysWithinSevenTenthsOfTheBaseSpacing() {
    #expect(abs(SearchPool.nextInterval(base: 2.5, jitter: 0.7, random: { $0.lowerBound }) - 1.8) < 1e-9)
    #expect(abs(SearchPool.nextInterval(base: 2.5, jitter: 0.7, random: { $0.upperBound }) - 3.2) < 1e-9)
    #expect(abs(SearchPool.nextInterval(base: 2.5, jitter: 0, random: { _ in 0 }) - 2.5) < 1e-9)

    for _ in 0..<1_000 {
        let interval = SearchPool.nextInterval(base: 2.5, jitter: 0.7)
        #expect(interval >= 1.8 - 1e-9)
        #expect(interval <= 3.2 + 1e-9)
    }
}

@Test func jitterNeverPacesFasterThanOneSecond() {
    // Jitter must not be able to turn a short base interval into a burst.
    #expect(SearchPool.nextInterval(base: 1.2, jitter: 0.7, random: { $0.lowerBound }) == 1.0)
    #expect(SearchPool.nextInterval(base: 0.1, jitter: 0, random: { _ in 0 }) == 1.0)
}

// MARK: - Engines and their redirectors

@Test func bingLinksDecodeOutOfTheirRedirector() {
    // A real `h2 a` href, captured by `scripts/spike-engines.swift`.
    let real = "https://www.bing.com/ck/a?!&&p=e75594df152d206c39f97466348b9ea93e2bb6a9a31d453ff2823aa01bea76ccJmltdHM9MTc4OTUxNjgwMA&ptn=3&ver=2&hsh=4&fclid=240f7656-3059-68a8-0bb9-618031ae69cb&u=a1aHR0cHM6Ly9mb3J1bXMuY29tbWVudGNhbWFyY2hlLm5ldC9mb3J1bS9hZmZpY2gtMzcxNjczODctNnBsYXk&ntb=1"
    #expect(SearchEngine.decodeBingLink(real) == "https://forums.commentcamarche.net/forum/affich-37167387-6play")

    let profile = "https://www.bing.com/ck/a?!&&p=abc&u=a1aHR0cHM6Ly93d3cubGlua2VkaW4uY29tL2luL3RpbS1jb29rLTQ3NTIyYjY&ntb=1"
    #expect(SearchEngine.decodeBingLink(profile) == "https://www.linkedin.com/in/tim-cook-47522b6")
    #expect(SearchEngine.bing.destination(of: profile) == "https://www.linkedin.com/in/tim-cook-47522b6")

    // Anything that isn't one of Bing's wrappers is already the destination and is left alone.
    #expect(SearchEngine.decodeBingLink("https://www.linkedin.com/in/timhcook") == nil)
    #expect(SearchEngine.decodeBingLink("https://www.bing.com/search?q=cats") == nil)
    #expect(SearchEngine.decodeBingLink("https://www.bing.com/ck/a?u=zz123") == nil)
    #expect(SearchEngine.bing.destination(of: "https://uk.linkedin.com/in/cooktim") == "https://uk.linkedin.com/in/cooktim")
}

@Test func yahooLinksDecodeOutOfTheirRedirector() {
    let wrapped = "https://r.search.yahoo.com/_ylt=AwrFbFf1/RV=2/RE=1789516800/RO=10/RU=https%3a%2f%2fwww.linkedin.com%2fin%2ftim-cook-47522b6/RK=2/RS=8MsX9pRhVw-"
    #expect(SearchEngine.decodeYahooLink(wrapped) == "https://www.linkedin.com/in/tim-cook-47522b6")

    // The trailing `/RK=` segment is optional.
    let noRK = "https://r.search.yahoo.com/_ylt=A0/RU=https%3a%2f%2fuk.linkedin.com%2fin%2fcooktim"
    #expect(SearchEngine.decodeYahooLink(noRK) == "https://uk.linkedin.com/in/cooktim")

    // The anonymous layout links straight out, which is what the spike actually saw.
    #expect(SearchEngine.decodeYahooLink("https://www.linkedin.com/in/timhcook") == nil)
    #expect(SearchEngine.yahoo.destination(of: "https://www.linkedin.com/in/timhcook") == "https://www.linkedin.com/in/timhcook")
    #expect(SearchEngine.yahoo.destination(of: wrapped) == "https://www.linkedin.com/in/tim-cook-47522b6")
}

@Test func onlyTheEnginesThatPassedTheSpikeAreEnabled() {
    #expect(SearchEngine.enabledEngines.map(\.id) == ["duckduckgo", "yahoo"])
    #expect(SearchEngine.all.filter { !$0.enabled }.map(\.id) == ["bing", "brave", "mojeek"])
    // Failover order: the pool moves a challenged web view onto the next *enabled* engine.
    #expect(SearchEngine.all.first?.id == "duckduckgo")
    #expect(SearchEngine.duckduckgo.url(for: "\"Tim Cook\" site:linkedin.com/in")?.absoluteString
        == "https://duckduckgo.com/?ia=web&q=%22Tim%20Cook%22%20site:linkedin.com/in")
    #expect(SearchEngine.yahoo.url(for: "a b")?.absoluteString == "https://search.yahoo.com/search?p=a%20b")
}

@Test func aPoolFailsOverFromDuckDuckGoToYahoo() async throws {
    let a = FakeWorker(id: "a", challenges: 1)
    let b = FakeWorker(id: "b")
    let pool = SearchPool(workers: [a, b], engines: SearchEngine.all, failoverCooldown: .seconds(600))

    _ = try await pool.search("q")

    // Disabled engines are filtered out in `init`, so the next engine is the next *working* one.
    #expect(a.engineSwitches.map(\.id) == ["yahoo"])
}

// MARK: - Cancellation

/// A worker that never answers on its own: it hangs until the caller's task is cancelled,
/// which is what a real web view three seconds into a twenty-five-second page load looks
/// like from the pool's side.
final class BlockingWorker: SearchBackend, @unchecked Sendable {
    let id = "blocking"
    private let lock = NSLock()
    private var continuation: CheckedContinuation<[SearchHit], Error>?
    private var hasStarted = false
    private var cancelled = false

    var started: Bool {
        lock.lock()
        defer { lock.unlock() }
        return hasStarted
    }

    func search(_ query: String) async throws -> [SearchHit] {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                park(continuation)
            }
        } onCancel: {
            release()
        }
    }

    private func park(_ continuation: CheckedContinuation<[SearchHit], Error>) {
        lock.lock()
        hasStarted = true
        if cancelled {
            lock.unlock()
            continuation.resume(throwing: CancellationError())
            return
        }
        self.continuation = continuation
        lock.unlock()
    }

    private func release() {
        lock.lock()
        let waiting = continuation
        continuation = nil
        cancelled = true
        lock.unlock()
        waiting?.resume(throwing: CancellationError())
    }
}

@Test func aCancelledCallerStopsWaitingOnAWorkerThatHasNotAnswered() async throws {
    let worker = BlockingWorker()
    let pool = SearchPool(workers: [worker], engines: threeEngines)

    let task = Task { try await pool.search("q") }
    while !worker.started { await Task.yield() }

    let clock = ContinuousClock()
    let start = clock.now
    task.cancel()
    await #expect(throws: CancellationError.self) { try await task.value }

    // "Promptly" meaning nothing like the 25 s a real page load would have taken.
    #expect(clock.now - start < .seconds(2))
}

@Test func anAlreadyCancelledCallerNeverReachesAWorker() async throws {
    let log = CallLog()
    let pool = SearchPool(workers: [FakeWorker(id: "a", log: log)], engines: threeEngines)

    let task = Task {
        // Be demonstrably cancelled *before* calling in, so this tests the pool's own check
        // rather than a race with it.
        while !Task.isCancelled { await Task.yield() }
        return try await pool.search("q")
    }
    task.cancel()

    await #expect(throws: CancellationError.self) { try await task.value }
    #expect(log.workerIds.isEmpty)
}
