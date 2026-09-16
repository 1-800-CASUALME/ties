import Testing
import Foundation
@testable import TiesCore

@Test func chunkerRespectsBoundaries() {
    let text = (0..<50).map { "Sentence number \($0) is here." }.joined(separator: " ")
    let chunks = TextChunker.chunks(text, maxTokens: 30)   // ≈120 chars
    #expect(chunks.count > 5)
    #expect(chunks.allSatisfy { $0.count <= 130 && !$0.hasPrefix(" ") })
    #expect(chunks.joined(separator: " ").replacingOccurrences(of: "  ", with: " ") == text)
}

@Test func schemaDecodeIsTolerant() throws {
    let f = try ProfileFactsSchema.decode(Data("```json\n{\"occupation\":\"CTO\",\"companies\":[{\"text\":\"Acme\",\"sources\":[\"s1\"]}],\"canHelpWith\":[\"Cloud\"]}\n```".utf8))
    #expect(f.occupation == "CTO"); #expect(f.companies.first?.sources == ["s1"]); #expect(f.achievements.isEmpty)
}

@Test func mergerDedupes() {
    let a = ProfileFacts(occupation: "CTO", companies: [Fact(text: "Acme", sources: ["1"])], canHelpWith: ["Cloud", "hiring"])
    let b = ProfileFacts(occupation: nil, companies: [Fact(text: "ACME", sources: ["2"])], canHelpWith: ["cloud", "sales"])
    let m = FactsMerger.merge([a, b])
    #expect(m.occupation == "CTO"); #expect(m.companies.count == 1); #expect(m.companies[0].sources == ["1", "2"])
    #expect(m.canHelpWith == ["cloud", "hiring", "sales"])
}

@Test func openAIProviderSendsSchemaAndParses() async throws {
    let http = FakeHTTP()
    http.routes = [("chat/completions", 200, Data(#"{"choices":[{"message":{"content":"{\"occupation\":\"Baker\",\"companies\":[],\"achievements\":[],\"certificates\":[],\"experience\":[],\"canHelpWith\":[\"bread\"]}"}}]}"#.utf8))]
    let p = OpenAICompatibleProvider(spec: ProviderCatalog.spec("groq")!, baseURL: "https://api.groq.com/openai/v1", apiKey: "k", model: "m", client: http)
    let f = try await p.extractChunk(system: "s", user: "u")
    #expect(f.occupation == "Baker"); #expect(f.canHelpWith == ["bread"])
    #expect(http.requested.first == "https://api.groq.com/openai/v1/chat/completions")
}

@Test func openAIProviderMapsUnauthorized() async {
    let http = FakeHTTP(); http.routes = [("chat/completions", 401, Data())]
    let p = OpenAICompatibleProvider(spec: ProviderCatalog.spec("groq")!, baseURL: "https://x/v1", apiKey: "k", model: "m", client: http)
    await #expect(throws: ProviderError.self) { try await p.extractChunk(system: "s", user: "u") }
}

@Test func claudeCLIProviderParsesStructuredOutput() async throws {
    let p = ClaudeCLIProvider(spec: ProviderCatalog.spec("claude-cli")!, executable: "/fake/claude") { exe, args, stdin in
        #expect(exe == "/fake/claude")
        #expect(args.contains("--json-schema")); #expect(stdin?.contains("u") == true)
        return CLIRunResult(stdout: #"{"type":"result","structured_output":{"occupation":"Pilot","companies":[],"achievements":[],"certificates":[],"experience":[],"canHelpWith":[]}}"#, stderr: "", status: 0)
    }
    #expect(try await p.extractChunk(system: "s", user: "u").occupation == "Pilot")
}

@Test func cliRunnerRunsRealProcess() async throws {
    let r = try await CLIRunner.run(executable: "/bin/echo", arguments: ["hi"], stdin: nil)
    #expect(r.stdout.trimmingCharacters(in: .whitespacesAndNewlines) == "hi"); #expect(r.status == 0)
}

@Test func defaultExtractChunksAndMerges() async throws {
    struct Echo: AIProvider {
        let spec = ProviderCatalog.spec("custom")!
        // Keyed on the prompt's length: a stable per-chunk identity that doesn't depend on
        // where the chunk boundary happened to land.
        func extractChunk(system: String, user: String) async throws -> ProfileFacts { ProfileFacts(canHelpWith: [String(user.count)]) }
        func validate() async throws {}
    }
    let p = Person(givenName: "A", familyName: "B")
    let pages = (0..<6).map { SourcePage(candidateId: "c", url: "https://p\($0)", title: "t", snippet: nil, bodyText: String(repeating: "word ", count: 3000), kind: .page) }
    let f = try await Echo().extract(ExtractionInput(person: p, channels: [], pages: pages))
    #expect(f.canHelpWith.count >= 2)   // more than one chunk was processed and merged
}

// MARK: - Fix round 1: source markers, stdin safety, and the paths the brief's tests miss

@Test func everySourceLineKeepsItsMarkerAcrossChunks() {
    let body = (0..<80).map { "Fact number \($0) about the person." }.joined(separator: " ")
    let pages = (0..<2).map {
        SourcePage(candidateId: "c", url: "https://p\($0)", title: "Page \($0)", snippet: "a snippet", bodyText: body, kind: .page)
    }
    let chunks = ExtractionPrompt.chunkedSources(pages, maxTokens: 40)   // ≈160 chars
    #expect(chunks.count > 2)
    let lines = chunks.flatMap { $0.split(separator: "\n") }
        .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
    #expect(lines.count >= chunks.count)
    #expect(lines.allSatisfy { $0.hasPrefix("[src:") })
    // Both pages' markers survive, so facts from either can still be cited.
    let document = chunks.joined(separator: "\n")
    for page in pages { #expect(document.contains("[src:\(page.id)]")) }
}

@Test func openAIProviderRetriesWithoutJSONSchema() async throws {
    let http = FakeHTTP()
    http.scripted = [
        (400, Data(#"{"error":{"message":"response_format.type json_schema is not supported"}}"#.utf8)),
        (200, Data(#"{"choices":[{"message":{"content":"{\"occupation\":\"Baker\",\"canHelpWith\":[\"bread\"]}"}}]}"#.utf8)),
    ]
    let p = OpenAICompatibleProvider(spec: ProviderCatalog.spec("groq")!, baseURL: "https://x/v1", apiKey: "k", model: "m", client: http)
    let f = try await p.extractChunk(system: "s", user: "u")

    #expect(f.occupation == "Baker"); #expect(f.canHelpWith == ["bread"])
    #expect(http.requested.count == 2)
    let retry = String(decoding: http.sentBodies[1], as: UTF8.self)
    #expect(retry.contains("json_object"))
    #expect(!retry.contains("json_schema"))
    #expect(retry.contains("Return only JSON matching this schema"))
}

@Test func openAIProviderMapsStatusesToProviderErrors() async {
    func provider(_ status: Int, _ body: Data = Data()) -> OpenAICompatibleProvider {
        let http = FakeHTTP(); http.scripted = [(status, body)]
        return OpenAICompatibleProvider(spec: ProviderCatalog.spec("groq")!, baseURL: "https://x/v1", apiKey: "k", model: "m", client: http)
    }
    await #expect(throws: ProviderError.unauthorized) { try await provider(401).extractChunk(system: "s", user: "u") }
    await #expect(throws: ProviderError.unauthorized) { try await provider(403).extractChunk(system: "s", user: "u") }
    await #expect(throws: ProviderError.contextTooLarge) { try await provider(413).extractChunk(system: "s", user: "u") }
    await #expect(throws: ProviderError.contextTooLarge) {
        try await provider(400, Data(#"{"error":"maximum context length exceeded"}"#.utf8)).extractChunk(system: "s", user: "u")
    }
}

@Test func anthropicProviderReadsToolUseAndSendsAuthHeaders() async throws {
    let http = FakeHTTP()
    http.routes = [("v1/messages", 200, Data(#"{"content":[{"type":"text","text":"thinking"},{"type":"tool_use","name":"save_profile","input":{"occupation":"Chef","companies":[{"text":"Acme","sources":["s1"]}],"canHelpWith":["pastry"]}}]}"#.utf8))]
    let p = AnthropicProvider(spec: ProviderCatalog.spec("anthropic")!, apiKey: "sk-test", model: "claude-haiku", client: http)
    let f = try await p.extractChunk(system: "s", user: "u")

    #expect(f.occupation == "Chef"); #expect(f.companies.first?.sources == ["s1"]); #expect(f.canHelpWith == ["pastry"])
    #expect(http.requested.first == "https://api.anthropic.com/v1/messages")
    #expect(http.sentHeaders.first?["x-api-key"] == "sk-test")
    #expect(http.sentHeaders.first?["anthropic-version"] == "2023-06-01")
    #expect(String(decoding: http.sentBodies[0], as: UTF8.self).contains("save_profile"))
}

@Test func factoryBuildsProvidersOrSaysWhyItCannot() throws {
    let http = FakeHTTP()
    let openai = try ProviderFactory.make(spec: ProviderCatalog.spec("openai")!, config: nil, apiKey: "k", detected: .unavailable, client: http)
    #expect(openai is OpenAICompatibleProvider); #expect(openai.spec.id == "openai")

    let claude = try ProviderFactory.make(spec: ProviderCatalog.spec("claude-cli")!, config: nil, apiKey: nil, detected: .available("/usr/local/bin/claude"), client: http)
    #expect(claude is ClaudeCLIProvider)

    #expect(throws: ProviderError.notInstalled("Claude Code")) {
        try ProviderFactory.make(spec: ProviderCatalog.spec("claude-cli")!, config: nil, apiKey: nil, detected: .unavailable, client: http)
    }
    #expect(throws: ProviderError.unavailable("Apple Intelligence")) {
        try ProviderFactory.make(spec: ProviderCatalog.spec("apple")!, config: nil, apiKey: nil, detected: .available("Apple Intelligence"), client: http)
    }
}

@Test func extractHalvesAChunkThatOverflowsContext() async throws {
    actor Calls {
        private(set) var count = 0
        func record() { count += 1 }
    }
    struct Picky: AIProvider {
        let spec = ProviderCatalog.spec("custom")!
        let limit: Int
        let calls: Calls
        func extractChunk(system: String, user: String) async throws -> ProfileFacts {
            await calls.record()
            if user.count > limit { throw ProviderError.contextTooLarge }
            return ProfileFacts(canHelpWith: ["ok"])
        }
        func validate() async throws {}
    }

    let body = (0..<1000).map { "Fact number \($0) about the person." }.joined(separator: " ")   // ≈34k chars
    let page = SourcePage(candidateId: "c", url: "https://p", title: "t", snippet: nil, bodyText: body, kind: .page)
    let calls = Calls()
    let person = Person(givenName: "A", familyName: "B")
    // One chunk holds the whole page; each half of it fits.
    let f = try await Picky(limit: 20_000, calls: calls).extract(ExtractionInput(person: person, pages: [page]))

    #expect(f.canHelpWith == ["ok"])
    #expect(await calls.count > 1)
}

@Test func cliRunnerSurvivesAChildThatNeverReadsStdin() async throws {
    // /usr/bin/true exits immediately, so the prompt is written into a pipe nobody is
    // reading: without SIGPIPE ignored this kills the whole process.
    let r = try await CLIRunner.run(executable: "/usr/bin/true", arguments: [], stdin: String(repeating: "x", count: 200_000))
    #expect(r.status == 0); #expect(r.stdout.isEmpty)
}

@Test func cliRunnerTimesOutAndKillsTheChild() async throws {
    let start = Date()
    await #expect(throws: ProviderError.self) {
        try await CLIRunner.run(executable: "/bin/sleep", arguments: ["37"], stdin: nil, timeout: 0.2)
    }
    #expect(Date().timeIntervalSince(start) < 2)

    try await Task.sleep(for: .milliseconds(500))
    let survivors = try await CLIRunner.run(executable: "/usr/bin/pgrep", arguments: ["-f", "sleep 37"], stdin: nil)
    #expect(survivors.stdout.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
}

@Test func cliNonZeroExitCarriesStderr() async {
    let p = ClaudeCLIProvider(spec: ProviderCatalog.spec("claude-cli")!, executable: "/fake/claude") { _, _, _ in
        CLIRunResult(stdout: "", stderr: "not logged in", status: 1)
    }
    await #expect(throws: ProviderError.badResponse("not logged in")) {
        try await p.extractChunk(system: "s", user: "u")
    }
}
