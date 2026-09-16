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
