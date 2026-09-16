import Testing
import Foundation
@testable import TiesCore

@Test func rrfPrefersItemsInBothLists() {
    let r = RankFusion.rrf([["a", "b", "c"], ["c", "a", "d"]])
    #expect(r.first?.id == "a"); #expect(r.map(\.id).contains("d"))
}

@Test func askRanksRelevantPeople() async throws {
    let store = try Store.inMemory(); let e = HashEmbedder()
    let sara = Person(givenName: "Sara", familyName: "Ahmed"), bob = Person(givenName: "Bob", familyName: "Ray")
    try store.upsertPeople([sara, bob], channels: [])
    for (p, facts) in [(sara, ProfileFacts(occupation: "Head of Growth", canHelpWith: ["b2b saas growth", "hiring"])), (bob, ProfileFacts(occupation: "Plumber", canHelpWith: ["pipes"]))] {
        try store.upsertProfile(Profile(personId: p.id, facts: facts, confidence: 1, providerId: "x", model: nil, extractedAt: .now, embedding: try await e.embed(facts.searchableText)))
    }
    let s = SearchService(store: store, embedder: e)
    let r = try await s.ask("who can help with saas growth")
    #expect(r.first?.personId == sara.id)
    #expect(r.first?.why.lowercased().contains("growth") == true)
    #expect(try s.filter("bo").map(\.id) == [bob.id])
}

@Test func askStripsLeadingQuestionMark() async throws {
    let store = try Store.inMemory(); let e = HashEmbedder()
    let sara = Person(givenName: "Sara", familyName: "Ahmed"), bob = Person(givenName: "Bob", familyName: "Ray")
    try store.upsertPeople([sara, bob], channels: [])
    for (p, facts) in [(sara, ProfileFacts(occupation: "Head of Growth", canHelpWith: ["b2b saas growth", "hiring"])), (bob, ProfileFacts(occupation: "Plumber", canHelpWith: ["pipes"]))] {
        try store.upsertProfile(Profile(personId: p.id, facts: facts, confidence: 1, providerId: "x", model: nil, extractedAt: .now, embedding: try await e.embed(facts.searchableText)))
    }
    let s = SearchService(store: store, embedder: e)
    let plain = try await s.ask("who can help with saas growth")
    let withMark = try await s.ask("?  who can help with saas growth")
    #expect(withMark.map(\.personId) == plain.map(\.personId))
    #expect(withMark.map(\.why) == plain.map(\.why))
}

@Test func stopWordOnlyQueryFallsBackToOccupation() async throws {
    let store = try Store.inMemory(); let e = HashEmbedder()
    let sara = Person(givenName: "Sara", familyName: "Ahmed")
    try store.upsertPeople([sara], channels: [])
    // "and" is the only query token below, and it's a stop word, so `why`-line matching should
    // never engage even though "and" literally appears (and would FTS-match) in the occupation.
    let facts = ProfileFacts(occupation: "Growth and Sales Lead", canHelpWith: ["b2b saas growth"])
    try store.upsertProfile(Profile(personId: sara.id, facts: facts, confidence: 1, providerId: "x", model: nil, extractedAt: .now, embedding: try await e.embed(facts.searchableText)))
    let s = SearchService(store: store, embedder: e)
    let r = try await s.ask("and")
    #expect(r.first?.personId == sara.id)
    #expect(r.first?.why == facts.occupation)
}
