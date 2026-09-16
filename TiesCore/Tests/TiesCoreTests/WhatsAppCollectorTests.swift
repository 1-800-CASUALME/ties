import Testing
import Foundation
@testable import TiesCore

/// A `ProbeInput` for the fixture's Sara Ahmed, addressed by the phone WhatsApp knows her by.
private func sara() -> ProbeInput {
    input(name: ("Sara", "Ahmed"), phones: [WhatsAppFixture.saraPhone])
}

@Test func pushNameBecomesAlias() async throws {
    let store = try WhatsAppFixture.make()
    let signals = try await WhatsAppCollector(chatStorage: store).collect(for: sara(), since: nil)

    // "Dr Sara A" is what she calls herself; "Sarita" is what the group calls her.
    #expect(signals.aliases == ["Dr Sara A", "Sarita"])
    #expect(signals.sources == ["whatsapp"])
}

@Test func pushNameEqualToTheContactNameIsNotAnAlias() async throws {
    let store = try WhatsAppFixture.make(pushName: "Sara Ahmed")
    let signals = try await WhatsAppCollector(chatStorage: store).collect(for: sara(), since: nil)

    #expect(signals.aliases == ["Sarita"])
}

@Test func groupMembersHonorifics() async throws {
    let store = try WhatsAppFixture.make()
    let signals = try await WhatsAppCollector(chatStorage: store).collect(for: sara(), since: nil)

    // "dr" comes from another member of her group. "prof" was the user's own message, "capt"
    // was hers, and the "Prof. Sara" in Omar's private chat is in a session she is not in.
    #expect(signals.honorifics == ["dr"])
}

@Test func linksFromOwnMessages() async throws {
    let store = try WhatsAppFixture.make()
    let signals = try await WhatsAppCollector(chatStorage: store).collect(for: sara(), since: nil)

    // Her group message (matched by ZFROMJID) and her side of the one-to-one chat (matched by
    // ZISFROMME == 0) — never the link the user sent her.
    #expect(signals.links == ["https://linkedin.com/in/sara-ahmed", "https://sara-ahmed.com"])
}

@Test func countsInteractionsAndLastContact() async throws {
    let now = Date.now
    let store = try WhatsAppFixture.make(now: now)
    let signals = try await WhatsAppCollector(chatStorage: store).collect(for: sara(), since: nil)

    #expect(signals.interactions == WhatsAppFixture.expectedInteractions)
    let expected = now.addingTimeInterval(-WhatsAppFixture.lastContactDaysAgo * 86_400)
    let last = try #require(signals.lastContact)
    #expect(abs(last.timeIntervalSince(expected)) < 1)
}

@Test func collectsNothingForAPersonWithoutAPhone() async throws {
    let store = try WhatsAppFixture.make()
    let signals = try await WhatsAppCollector(chatStorage: store)
        .collect(for: input(name: ("Sara", "Ahmed")), since: nil)

    #expect(signals.isEmpty)
    #expect(signals.sources.isEmpty)
    #expect(signals.interactions == 0)
}

@Test func statusUnavailableWhenMissing() throws {
    let missing = WhatsAppCollector(chatStorage: URL(fileURLWithPath: "/nonexistent/ChatStorage.sqlite"))
    #expect(missing.status() == .unavailable)
    #expect(missing.id == "whatsapp")
    #expect(missing.displayName == "WhatsApp")

    let store = try WhatsAppFixture.make()
    #expect(WhatsAppCollector(chatStorage: store).status() == .ready)
}

@Test func collectThrowsWhenTheStoreIsMissing() async {
    let missing = WhatsAppCollector(chatStorage: URL(fileURLWithPath: "/nonexistent/ChatStorage.sqlite"))
    await #expect(throws: SourceError.self) {
        _ = try await missing.collect(for: sara(), since: nil)
    }
}

@Test func jidForPhoneDropsEverythingButDigits() {
    #expect(WhatsAppCollector.jid(forPhone: "+966 50 123 4567") == "966501234567@s.whatsapp.net")
    #expect(WhatsAppCollector.jid(forPhone: "not a number") == nil)
}
