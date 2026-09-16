import Testing
import Foundation
@testable import TiesCore

@Test func catalogOrderAndIds() {
    let ids = ProviderCatalog.all.map(\.id)
    #expect(Array(ids.prefix(5)) == ["apple", "gemini", "groq", "openrouter", "claude-cli"])
    #expect(ids.last == "custom")
    #expect(Set(ids).count == ids.count)
    #expect(ProviderCatalog.all.filter { $0.tier == .freeCloud }.count == 3)
    #expect(ProviderCatalog.spec("ollama")?.needsAPIKey == false)
}

@Test func detectorUsesRules() async {
    let http = FakeHTTP(); http.routes = [("11434/api/tags", 200, Data("{}".utf8))]
    let d = ProviderDetector(client: http, fileExists: { $0.hasSuffix("Jan.app") }, which: { $0 == "claude" ? "/usr/local/bin/claude" : nil })
    #expect(await d.detect(ProviderCatalog.spec("ollama")!) == .available("http://127.0.0.1:11434/v1"))
    #expect(await d.detect(ProviderCatalog.spec("lmstudio")!) == .unavailable)
    #expect(await d.detect(ProviderCatalog.spec("jan")!) == .available("/Applications/Jan.app"))
    #expect(await d.detect(ProviderCatalog.spec("claude-cli")!) == .available("/usr/local/bin/claude"))
    #expect(await d.detect(ProviderCatalog.spec("codex-cli")!) == .unavailable)
    #expect(await d.detect(ProviderCatalog.spec("apple")!) == .unavailable)
    #expect(await d.detect(ProviderCatalog.spec("openai")!) == .unavailable)   // no detect rule → unavailable (means "needs key")
}

@Test func keychainRoundTrip() throws {
    let account = "test-\(UUID().uuidString)"
    try Keychain.set("secret", account: account)
    #expect(Keychain.get(account: account) == "secret")
    Keychain.delete(account: account)
    #expect(Keychain.get(account: account) == nil)
}
