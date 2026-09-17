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

@Test func runShellTimesOutAndTerminatesProcess() async {
    let clock = ContinuousClock()
    let start = clock.now
    let result = await ProviderDetector.runShell("/bin/sleep 30", timeout: .milliseconds(200))
    let elapsed = clock.now - start
    #expect(result == nil)
    #expect(elapsed < .seconds(4))  // generous: builds and parallel tests share this machine
}

@Test func runShellHappyPath() async {
    let result = await ProviderDetector.runShell("/bin/echo hi", timeout: .seconds(3))
    #expect(result == "hi")
}

@Test func detectorBypassesTheResponseCache() async {
    let http = FakeHTTP(); http.routes = [("11434/api/tags", 200, Data("{}".utf8))]
    let d = ProviderDetector(client: http, fileExists: { _ in false }, which: { _ in nil })
    #expect(await d.detect(ProviderCatalog.spec("ollama")!) == .available("http://127.0.0.1:11434/v1"))
    // The shared client caches GETs on disk for 7 days, so a liveness probe that is allowed
    // to read that cache reports a stopped local server as running for a week.
    #expect(http.bypassedCache == [true])
}

@Test func plainGetDoesNotBypassTheResponseCache() async throws {
    let http = FakeHTTP(); http.routes = [("example.com", 200, Data())]
    _ = try await http.get(URL(string: "https://example.com/x")!, headers: [:])
    #expect(http.bypassedCache == [false])
}
