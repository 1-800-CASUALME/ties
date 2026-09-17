import Foundation
import Testing
@testable import TiesCore

// MARK: - The little path language

@Test func jsonPathWalksObjectsAndFansOutArrays() throws {
    let json = try JSONSerialization.jsonObject(with: Data("""
    {"result": {"tags": [{"tag": "Dr Sara", "count": 12}, {"tag": "Sara Clinic", "count": 3}]}}
    """.utf8))

    let nodes = JSONPath.nodes("result.tags[]", in: json)
    #expect(nodes.count == 2)
    #expect(JSONPath.string(nodes[0], field: "tag") == "Dr Sara")
    #expect(JSONPath.int(nodes[0], field: "count") == 12)
    #expect(JSONPath.string(nodes[1], field: "tag") == "Sara Clinic")
}

@Test func jsonPathFansOutATopLevelArrayAndReadsBareStrings() throws {
    let json = try JSONSerialization.jsonObject(with: Data(#"["Doctor", "  ", "Cardiologist"]"#.utf8))
    let names = JSONPath.nodes("[]", in: json).compactMap { JSONPath.string($0, field: nil) }
    #expect(names == ["Doctor", "Cardiologist"])
}

@Test func jsonPathIgnoresNumbersAndMissingKeys() throws {
    let json = try JSONSerialization.jsonObject(with: Data(#"{"a": {"b": 7, "c": null}}"#.utf8))
    #expect(JSONPath.string(JSONPath.nodes("a", in: json)[0], field: "b") == nil)
    #expect(JSONPath.nodes("a.c", in: json).isEmpty)
    #expect(JSONPath.nodes("a.missing.deeper", in: json).isEmpty)
}

// MARK: - A service Ties knows nothing about

/// The shape a "what do other people save this number as" service answers in: labels with a
/// count of how many people used each one.
private let crowdConfig = CustomLookupConfig(
    urlTemplate: "https://lookup.example/v1/numbers/{phone_plain}",
    headerName: "Authorization",
    headerTemplate: "Bearer {key}",
    namesPath: "result.tags[]",
    nameField: "tag",
    countField: "count",
    tagsPath: "result.labels[]",
    namesAreCrowd: true
)

private let crowdAnswer = Data("""
{"result": {"tags": [{"tag": "Sara Ahmed", "count": 4}, {"tag": "Dr Sara", "count": 31}],
            "labels": ["Cardiologist"]}}
""".utf8)

@Test func customProviderReadsNamesTagsAndOrdersByHowManyPeopleAgree() async throws {
    let http = FakeHTTP()
    http.routes = [(contains: "lookup.example", status: 200, body: crowdAnswer)]
    let provider = CustomLookupProvider(config: crowdConfig, key: "secret-key", client: http)

    let result = try await provider.lookup(LookupQuery(phoneE164: "+966501234567"))

    #expect(result?.names.map(\.value) == ["Dr Sara", "Sara Ahmed"])
    #expect(result?.names.allSatisfy { $0.kind == .crowd } == true)
    #expect(result?.names.first?.count == 31)
    #expect(result?.tags == ["Cardiologist"])
    // The number went in as digits, and the key went in the header the user named — never in
    // the URL, where it would end up in every log between here and the service.
    #expect(http.requested == ["https://lookup.example/v1/numbers/966501234567"])
    #expect(http.sentHeaders.first?["Authorization"] == "Bearer secret-key")
}

@Test func customProviderTreatsNotFoundAsAnAnswerAndRefusalAsAnError() async throws {
    let http = FakeHTTP()
    http.scripted = [(status: 404, body: Data())]
    let provider = CustomLookupProvider(config: crowdConfig, key: "k", client: http)
    #expect(try await provider.lookup(LookupQuery(phoneE164: "+15551234567")) == nil)

    http.scripted = [(status: 401, body: Data())]
    await #expect(throws: LookupError.unauthorized) {
        try await provider.lookup(LookupQuery(phoneE164: "+15551234567"))
    }
}

@Test func customProviderRefusesATemplateThatAsksAboutNobody() async throws {
    let http = FakeHTTP()
    var config = crowdConfig
    config.urlTemplate = "https://lookup.example/v1/numbers"
    let provider = CustomLookupProvider(config: config, key: "k", client: http)

    await #expect(throws: LookupError.notConfigured) {
        try await provider.lookup(LookupQuery(phoneE164: "+15551234567"))
    }
    #expect(http.requested.isEmpty)
}

@Test func aHalfFilledConfigurationReadsNoNames() {
    let provider = CustomLookupProvider(config: CustomLookupConfig(), key: nil, client: FakeHTTP())
    let result = provider.parse(["anything": "at all"])
    #expect(result.isEmpty)
}

@Test func urlTemplateEncodesTheCharactersThatWouldBecomeSyntax() {
    let filled = LookupCatalog.fill(
        "https://x.test/?n={phone}&q={name}",
        with: LookupQuery(phoneE164: "+966501234567", name: "Sara & Co")
    )
    #expect(filled == "https://x.test/?n=%2B966501234567&q=Sara%20%26%20Co")
    #expect(URL(string: filled) != nil)
}

// MARK: - Twilio

private let twilioAnswer = Data("""
{"phone_number": "+15551234567", "valid": true,
 "caller_name": {"caller_name": "SARA AHMED", "caller_type": "CONSUMER", "error_code": null},
 "line_type_intelligence": {"carrier_name": "Verizon", "type": "mobile", "error_code": null}}
""".utf8)

@Test func twilioReadsTheRegisteredNameCarrierAndLineType() async throws {
    let http = FakeHTTP()
    http.routes = [(contains: "lookups.twilio.com", status: 200, body: twilioAnswer)]
    let provider = TwilioLookupProvider(accountSID: "AC123", authToken: "tok", client: http)

    let result = try await provider.lookup(LookupQuery(phoneE164: "+15551234567", name: "Sara Ahmed"))

    #expect(result?.names == [LookupName(value: "SARA AHMED", kind: .registered)])
    #expect(result?.carrier == "Verizon")
    #expect(result?.lineType == "mobile")
    #expect(http.requested.first?.contains("Fields=caller_name,line_type_intelligence") == true)
    #expect(http.sentHeaders.first?["Authorization"] == "Basic \(Data("AC123:tok".utf8).base64EncodedString())")
    // A cached answer about a phone number is a stale answer that was still paid for once.
    #expect(http.bypassedCache == [true])
}

@Test func twilioSaysNothingRatherThanNothingAtAllWhenTheNameIsMissing() async throws {
    let http = FakeHTTP()
    http.routes = [(contains: "lookups.twilio.com", status: 200, body: Data("""
    {"caller_name": {"caller_name": null}, "line_type_intelligence": {"type": "landline"}}
    """.utf8))]
    let provider = TwilioLookupProvider(accountSID: "AC1", authToken: "t", client: http)

    let result = try await provider.lookup(LookupQuery(phoneE164: "+15551234567"))
    #expect(result?.names.isEmpty == true)
    #expect(result?.lineType == "landline")
}

@Test func twilioIsNotAskedAboutAnEmailAddress() async throws {
    let http = FakeHTTP()
    let provider = TwilioLookupProvider(accountSID: "AC1", authToken: "t", client: http)
    #expect(try await provider.lookup(LookupQuery(email: "sara@example.com")) == nil)
    #expect(http.requested.isEmpty)
}

// MARK: - The budget

@Test func theBudgetCapsAPassAndRemembersWhatItAlreadyAsked() async {
    let budget = LookupBudget(limit: 2)
    #expect(await budget.take())
    await budget.store("+1", LookupResult(names: [LookupName(value: "A", kind: .crowd)], providerId: "x"))
    #expect(await budget.take())
    await budget.store("+2", nil)
    #expect(await budget.take() == false)

    if case .known(let cached) = await budget.cached("+1") {
        #expect(cached?.names.first?.value == "A")
    } else {
        Issue.record("the first number should be remembered")
    }
    if case .known(let cached) = await budget.cached("+2") {
        #expect(cached == nil)
    } else {
        Issue.record("a number the service had nothing on should be remembered too")
    }
    if case .unknown = await budget.cached("+3") {} else {
        Issue.record("a number nobody asked about is unknown")
    }
}

@Test func haltingStopsTheBudgetEvenWithCallsLeft() async {
    let budget = LookupBudget(limit: 10)
    await budget.halt()
    #expect(await budget.take() == false)
    #expect(await budget.isHalted)
}

// MARK: - The collector

/// A provider that answers from a script and counts how many times it was asked.
private final class CountingProvider: LookupProvider, @unchecked Sendable {
    let id = "counting"
    var answer: LookupResult?
    var error: LookupError?
    private(set) var calls: [String] = []
    private let lock = NSLock()

    init(answer: LookupResult? = nil, error: LookupError? = nil) {
        self.answer = answer
        self.error = error
    }

    func lookup(_ query: LookupQuery) async throws -> LookupResult? {
        // `NSLock` is `noasync`, so the bookkeeping happens in a plain synchronous helper —
        // the same shape `FakeHTTP` uses.
        record(query.phoneE164 ?? query.email ?? "")
        if let error { throw error }
        return answer
    }

    private func record(_ call: String) {
        lock.lock()
        calls.append(call)
        lock.unlock()
    }
}

@Test func aRegisteredNameIsStrongAndACrowdNameIsOnlyAnAlias() async throws {
    let provider = CountingProvider(answer: LookupResult(
        names: [
            LookupName(value: "Sara Ahmed", kind: .registered),
            LookupName(value: "Dr Sara", kind: .crowd, count: 31),
        ],
        tags: ["Cardiologist", "Dr."],
        providerId: "counting"
    ))
    let collector = LookupCollector(provider: provider, budget: LookupBudget(limit: 10))

    let signals = try await collector.collect(
        for: input(name: ("Sara", "Ahmed"), phones: ["+966501234567"]),
        since: nil
    )

    #expect(signals.aliases.contains("Sara Ahmed"))
    #expect(signals.aliases.contains("Dr Sara"))
    #expect(signals.strongAliases == ["Sara Ahmed"])
    // "Dr Sara" and the bare "Dr." are the same honorific said twice, kept once.
    #expect(signals.honorifics == ["dr"])
    #expect(signals.titles == ["Cardiologist"])
    #expect(signals.sources == ["lookup"])
}

@Test func theSameNumberIsPaidForOnceHoweverManyContactsShareIt() async throws {
    let provider = CountingProvider(answer: LookupResult(
        names: [LookupName(value: "Reception", kind: .crowd)], providerId: "counting"
    ))
    let budget = LookupBudget(limit: 10)
    let collector = LookupCollector(provider: provider, budget: budget)

    _ = try await collector.collect(for: input(name: ("Sara", "Ahmed"), phones: ["+966501234567"]), since: nil)
    let second = try await collector.collect(for: input(name: ("Omar", "Ali"), phones: ["+966501234567"]), since: nil)

    #expect(provider.calls == ["+966501234567"])
    #expect(second.aliases == ["Reception"])
    #expect(await budget.remainingCount == 9)
}

@Test func aPersonIsAskedAboutAtMostTwoOfTheirNumbers() async throws {
    let provider = CountingProvider(answer: nil)
    let collector = LookupCollector(provider: provider, budget: LookupBudget(limit: 10))

    _ = try await collector.collect(
        for: input(name: ("Sara", "Ahmed"), phones: ["+9661", "+9662", "+9663", "+9664"]),
        since: nil
    )

    #expect(provider.calls == ["+9661", "+9662"])
}

@Test func aRefusedKeyHaltsThePassRatherThanBeingRefusedOncePerPerson() async throws {
    let provider = CountingProvider(error: .unauthorized)
    let budget = LookupBudget(limit: 100)
    let collector = LookupCollector(provider: provider, budget: budget)

    await #expect(throws: SourceError.self) {
        try await collector.collect(for: input(name: ("Sara", "Ahmed"), phones: ["+9661"]), since: nil)
    }
    #expect(await budget.isHalted)

    await #expect(throws: SourceError.self) {
        try await collector.collect(for: input(name: ("Omar", "Ali"), phones: ["+9662"]), since: nil)
    }
    // The second person cost nothing: the pass was already halted before the call.
    #expect(provider.calls == ["+9661"])
}

@Test func oneUnanswerableNumberDoesNotFailThePerson() async throws {
    let provider = CountingProvider(error: .http(500))
    let collector = LookupCollector(provider: provider, budget: LookupBudget(limit: 10))

    let signals = try await collector.collect(
        for: input(name: ("Sara", "Ahmed"), phones: ["+9661"]),
        since: nil
    )
    #expect(signals.isEmpty)
    // It was asked, so the row says the source ran and found nothing.
    #expect(signals.sources == ["lookup"])
}

@Test func withNoProviderTheSourceIsSimplyNotThere() async {
    let collector = LookupCollector(provider: nil, budget: LookupBudget(limit: 10))
    #expect(collector.status() == .unavailable)
    await #expect(throws: SourceError.self) {
        try await collector.collect(for: input(name: ("Sara", "Ahmed"), phones: ["+9661"]), since: nil)
    }
}

@Test func aPersonWithNoNumbersClaimsNoSource() async throws {
    let provider = CountingProvider(answer: nil)
    let collector = LookupCollector(provider: provider, budget: LookupBudget(limit: 10))

    let signals = try await collector.collect(for: input(name: ("Sara", "Ahmed")), since: nil)
    #expect(signals.sources.isEmpty)
    #expect(provider.calls.isEmpty)
}

@Test func aPresetMapsTheReplyAndStillHasNoEndpointToCall() throws {
    let spec = try #require(LookupCatalog.spec(LookupCatalog.getcontactId))
    let preset = try #require(spec.preset)

    #expect(spec.usesCustomEndpoint)
    // The half a preset can honestly fill in.
    #expect(preset.namesPath == "result.tags[]")
    #expect(preset.nameField == "tag")
    #expect(preset.countField == "count")
    #expect(preset.namesAreCrowd)
    // The half it must not: no endpoint ships, so nothing can be called until the user has
    // their own access.
    #expect(preset.urlTemplate.isEmpty)
    #expect(!preset.isUsable)

    // With a URL of the user's own, the preset reads a tag-shaped reply without another word
    // being typed.
    var configured = preset
    configured.urlTemplate = "https://their-own-access.example/v1/{phone_plain}"
    #expect(configured.isUsable)
    let provider = CustomLookupProvider(id: spec.id, config: configured, key: "k", client: FakeHTTP())
    let result = provider.parse(try JSONSerialization.jsonObject(with: crowdAnswer))
    #expect(result.names.map(\.value) == ["Dr Sara", "Sara Ahmed"])
    #expect(result.providerId == LookupCatalog.getcontactId)
}

@Test func everyCatalogueEntryHasAKeyFieldAndAnHonestLineAboutWhatItAnswers() {
    #expect(LookupCatalog.all.count >= 3)
    for spec in LookupCatalog.all {
        #expect(!spec.secretLabel.isEmpty)
        #expect(spec.coverage.count > 40)
        #expect(LookupCatalog.spec(spec.id)?.name == spec.name)
        #expect(LookupCatalog.secretAccount(spec.id).hasPrefix("lookup."))
    }
}

// MARK: - Inside a real pass

@Test func aLookupRunsInsideACollectionPassAndReachesTheStore() async throws {
    let store = try Store.inMemory()
    let sara = Person(givenName: "Sara", familyName: "Ahmed")
    let omar = Person(givenName: "Omar", familyName: "Ali")
    try store.upsertPeople([sara, omar], channels: [
        Channel(personId: sara.id, kind: .phone, value: "+966501234567", normalized: "+966501234567"),
        Channel(personId: omar.id, kind: .email, value: "omar@example.com", normalized: "omar@example.com"),
    ])

    let provider = CountingProvider(answer: LookupResult(
        names: [LookupName(value: "Dr Sara", kind: .crowd, count: 9)],
        tags: ["Cardiologist"],
        providerId: "counting"
    ))
    let collector = SignalCollector(
        store: store,
        collectors: [LookupCollector(provider: provider, budget: LookupBudget(limit: 50))]
    )

    for await _ in await collector.run(personIds: [sara.id, omar.id]) {}

    let rows = try store.signalsByPerson()
    #expect(rows[sara.id]?.aliases == ["Dr Sara"])
    #expect(rows[sara.id]?.honorifics == ["dr"])
    #expect(rows[sara.id]?.titles == ["Cardiologist"])
    #expect(rows[sara.id]?.sources == ["lookup"])
    // A crowd name never counts as strong, however many people agree on it.
    #expect(rows[sara.id]?.strongAliases.isEmpty == true)
    // Omar has no number, so nothing was asked about him and nothing was charged.
    #expect(rows[omar.id]?.aliases.isEmpty == true)
    #expect(provider.calls == ["+966501234567"])
    #expect(try store.counts(kind: .collect)[.done] == 2)
}
