import Testing
import Foundation
@testable import TiesCore

struct StaticProbe: Probe {
    let id: String; let findings: [ProbeFinding]; let failFor: String?
    func run(_ input: ProbeInput, client: any HTTPClient) async throws -> [ProbeFinding] {
        if input.person.givenName == failFor { throw HTTPError.status(500, "x") }
        return findings.map { var f = $0; f.displayName = input.fullName; return f }
    }
}

@Test func scannerWritesCandidatesAndJobs() async throws {
    let store = try Store.inMemory()
    let a = Person(givenName: "Sara", familyName: "Ahmed"), b = Person(givenName: "Bob", familyName: "Ray")
    try store.upsertPeople([a, b], channels: [])
    let probe = StaticProbe(id: "s", findings: [ProbeFinding(url: "https://site/x", displayName: nil, headline: "CEO", company: nil, location: nil, avatarURL: nil, username: nil,
        pageTitle: nil, snippet: nil, bodyText: nil, pageKind: .serp, evidence: [EvidenceItem(kind: .emailHash, weight: 8, detail: "", sourceURL: nil)], linkedURLs: [])], failFor: "Bob")
    let scanner = Scanner(store: store, probes: [probe], client: FakeHTTP(), concurrency: 2)
    var last: ScanProgress?
    for await p in await scanner.run(personIds: [a.id, b.id]) { last = p }
    #expect(last?.finished == true); #expect(last?.completed == 2)
    #expect(try store.candidates(personId: a.id).first?.status == .auto)
    #expect(try store.candidates(personId: b.id).isEmpty)          // probe failed but scan continues; person just has no candidates
    let counts = try store.counts(kind: .scan)
    #expect(counts[.done] == 2)                                       // a failed probe is not a failed job
}

@Test func scannerCancelStopsEarly() async throws {
    let store = try Store.inMemory()
    let people = (0..<20).map { Person(givenName: "P\($0)", familyName: "X") }
    try store.upsertPeople(people, channels: [])
    struct Slow: Probe { let id = "slow"; func run(_ i: ProbeInput, client: any HTTPClient) async throws -> [ProbeFinding] { try await Task.sleep(for: .milliseconds(30)); return [] } }
    let scanner = Scanner(store: store, probes: [Slow()], client: FakeHTTP(), concurrency: 1)
    var seen = 0
    for await p in await scanner.run(personIds: people.map(\.id)) { seen = p.completed; if seen == 2 { await scanner.cancel() } }
    #expect(seen < 20)
}

// MARK: - Fix round 1: re-entrancy, enqueue-failure event, cancellable backoff

/// Thread-safe call counter for probes that need to behave differently on their first vs.
/// later invocations.
actor CallCounter {
    private(set) var count = 0
    @discardableResult
    func increment() -> Int {
        count += 1
        return count
    }
}

/// Throws `SearchBackendError.challenge` on its first invocation, then succeeds.
struct ChallengeOnceProbe: Probe {
    let id = "challenge-once"
    let counter: CallCounter
    let finding: ProbeFinding
    func run(_ input: ProbeInput, client: any HTTPClient) async throws -> [ProbeFinding] {
        if await counter.increment() == 1 { throw SearchBackendError.challenge }
        var f = finding
        f.displayName = input.fullName
        return [f]
    }
}

/// Throws `HTTPError.rateLimited` on its first invocation, then succeeds.
struct RateLimitedOnceProbe: Probe {
    let id = "rate-limited-once"
    let counter: CallCounter
    let finding: ProbeFinding
    func run(_ input: ProbeInput, client: any HTTPClient) async throws -> [ProbeFinding] {
        if await counter.increment() == 1 { throw HTTPError.rateLimited(retryAfter: 0.01) }
        var f = finding
        f.displayName = input.fullName
        return [f]
    }
}

/// Always throws `SearchBackendError.challenge`, counting every invocation.
struct AlwaysChallengeProbe: Probe {
    let id = "always-challenge"
    let counter: CallCounter
    func run(_ input: ProbeInput, client: any HTTPClient) async throws -> [ProbeFinding] {
        await counter.increment()
        throw SearchBackendError.challenge
    }
}

@Test func secondRunWhileActiveIsRejected() async throws {
    let store = try Store.inMemory()
    let people = (0..<3).map { Person(givenName: "P\($0)", familyName: "X") }
    try store.upsertPeople(people, channels: [])
    struct Slow: Probe { let id = "slow"; func run(_ i: ProbeInput, client: any HTTPClient) async throws -> [ProbeFinding] { try await Task.sleep(for: .milliseconds(200)); return [] } }
    let scanner = Scanner(store: store, probes: [Slow()], client: FakeHTTP(), concurrency: 1)

    // The first run's continuation is set synchronously before `run(personIds:)` returns, so by
    // the time this call comes back, the scanner is definitely "active" — no sleep/race needed.
    let firstStream = await scanner.run(personIds: people.map(\.id))
    let firstTask = Task { for await _ in firstStream {} }

    let secondStream = await scanner.run(personIds: people.map(\.id))
    var secondEvents: [ScanProgress] = []
    for await p in secondStream { secondEvents.append(p) }

    #expect(secondEvents.count == 1)
    #expect(secondEvents.first?.finished == true)
    #expect(secondEvents.first?.waitingFor == "Another scan is running")

    await scanner.cancel()
    await firstTask.value
}

@Test func scannerRetriesOnceAfterChallengeThenSucceeds() async throws {
    let store = try Store.inMemory()
    let a = Person(givenName: "Sara", familyName: "Ahmed")
    try store.upsertPeople([a], channels: [])
    let counter = CallCounter()
    let finding = ProbeFinding(url: "https://site/challenge", displayName: nil, headline: nil, company: nil, location: nil, avatarURL: nil, username: nil,
        pageTitle: nil, snippet: nil, bodyText: nil, pageKind: .serp, evidence: [EvidenceItem(kind: .emailHash, weight: 8, detail: "", sourceURL: nil)], linkedURLs: [])
    let probe = ChallengeOnceProbe(counter: counter, finding: finding)
    let scanner = Scanner(store: store, probes: [probe], client: FakeHTTP(), concurrency: 1, challengeBackoff: .milliseconds(5))

    var sawWaitingForDuckDuckGo = false
    for await p in await scanner.run(personIds: [a.id]) {
        if p.waitingFor == "DuckDuckGo" { sawWaitingForDuckDuckGo = true }
    }

    #expect(sawWaitingForDuckDuckGo)
    #expect(try store.candidates(personId: a.id).first?.status == .auto)
    let counts = try store.counts(kind: .scan)
    #expect(counts[.done] == 1)
    #expect(await counter.count == 2)
}

@Test func scannerRetriesOnceAfterRateLimitThenSucceeds() async throws {
    let store = try Store.inMemory()
    let a = Person(givenName: "Sara", familyName: "Ahmed")
    try store.upsertPeople([a], channels: [])
    let counter = CallCounter()
    let finding = ProbeFinding(url: "https://site/rate-limited", displayName: nil, headline: nil, company: nil, location: nil, avatarURL: nil, username: nil,
        pageTitle: nil, snippet: nil, bodyText: nil, pageKind: .serp, evidence: [EvidenceItem(kind: .emailHash, weight: 8, detail: "", sourceURL: nil)], linkedURLs: [])
    let probe = RateLimitedOnceProbe(counter: counter, finding: finding)
    let scanner = Scanner(store: store, probes: [probe], client: FakeHTTP(), concurrency: 1)

    var last: ScanProgress?
    for await p in await scanner.run(personIds: [a.id]) { last = p }

    #expect(last?.finished == true)
    #expect(try store.candidates(personId: a.id).first?.status == .auto)
    #expect(await counter.count == 2)
}

@Test func scannerRetriesChallengeExactlyOnceThenGivesUp() async throws {
    let store = try Store.inMemory()
    let a = Person(givenName: "Sara", familyName: "Ahmed")
    try store.upsertPeople([a], channels: [])
    let counter = CallCounter()
    let probe = AlwaysChallengeProbe(counter: counter)
    let scanner = Scanner(store: store, probes: [probe], client: FakeHTTP(), concurrency: 1, challengeBackoff: .milliseconds(5))

    var last: ScanProgress?
    for await p in await scanner.run(personIds: [a.id]) { last = p }

    #expect(last?.finished == true)
    #expect(try store.candidates(personId: a.id).isEmpty)
    let counts = try store.counts(kind: .scan)
    #expect(counts[.done] == 1)
    #expect(await counter.count == 2)  // one initial call, one retry — never more
}

@Test func scannerCancelDuringBackoffFinishesQuickly() async throws {
    let store = try Store.inMemory()
    let people = (0..<3).map { Person(givenName: "P\($0)", familyName: "X") }
    try store.upsertPeople(people, channels: [])
    let counter = CallCounter()
    let probe = AlwaysChallengeProbe(counter: counter)
    let scanner = Scanner(store: store, probes: [probe], client: FakeHTTP(), concurrency: 1, challengeBackoff: .seconds(30))

    let start = ContinuousClock.now
    var finished = false
    for await p in await scanner.run(personIds: people.map(\.id)) {
        if p.waitingFor == "DuckDuckGo" {
            await scanner.cancel()
        }
        if p.finished { finished = true }
    }
    let elapsed = ContinuousClock.now - start

    #expect(finished)
    #expect(elapsed < .seconds(2))
}
