import Testing
import Foundation
@testable import TiesCore

/// A `SourceCollector` that answers with fixed signals (or throws a fixed error), and counts the
/// session and collection calls the orchestrator makes on it.
private final class FakeCollector: SourceCollector, @unchecked Sendable {
    let id: String
    let displayName: String
    /// What `collect` returns, re-addressed to the person it is asked about.
    let template: LocalSignals
    let failure: SourceError?
    let delay: Duration?
    let reported: SourceStatus

    private let lock = NSLock()
    private var begun = 0
    private var ended = 0
    private var people: [String] = []

    var sessionsBegun: Int { lock.withLock { begun } }
    var sessionsEnded: Int { lock.withLock { ended } }
    var collectedFor: [String] { lock.withLock { people } }

    init(
        id: String,
        displayName: String,
        template: LocalSignals = LocalSignals(personId: ""),
        failure: SourceError? = nil,
        delay: Duration? = nil,
        status: SourceStatus = .ready
    ) {
        self.id = id
        self.displayName = displayName
        self.template = template
        self.failure = failure
        self.delay = delay
        self.reported = status
    }

    func status() -> SourceStatus { reported }

    func beginSession() async throws {
        lock.withLock { begun += 1 }
        if let failure { throw failure }
    }

    func endSession() async {
        lock.withLock { ended += 1 }
    }

    func collect(for input: ProbeInput, since: Date?) async throws -> LocalSignals {
        if let delay { try? await Task.sleep(for: delay) }
        lock.withLock { people.append(input.person.id) }
        if let failure { throw failure }
        var signals = template
        signals.personId = input.person.id
        signals.sources = [id]
        return signals
    }
}

private func messagesLike() -> FakeCollector {
    FakeCollector(
        id: "messages",
        displayName: "your chats",
        template: LocalSignals(personId: "", aliases: ["Sarita"], honorifics: ["dr"], interactions: 4)
    )
}

private func mailLike() -> FakeCollector {
    FakeCollector(
        id: "mail",
        displayName: "your mail",
        template: LocalSignals(personId: "", titles: ["Cardiologist"], companies: ["Acme"], interactions: 2)
    )
}

@Test func collectionMergesEverySourceIntoOneRow() async throws {
    let store = try Store.inMemory()
    let sara = Person(givenName: "Sara", familyName: "Ahmed")
    try store.upsertPeople([sara], channels: [])

    let chats = messagesLike()
    let mail = mailLike()
    let blocked = FakeCollector(
        id: "whatsapp", displayName: "WhatsApp", failure: .needsAccess, status: .needsAccess
    )
    let collector = SignalCollector(store: store, collectors: [chats, blocked, mail])

    var last: ScanProgress?
    for await progress in await collector.run(personIds: [sara.id]) { last = progress }

    #expect(last?.finished == true)
    #expect(last?.completed == 1)
    #expect(last?.total == 1)

    let signals = try #require(try store.signals(personId: sara.id))
    #expect(signals.aliases == ["Sarita"])
    #expect(signals.honorifics == ["dr"])
    #expect(signals.titles == ["Cardiologist"])
    #expect(signals.companies == ["Acme"])
    // The two sources' counts add up; the blocked one contributes nothing at all.
    #expect(signals.interactions == 6)
    #expect(signals.sources == ["messages", "mail"])

    // A source that cannot be read is written into the job's error, and the person is still done.
    let jobs = try store.jobs(kind: .collect)
    #expect(jobs.count == 1)
    #expect(jobs.first?.state == .done)
    let error = try #require(jobs.first?.error)
    #expect(error.contains("whatsapp: "))
    #expect(!error.contains("messages"))
}

@Test func aRebuiltRowDropsASourceThatWasSwitchedOff() async throws {
    let store = try Store.inMemory()
    let sara = Person(cnIdentifier: "cn:sara", givenName: "Sara", familyName: "Ahmed")
    try store.upsertPeople([sara], channels: [])
    try store.upsertContactsSignals(
        personId: sara.id,
        LocalSignals(personId: sara.id, aliases: ["Sarita"], location: "Riyadh", sources: ["contacts"])
    )

    let contacts = ContactsCollector(store: store)
    let chats = messagesLike()
    for await _ in await SignalCollector(store: store, collectors: [contacts, chats]).run(personIds: [sara.id]) {}

    let first = try #require(try store.signals(personId: sara.id))
    #expect(first.aliases == ["Sarita"])
    #expect(first.honorifics == ["dr"])
    #expect(first.interactions == 4)
    #expect(first.sources == ["contacts", "messages"])

    // Messages is switched off and the pass is run again.
    for await _ in await SignalCollector(store: store, collectors: [contacts]).run(personIds: [sara.id]) {}

    let second = try #require(try store.signals(personId: sara.id))
    // What the chats found is gone rather than carried forward under the Contacts name…
    #expect(second.honorifics.isEmpty)
    #expect(second.interactions == 0)
    #expect(second.sources == ["contacts"])
    // …and what the address book knows survived the rebuild.
    #expect(second.aliases == ["Sarita"])
    #expect(second.location == "Riyadh")
    #expect(try store.contactsSignals(personId: sara.id)?.aliases == ["Sarita"])
}

@Test func stagesAreStreamedInTheOrderTheCollectorsWereGiven() async throws {
    let store = try Store.inMemory()
    let sara = Person(givenName: "Sara", familyName: "Ahmed")
    try store.upsertPeople([sara], channels: [])

    let collector = SignalCollector(
        store: store,
        collectors: [
            messagesLike(),
            FakeCollector(id: "whatsapp", displayName: "WhatsApp"),
            mailLike(),
        ]
    )

    var stages: [String] = []
    var lastFinished: [String] = []
    var names: [String] = []
    for await progress in await collector.run(personIds: [sara.id]) {
        if let stage = progress.stage {
            stages.append(stage)
            lastFinished = progress.finishedStages
        }
        if let name = progress.currentName { names.append(name) }
    }

    #expect(stages == ["your chats", "WhatsApp", "your mail"])
    // Every stage event carries the ones already done, so the caption can list them.
    #expect(lastFinished == ["your chats", "WhatsApp"])
    #expect(names.allSatisfy { $0 == "Sara Ahmed" })
}

@Test func everySourceOpensOneSessionForTheWholeRun() async throws {
    let store = try Store.inMemory()
    let people = (0..<4).map { Person(givenName: "P\($0)", familyName: "X") }
    try store.upsertPeople(people, channels: [])

    let chats = messagesLike()
    let collector = SignalCollector(store: store, collectors: [chats], concurrency: 2)
    for await _ in await collector.run(personIds: people.map(\.id)) {}

    #expect(chats.sessionsBegun == 1)
    #expect(chats.sessionsEnded == 1)
    #expect(Set(chats.collectedFor) == Set(people.map(\.id)))
}

@Test func aSourceThatCannotOpenIsStillReportedPerPerson() async throws {
    let store = try Store.inMemory()
    let people = (0..<2).map { Person(givenName: "P\($0)", familyName: "X") }
    try store.upsertPeople(people, channels: [])

    let blocked = FakeCollector(
        id: "messages", displayName: "your chats", failure: .needsAccess, status: .needsAccess
    )
    let collector = SignalCollector(store: store, collectors: [blocked])
    for await _ in await collector.run(personIds: people.map(\.id)) {}

    // The session it could not open is closed all the same, and both people say why.
    #expect(blocked.sessionsEnded == 1)
    let jobs = try store.jobs(kind: .collect)
    #expect(jobs.count == 2)
    #expect(jobs.allSatisfy { $0.state == .done })
    #expect(jobs.allSatisfy { ($0.error ?? "").contains("messages: ") })
}

@Test func aPersonWhoIsNotThereFails() async throws {
    let store = try Store.inMemory()
    let collector = SignalCollector(store: store, collectors: [messagesLike()])
    for await _ in await collector.run(personIds: ["ghost"]) {}

    let jobs = try store.jobs(kind: .collect)
    #expect(jobs.first?.state == .failed)
    #expect(jobs.first?.error?.contains("ghost") == true)
}

@Test func collectionCancelStopsEarly() async throws {
    let store = try Store.inMemory()
    let people = (0..<20).map { Person(givenName: "P\($0)", familyName: "X") }
    try store.upsertPeople(people, channels: [])

    let slow = FakeCollector(id: "slow", displayName: "slowly", delay: .milliseconds(30))
    let collector = SignalCollector(store: store, collectors: [slow], concurrency: 1)

    var seen = 0
    for await progress in await collector.run(personIds: people.map(\.id)) {
        seen = max(seen, progress.completed)
        if seen == 2 { await collector.cancel() }
    }
    #expect(seen < 20)
    #expect(slow.sessionsEnded == 1)
}

@Test func secondCollectionWhileActiveIsRejected() async throws {
    let store = try Store.inMemory()
    let people = (0..<3).map { Person(givenName: "P\($0)", familyName: "X") }
    try store.upsertPeople(people, channels: [])

    let slow = FakeCollector(id: "slow", displayName: "slowly", delay: .milliseconds(200))
    let collector = SignalCollector(store: store, collectors: [slow], concurrency: 1)

    let firstStream = await collector.run(personIds: people.map(\.id))
    let firstTask = Task { for await _ in firstStream {} }

    var events: [ScanProgress] = []
    for await progress in await collector.run(personIds: people.map(\.id)) { events.append(progress) }

    #expect(events.count == 1)
    #expect(events.first?.finished == true)
    #expect(events.first?.waitingFor == SignalCollector.busyNotice)

    await collector.cancel()
    await firstTask.value
}

@Test func statusesAnswerForEverySource() async throws {
    let store = try Store.inMemory()
    let collector = SignalCollector(
        store: store,
        collectors: [
            FakeCollector(id: "messages", displayName: "your chats"),
            FakeCollector(id: "whatsapp", displayName: "WhatsApp", status: .needsAccess),
            FakeCollector(id: "mail", displayName: "your mail", status: .unavailable),
        ]
    )

    #expect(await collector.statuses() == [
        "messages": .ready,
        "whatsapp": .needsAccess,
        "mail": .unavailable,
    ])
}
