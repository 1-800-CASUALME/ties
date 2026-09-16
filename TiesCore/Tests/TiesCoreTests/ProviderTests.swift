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
        func extractChunk(system: String, user: String) async throws -> ProfileFacts { ProfileFacts(canHelpWith: [String(user.suffix(3))]) }
        func validate() async throws {}
    }
    let p = Person(givenName: "A", familyName: "B")
    let pages = (0..<6).map { SourcePage(candidateId: "c", url: "https://p\($0)", title: "t", snippet: nil, bodyText: String(repeating: "word ", count: 3000), kind: .page) }
    let f = try await Echo().extract(ExtractionInput(person: p, channels: [], pages: pages))
    #expect(f.canHelpWith.count >= 2)   // more than one chunk was processed and merged
}
