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

@Test func groupNamesThatReadLikeACompany() async throws {
    let store = try WhatsAppFixture.make()
    let signals = try await WhatsAppCollector(chatStorage: store).collect(for: sara(), since: nil)

    // "Clinic Team" names an organisation; her one-to-one chats are named after people.
    #expect(signals.companies == [WhatsAppFixture.groupName])
}

@Test func groupsAreFoundWithoutAMembershipTable() async throws {
    let store = try WhatsAppFixture.make(groupMembers: false)
    let signals = try await WhatsAppCollector(chatStorage: store).collect(for: sara(), since: nil)

    // ZWAGROUPMEMBER is empty, so the group is recognised only by the messages she wrote in it —
    // and everything it contributes still arrives.
    #expect(signals.honorifics == ["dr"])
    #expect(signals.aliases == ["Dr Sara A", "Sarita"])
    #expect(signals.companies == [WhatsAppFixture.groupName])
}

@Test func aSessionCopiesTheStoreOnce() async throws {
    let store = try WhatsAppFixture.make()

    let session = WhatsAppCollector(chatStorage: store)
    try await session.beginSession()
    _ = try await session.collect(for: sara(), since: nil)
    let second = try await session.collect(for: sara(), since: nil)
    #expect(session.snapshotsOpened == 1)
    #expect(second.aliases == ["Dr Sara A", "Sarita"])
    await session.endSession()

    let loose = WhatsAppCollector(chatStorage: store)
    _ = try await loose.collect(for: sara(), since: nil)
    _ = try await loose.collect(for: sara(), since: nil)
    #expect(loose.snapshotsOpened == 2)
}

@Test func beginningASessionOnAMissingStoreThrows() async {
    let missing = WhatsAppCollector(chatStorage: URL(fileURLWithPath: "/nonexistent/ChatStorage.sqlite"))
    await #expect(throws: SourceError.self) { try await missing.beginSession() }
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

// MARK: - Register sample (§7.4)

@Test func whatsAppRegisterSampleIsTheUsersOwnSideOfTheOneToOneChat() async throws {
    let store = try WhatsAppFixture.make()
    let sample = try await WhatsAppCollector(chatStorage: store).registerSample(for: sara(), limit: 3)

    // Newest first, the user's own messages only, and only from the chat with her.
    #expect(sample == WhatsAppFixture.expectedRegisterSample)
    // Never what she wrote, never what the user wrote to the group, never a blank line.
    #expect(!sample.contains("here is my site https://sara-ahmed.com"))
    #expect(!sample.contains(WhatsAppFixture.ownGroupMessage))
    #expect(!sample.contains(""))
    // One long message is cut rather than dropped.
    #expect(sample.allSatisfy { $0.count <= MessagesCollector.sampleLength })
    #expect(sample.last?.count == MessagesCollector.sampleLength)
}

@Test func whatsAppRegisterSampleRespectsItsLimit() async throws {
    let store = try WhatsAppFixture.make()
    let c = WhatsAppCollector(chatStorage: store)

    #expect(try await c.registerSample(for: sara(), limit: 1) == Array(WhatsAppFixture.expectedRegisterSample.prefix(1)))
    #expect(try await c.registerSample(for: sara(), limit: 0).isEmpty)
    // Beyond the recent lines there is nothing but ancient filler, so the default 20 is filled
    // out with it rather than reaching past this chat.
    let twenty = try await c.registerSample(for: sara())
    #expect(twenty.count == 20)
    #expect(Array(twenty.prefix(3)) == WhatsAppFixture.expectedRegisterSample)
    #expect(twenty.dropFirst(3).allSatisfy { $0 == "ok" })
}

@Test func whatsAppRegisterSampleReusesTheRunsSnapshot() async throws {
    let store = try WhatsAppFixture.make()
    let session = WhatsAppCollector(chatStorage: store)
    try await session.beginSession()
    _ = try await session.collect(for: sara(), since: nil)
    #expect(try await session.registerSample(for: sara(), limit: 3) == WhatsAppFixture.expectedRegisterSample)
    #expect(session.snapshotsOpened == 1)
    await session.endSession()
}

@Test func whatsAppRegisterSampleIsEmptyWithoutAPhone() async throws {
    let store = try WhatsAppFixture.make()
    let c = WhatsAppCollector(chatStorage: store)

    #expect(try await c.registerSample(for: input(name: ("Sara", "Ahmed"))).isEmpty)
    // A number WhatsApp has never seen has no chat to sample.
    #expect(try await c.registerSample(for: input(name: ("Sara", "Ahmed"), phones: ["+15550100100"])).isEmpty)
}

@Test func whatsAppRegisterSampleFromAnUnavailableSourceYieldsNothing() async {
    let missing = WhatsAppCollector(chatStorage: URL(fileURLWithPath: "/nonexistent/ChatStorage.sqlite"))

    // Same `status()`-first rule as `collect`: the caller is told why, and a caller that only
    // wants a sample (`try?`) is left with nothing and drafts in a neutral register.
    await #expect(throws: SourceError.self) { _ = try await missing.registerSample(for: sara()) }
    #expect((try? await missing.registerSample(for: sara())) ?? [] == [])
}
