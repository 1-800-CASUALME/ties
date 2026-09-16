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

@Test func reimportingSameVCardDoesNotDuplicate() throws {
    let store = try Store.inMemory()
    let url = Bundle.module.url(forResource: "two", withExtension: "vcf", subdirectory: "Fixtures")!
    let data = try Data(contentsOf: url)

    let first = try VCardImporter.parse(data)
    let second = try VCardImporter.parse(data)
    #expect(first.map(\.identifier) == second.map(\.identifier))

    _ = try ContactSync.sync(first, into: store)
    _ = try ContactSync.sync(second, into: store)
    #expect(try store.allPeople().count == 2)
}

// MARK: - Contacts extras (nickname, note, postal address)

/// The person the extras tests are about: a nickname, a hand-written note, and an address.
private func saraWithExtras(
    nickname: String? = "Sarita",
    note: String? = "Met at the clinic. Dr. Sara — everyone calls her Sarita. https://www.linkedin.com/in/sara-ahmed/",
    city: String? = "Riyadh",
    country: String? = "Saudi Arabia"
) -> ImportedContact {
    ImportedContact(
        identifier: "cn:sara",
        givenName: "Sara",
        familyName: "Ahmed",
        nickname: nickname,
        note: note,
        phones: [LabeledValue(label: "Mobile", value: "+966501234567")],
        postalCity: city,
        postalCountry: country
    )
}

@Test func contactExtrasBecomeSignals() throws {
    let store = try Store.inMemory()
    _ = try ContactSync.sync([saraWithExtras()], into: store)

    let sara = try #require(try store.allPeople().first)
    let signals = try #require(try store.signals(personId: sara.id))

    #expect(signals.aliases == ["Sarita"])
    #expect(signals.honorifics == ["dr"])
    #expect(signals.links == ["https://linkedin.com/in/sara-ahmed"])
    #expect(signals.location == "Riyadh, Saudi Arabia")
    #expect(signals.sources == ["contacts"])
    // Contacts says nothing about how often you two talk.
    #expect(signals.interactions == 0)
    #expect(signals.lastContact == nil)
}

@Test func aNicknameThatIsJustTheNameIsNotAnAlias() throws {
    let store = try Store.inMemory()
    _ = try ContactSync.sync([saraWithExtras(nickname: "Sara Ahmed", note: nil)], into: store)

    let sara = try #require(try store.allPeople().first)
    let signals = try #require(try store.signals(personId: sara.id))
    #expect(signals.aliases.isEmpty)
    #expect(signals.location == "Riyadh, Saudi Arabia")
}

@Test func aContactWithNoExtrasWritesNoSignalsRow() throws {
    let store = try Store.inMemory()
    _ = try ContactSync.sync(
        [saraWithExtras(nickname: nil, note: nil, city: nil, country: nil)],
        into: store
    )

    let sara = try #require(try store.allPeople().first)
    #expect(try store.signals(personId: sara.id) == nil)
}

@Test func syncingAgainKeepsWhatOtherSourcesCollected() throws {
    let store = try Store.inMemory()
    _ = try ContactSync.sync([saraWithExtras()], into: store)
    let sara = try #require(try store.allPeople().first)

    // A collection pass has since added what the chats know.
    var collected = try #require(try store.signals(personId: sara.id))
    collected.aliases.append("Abu Khalid")
    collected.interactions = 12
    collected.sources.append("messages")
    try store.upsertSignals(collected)

    _ = try ContactSync.sync([saraWithExtras(city: "Jeddah")], into: store)

    let merged = try #require(try store.signals(personId: sara.id))
    #expect(merged.aliases == ["Sarita", "Abu Khalid"])
    #expect(merged.interactions == 12)
    #expect(merged.sources.contains("messages"))
    // The address book is the authority on where the person is, so a move is picked up.
    #expect(merged.location == "Jeddah, Saudi Arabia")
}

@Test func contactsCollectorReadsBackWhatTheSyncStored() async throws {
    let store = try Store.inMemory()
    _ = try ContactSync.sync([saraWithExtras()], into: store)
    let sara = try #require(try store.allPeople().first)

    let collector = ContactsCollector(store: store)
    #expect(collector.id == "contacts")
    #expect(collector.displayName == "Contacts")
    #expect(collector.status() == .ready)

    let signals = try await collector.collect(
        for: ProbeInput(person: sara, channels: try store.channels(personId: sara.id)),
        since: nil
    )
    #expect(signals.aliases == ["Sarita"])
    #expect(signals.honorifics == ["dr"])
    #expect(signals.links == ["https://linkedin.com/in/sara-ahmed"])
    #expect(signals.location == "Riyadh, Saudi Arabia")
    #expect(signals.sources == ["contacts"])
    // Never the relationship: those counts belong to the chat and mail collectors, and adding
    // them again would double every person's history on each pass.
    #expect(signals.interactions == 0)
    #expect(signals.lastContact == nil)
    #expect(signals.phones.isEmpty)

    // Someone with nothing stored collects nothing rather than failing.
    let stranger = Person(givenName: "No", familyName: "One")
    let empty = try await collector.collect(for: ProbeInput(person: stranger, channels: []), since: nil)
    #expect(empty.isEmpty)
    #expect(empty.sources.isEmpty)
}

@Test func sectionsGroupByLetter() {
    let names = ["Émile", "bob", "Alice", "123 Taxi", "Ali"]
    let s = ContactSectioner.sections(names, name: { $0 })
    #expect(s.map(\.letter) == ["A", "B", "E", "#"])
    #expect(s[0].items == ["Ali", "Alice"])
}
