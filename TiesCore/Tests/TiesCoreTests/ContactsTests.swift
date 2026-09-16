import Testing
import Foundation
@testable import TiesCore

@Test func vcardParses() throws {
    let url = Bundle.module.url(forResource: "two", withExtension: "vcf", subdirectory: "Fixtures")!
    let contacts = try VCardImporter.parse(try Data(contentsOf: url))
    #expect(contacts.count == 2)
    #expect(contacts[0].givenName == "Sara")
    #expect(contacts[0].emails.first?.value == "sara@acme.com")
    #expect(contacts[0].urls.first?.value == "https://sara.dev")
    #expect(contacts[1].organization == "Beta Corp")
}

@Test func syncWritesPeopleAndChannels() throws {
    let store = try Store.inMemory()
    let url = Bundle.module.url(forResource: "two", withExtension: "vcf", subdirectory: "Fixtures")!
    let contacts = try VCardImporter.parse(try Data(contentsOf: url))
    let n = try ContactSync.sync(contacts, into: store)
    #expect(n == 2)
    let people = try store.allPeople()
    #expect(people.map(\.displayName) == ["Beta Corp", "Sara Ahmed"])
    let sara = people[1]
    let ch = try store.channels(personId: sara.id)
    #expect(ch.first { $0.kind == .phone }?.normalized == "+15550100100")
    #expect(ch.first { $0.kind == .email }?.normalized == "sara@acme.com")
}

@Test func sectionsGroupByLetter() {
    let names = ["Émile", "bob", "Alice", "123 Taxi", "Ali"]
    let s = ContactSectioner.sections(names, name: { $0 })
    #expect(s.map(\.letter) == ["A", "B", "E", "#"])
    #expect(s[0].items == ["Ali", "Alice"])
}
