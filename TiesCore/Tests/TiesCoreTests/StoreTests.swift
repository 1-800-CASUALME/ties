import Testing
import Foundation
@testable import TiesCore

private func makeStore() throws -> Store { try Store.inMemory() }

@Test func upsertPeopleReplacesByCNIdentifier() throws {
    let s = try makeStore()
    let p = Person(cnIdentifier: "cn1", givenName: "Sara", familyName: "Ahmed", organization: "Acme")
    try s.upsertPeople([p], channels: [Channel(personId: p.id, kind: .email, label: "work", value: "Sara@Acme.com", normalized: "sara@acme.com")])
    var p2 = p; p2.id = UUID().uuidString; p2.organization = "Beta"
    try s.upsertPeople([p2], channels: [Channel(personId: p2.id, kind: .phone, label: nil, value: "+1 555 0100", normalized: "+15550100")])
    let all = try s.allPeople()
    #expect(all.count == 1)
    #expect(all[0].organization == "Beta")
    let ch = try s.channels(personId: all[0].id)
    #expect(ch.count == 1)
    #expect(ch[0].kind == .phone)
}

@Test func searchByNameOrDigits() throws {
    let s = try makeStore()
    let a = Person(givenName: "Zoë", familyName: "Ali")
    let b = Person(givenName: "Bob", familyName: "Ray")
    try s.upsertPeople([a, b], channels: [Channel(personId: b.id, kind: .phone, label: nil, value: "+966 50 123 4567", normalized: "+966501234567")])
    #expect(try s.people(matchingNameOrDigits: "zoe").map(\.id) == [a.id])
    #expect(try s.people(matchingNameOrDigits: "1234").map(\.id) == [b.id])
    #expect(try s.people(matchingNameOrDigits: "").count == 2)
}

@Test func candidatesAcceptRejectsOthers() throws {
    let s = try makeStore()
    let p = Person(givenName: "Tim", familyName: "Cook")
    try s.upsertPeople([p], channels: [])
    let c1 = Candidate(personId: p.id, score: 3, status: .pending, displayName: "Tim Cook", primaryURL: "https://a")
    let c2 = Candidate(personId: p.id, score: 2.5, status: .pending, displayName: "Tim Cook", primaryURL: "https://b")
    try s.replaceCandidates(personId: p.id, candidates: [c1, c2],
        evidence: [Evidence(candidateId: c1.id, kind: .company, weight: 3, detail: "Works at Apple")],
        pages: [SourcePage(candidateId: c1.id, url: "https://a", title: "t", snippet: "s", kind: .serp)])
    try s.setCandidateStatus(id: c2.id, status: .accepted)
    let cs = try s.candidates(personId: p.id)
    #expect(cs.first { $0.id == c1.id }?.status == .rejected)
    #expect(try s.bestCandidate(personId: p.id)?.id == c2.id)
    #expect(try s.pagesForAccepted(personId: p.id).isEmpty)   // c1's page is rejected now
    #expect(try s.evidence(candidateId: c1.id).count == 1)
}

@Test func profileFTSAndNotes() throws {
    let s = try makeStore()
    let p = Person(givenName: "Sara", familyName: "Ahmed")
    try s.upsertPeople([p], channels: [])
    try s.upsertProfile(Profile(personId: p.id, facts: ProfileFacts(occupation: "Growth lead", canHelpWith: ["B2B SaaS"]),
                                confidence: 0.9, providerId: "apple", model: nil, extractedAt: .now, embedding: [0.1, 0.2]))
    #expect(try s.ftsSearch("growth").map(\.personId) == [p.id])
    #expect(try s.ftsSearch("saas").map(\.personId) == [p.id])
    #expect(try s.ftsSearch("plumbing").isEmpty)
    try s.upsertNote(Note(personId: p.id, body: "Met at plumbing conference", updatedAt: .now))
    #expect(try s.ftsSearch("plumbing").map(\.personId) == [p.id])
    #expect(try s.allEmbeddings().first?.vector == [0.1, 0.2])
    try s.deletePerson(id: p.id)
    #expect(try s.profile(personId: p.id) == nil)
    #expect(try s.ftsSearch("growth").isEmpty)
}

@Test func jobsLifecycle() throws {
    let s = try makeStore()
    try s.enqueue(kind: .scan, personIds: ["a", "b"])
    try s.setJob(kind: .scan, personId: "a", state: .done)
    try s.setJob(kind: .scan, personId: "b", state: .failed, error: "boom")
    let counts = try s.counts(kind: .scan)
    #expect(counts[.done] == 1)
    #expect(counts[.failed] == 1)
    try s.enqueue(kind: .scan, personIds: ["a"])
    #expect(try s.jobs(kind: .scan).first { $0.personId == "a" }?.state == .queued)
}
