import Testing
import Foundation
@testable import TiesCore

actor Counter {
    var value = 0
    func bump() { value += 1 }
}

@Suite(.serialized)
struct HTTPClientTests {
    @Test func getCachesAndSetsUserAgent() async throws {
        let counter = Counter()
        StubURLProtocol.handler = { req in
            #expect(req.value(forHTTPHeaderField: "User-Agent")?.contains("Safari") == true)
            Task { await counter.bump() }
            return (200, ["Content-Type": "application/json"], Data("{\"ok\":true}".utf8))
        }
        let cacheDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let client = URLSessionHTTPClient(session: StubURLProtocol.session(), cache: DiskCache(directory: cacheDir))
        let url = URL(string: "https://example.com/a")!
        _ = try await client.get(url, headers: [:])
        let r2 = try await client.get(url, headers: [:])
        #expect(r2.status == 200)
        #expect(r2.text.contains("ok"))
        try await Task.sleep(for: .milliseconds(50))
        #expect(await counter.value == 1)
    }

    @Test func rateLimitBecomesTypedError() async {
        StubURLProtocol.handler = { _ in (429, ["Retry-After": "7"], Data()) }
        let client = URLSessionHTTPClient(session: StubURLProtocol.session())
        do { _ = try await client.get(URL(string: "https://example.com/b")!, headers: [:]); Issue.record("expected throw") }
        catch HTTPError.rateLimited(let retry) { #expect(retry == 7) }
        catch { Issue.record("wrong error \(error)") }
    }
}

@Test func throttleSpacesRequests() async {
    let t = HostThrottle(defaultInterval: 0.2)
    let start = Date()
    await t.waitTurn(host: "h"); await t.waitTurn(host: "h")
    #expect(Date().timeIntervalSince(start) >= 0.19)
}
