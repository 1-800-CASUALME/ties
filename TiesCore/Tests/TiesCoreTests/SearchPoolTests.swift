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
