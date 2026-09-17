import Testing
import Foundation
import GRDB
@testable import TiesCore

@Test func signalsRoundTripAndMerge() throws {
    let store = try Store.inMemory()
    let p = Person(givenName: "Sara", familyName: "Ahmed")
    try store.upsertPeople([p], channels: [])

    var s = LocalSignals(personId: p.id)
    s.aliases = ["Dr. Sara"]
    s.honorifics = ["dr"]
    s.honorificsAsWritten = ["دكتورة"]
    s.sources = ["messages"]
    s.interactions = 3
    try store.upsertSignals(s)

    let other = LocalSignals(personId: p.id, aliases: ["Sara A."], titles: ["Cardiologist"], interactions: 2, sources: ["mail"])
    try store.upsertSignals(s.merged(with: other))

    let got = try #require(try store.signals(personId: p.id))
    #expect(got.aliases == ["Dr. Sara", "Sara A."])
    #expect(got.honorifics == ["dr"])
    // The spelling survives the round trip next to the id, which is what the search seeds use.
    #expect(got.honorificsAsWritten == ["دكتورة"])
    #expect(got.titles == ["Cardiologist"])
    #expect(got.interactions == 5)
    #expect(Set(got.sources) == ["messages", "mail"])
    #expect(try store.signalsByPerson()[p.id]?.aliases == ["Dr. Sara", "Sara A."])
}

@Test func signalsFeedFTS() throws {
    let store = try Store.inMemory()
    let p = Person(givenName: "Sara", familyName: "Ahmed")
    try store.upsertPeople([p], channels: [])
    try store.upsertSignals(LocalSignals(personId: p.id, titles: ["Cardiologist"]))
    #expect(try store.ftsSearch("cardiologist").map(\.personId) == [p.id])
}

@Test func smartListsReplaceAndRead() throws {
    let store = try Store.inMemory()
    let a = SmartList(name: "Doctors", systemImage: "cross.case", personIds: ["p1"])
    let b = SmartList(name: "Riyadh", systemImage: "mappin", personIds: ["p2", "p3"])
    try store.replaceSmartLists([a, b])
    #expect(try store.smartLists().map(\.id).sorted() == [a.id, b.id].sorted())

    let c = SmartList(name: "Founders", systemImage: "briefcase", personIds: ["p4"])
    try store.replaceSmartLists([c])
    let got = try store.smartLists()
    #expect(got.count == 1)
    #expect(got[0].id == c.id)
    #expect(got[0].name == "Founders")
    #expect(got[0].personIds == ["p4"])
}

@Test func judgementUpsert() throws {
    let store = try Store.inMemory()
    let p = Person(givenName: "Tim", familyName: "Cook")
    try store.upsertPeople([p], channels: [])

    try store.upsertJudgement(Judgement(personId: p.id, candidateId: "c1", confidence: 0.4, reason: "weak", providerId: "apple"))
    try store.upsertJudgement(Judgement(personId: p.id, candidateId: "c2", confidence: 0.9, reason: "strong", providerId: "apple"))

    let got = try #require(try store.judgement(personId: p.id))
    #expect(got.candidateId == "c2")
    #expect(got.confidence == 0.9)
    #expect(got.reason == "strong")
    #expect(try store.judgementsByPerson().count == 1)
    #expect(try store.judgementsByPerson()[p.id]?.candidateId == "c2")
}

@Test func factSupportedDecodesWhenMissing() throws {
    let legacy = Data(#"{"text":"Founded Acme","sources":["https://a"]}"#.utf8)
    let fact = try JSONDecoder().decode(Fact.self, from: legacy)
    #expect(fact.text == "Founded Acme")
    #expect(fact.sources == ["https://a"])
    #expect(fact.supported == nil)

    let checked = try JSONDecoder().decode(Fact.self, from: Data(#"{"text":"t","sources":[],"supported":true}"#.utf8))
    #expect(checked.supported == true)
}

@Test func publicSafeStripsPrivateFields() {
    let s = LocalSignals(
        personId: "p1",
        aliases: ["Abu Omar"],
        titles: ["Cardiologist"],
        phones: ["+966501234567"],
        emails: ["sara@example.com"],
        location: "Riyadh",
        lastContact: Date(timeIntervalSince1970: 1_000_000),
        interactions: 12,
        sources: ["messages"]
    )
    let safe = s.publicSafe
    #expect(safe.phones.isEmpty)
    #expect(safe.emails.isEmpty)
    #expect(safe.lastContact == nil)
    #expect(safe.interactions == 0)
    #expect(safe.aliases == ["Abu Omar"])
    #expect(safe.titles == ["Cardiologist"])
    #expect(safe.location == "Riyadh")
    #expect(!safe.isEmpty)
    #expect(LocalSignals(personId: "p2").isEmpty)
}

@Test func migrationV2RunsOnAnExistingV1Database() throws {
    // The shipped 0.1 database is already on disk at v1; v2 has to add its tables to it
    // rather than only ever being seen by freshly created databases.
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("ties-migration-\(UUID().uuidString)", isDirectory: true)
        .appendingPathComponent("ties.sqlite")
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

    let v1 = try DatabaseQueue(path: url.path)
    try Migrations.migrator.migrate(v1, upTo: "v1")
    let p = Person(givenName: "Sara", familyName: "Ahmed")
    try v1.write { db in try p.insert(db) }
    try v1.close()

    let store = try Store.open(at: url)
    try store.upsertSignals(LocalSignals(personId: p.id, titles: ["Cardiologist"]))
    #expect(try store.signals(personId: p.id)?.titles == ["Cardiologist"])
    #expect(try store.smartLists().isEmpty)
    #expect(try store.judgement(personId: p.id) == nil)
    #expect(try store.ftsSearch("cardiologist").map(\.personId) == [p.id])
}
