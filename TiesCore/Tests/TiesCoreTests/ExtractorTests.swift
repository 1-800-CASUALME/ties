import Testing
import Foundation
@testable import TiesCore

@Test func extractorWritesProfilesAndSkipsEmpty() async throws {
    let store = try Store.inMemory()
    let a = Person(givenName: "Sara", familyName: "Ahmed"), b = Person(givenName: "Nobody", familyName: "Known")
    try store.upsertPeople([a, b], channels: [])
    let c = Candidate(personId: a.id, score: 9, status: .auto, primaryURL: "https://sara.dev")
    try store.replaceCandidates(personId: a.id, candidates: [c], evidence: [], pages: [SourcePage(candidateId: c.id, url: "https://sara.dev", title: "t", snippet: nil, bodyText: "Sara Ahmed leads growth at Acme.", kind: .page)])
    struct Fixed: AIProvider { let spec = ProviderCatalog.spec("custom")!
        func complete(system: String, user: String, schemaJSON: String, schemaName: String) async throws -> Data {
            Data(#"{"occupation":"Growth lead","canHelpWith":["growth"]}"#.utf8)
        }
        func validate() async throws {} }
    let ex = Extractor(store: store, provider: Fixed(), embedder: HashEmbedder())
    for await _ in await ex.run(personIds: [a.id, b.id]) {}
    #expect(try store.profile(personId: a.id)?.facts.occupation == "Growth lead")
    #expect(try store.profile(personId: a.id)?.embedding?.isEmpty == false)
    #expect(try store.profile(personId: b.id) == nil)
    #expect(try store.counts(kind: .extract)[.skipped] == 1)
    #expect(try store.ftsSearch("growth").first?.personId == a.id)
}

@Test func cosineAndHashEmbedder() async throws {
    let e = HashEmbedder()
    let a = try await e.embed("growth marketing saas"), b = try await e.embed("growth marketing"), c = try await e.embed("plumbing pipes")
    #expect(Vector.cosine(a, b) > Vector.cosine(a, c))
    #expect(abs(Vector.cosine(a, a) - 1) < 0.001)
}

// MARK: - Second concurrent run rejected (mirrors ScannerTests.secondRunWhileActiveIsRejected)

/// An `AIProvider` whose model call sleeps before returning, so a run stays active long
/// enough for a second `run(personIds:)` call to observe it as in progress.
struct SlowProvider: AIProvider {
    let spec = ProviderCatalog.spec("custom")!
    func complete(system: String, user: String, schemaJSON: String, schemaName: String) async throws -> Data {
        try await Task.sleep(for: .milliseconds(200))
        return Data("{}".utf8)
    }
    func validate() async throws {}
}

@Test func secondExtractorRunWhileActiveIsRejected() async throws {
    let store = try Store.inMemory()
    let people = (0..<3).map { Person(givenName: "P\($0)", familyName: "X", organization: "Acme") }
    try store.upsertPeople(people, channels: [])
    let extractor = Extractor(store: store, provider: SlowProvider(), embedder: HashEmbedder(), concurrency: 1)

    // The first run's continuation is set synchronously before `run(personIds:)` returns, so by
    // the time this call comes back, the extractor is definitely "active" — no sleep/race needed.
    let firstStream = await extractor.run(personIds: people.map(\.id))
    let firstTask = Task { for await _ in firstStream {} }

    let secondStream = await extractor.run(personIds: people.map(\.id))
    var secondEvents: [ScanProgress] = []
    for await p in secondStream { secondEvents.append(p) }

    #expect(secondEvents.count == 1)
    #expect(secondEvents.first?.finished == true)
    #expect(secondEvents.first?.waitingFor == "Another extraction is running")

    await extractor.cancel()
    await firstTask.value
}
