import Foundation
@testable import TiesCore

/// Loads a test fixture file from the test bundle's `Fixtures` resource directory.
func fixture(_ name: String, _ ext: String) throws -> Data {
    try Data(contentsOf: Bundle.module.url(forResource: name, withExtension: ext, subdirectory: "Fixtures")!)
}

/// A fake `HTTPClient` for probe tests. Routes by URL substring; records requested URLs.
/// Not `private`/`fileprivate`: reused by every probe test file across Tasks 8-14.
final class FakeHTTP: HTTPClient, @unchecked Sendable {
    var routes: [(contains: String, status: Int, body: Data)] = []
    /// Answers served in call order, taking priority over `routes` while any are left. Use
    /// these when the same URL must answer differently on successive calls, e.g. a 400 that
    /// makes the provider retry.
    var scripted: [(status: Int, body: Data)] = []
    var requested: [String] = []
    /// Request headers and POST bodies, in call order, for asserting what was sent.
    var sentHeaders: [[String: String]] = []
    var sentBodies: [Data] = []
    /// The `bypassCache` flag of each GET, in call order (POSTs record nothing here).
    var bypassedCache: [Bool] = []
    private let lock = NSLock()

    func get(_ url: URL, headers: [String: String]) async throws -> HTTPResponse {
        try respond(url: url, headers: headers, body: nil, bypassCache: false)
    }

    func get(_ url: URL, headers: [String: String], bypassCache: Bool) async throws -> HTTPResponse {
        try respond(url: url, headers: headers, body: nil, bypassCache: bypassCache)
    }

    func post(_ url: URL, headers: [String: String], body: Data) async throws -> HTTPResponse {
        try respond(url: url, headers: headers, body: body, bypassCache: nil)
    }

    // `NSLock.lock()`/`unlock()` can't be called directly from an `async` function body
    // (they're `noasync`); a plain synchronous helper sidesteps that while keeping the same
    // lock-protected bookkeeping.
    private func respond(url: URL, headers: [String: String], body: Data?, bypassCache: Bool?) throws -> HTTPResponse {
        lock.lock()
        requested.append(url.absoluteString)
        sentHeaders.append(headers)
        if let body { sentBodies.append(body) }
        if let bypassCache { bypassedCache.append(bypassCache) }
        let next = scripted.isEmpty ? nil : scripted.removeFirst()
        lock.unlock()

        if let next {
            if next.status >= 400 { throw HTTPError.status(next.status, String(decoding: next.body, as: UTF8.self)) }
            return HTTPResponse(status: next.status, headers: [:], body: next.body)
        }
        if let r = routes.first(where: { url.absoluteString.contains($0.contains) }) {
            if r.status >= 400 { throw HTTPError.status(r.status, "") }
            return HTTPResponse(status: r.status, headers: [:], body: r.body)
        }
        throw HTTPError.status(404, "no route")
    }
}

/// Builds a `ProbeInput` for a person with the given name, emails, phones (already E.164, the
/// form `Channel.normalized` carries), urls, company, and local signals. The signals'
/// `personId` is rewritten to the person built here — see `localSignals(...)`.
func input(
    name: (String, String),
    emails: [String] = [],
    phones: [String] = [],
    urls: [String] = [],
    company: String? = nil,
    signals: LocalSignals? = nil
) -> ProbeInput {
    let p = Person(givenName: name.0, familyName: name.1, organization: company)
    var ch = emails.map { Channel(personId: p.id, kind: .email, label: nil, value: $0, normalized: $0) }
    ch += phones.map { Channel(personId: p.id, kind: .phone, label: nil, value: $0, normalized: $0) }
    ch += urls.map { Channel(personId: p.id, kind: .url, label: nil, value: $0, normalized: $0) }
    var signals = signals
    signals?.personId = p.id
    return ProbeInput(person: p, channels: ch, signals: signals)
}

/// Builds a `LocalSignals` with a placeholder `personId` for `input(name:signals:)` to fill in.
func localSignals(aliases: [String] = [], honorifics: [String] = [], honorificsAsWritten: [String] = [],
                  titles: [String] = [], companies: [String] = [], links: [String] = [],
                  location: String? = nil) -> LocalSignals {
    LocalSignals(personId: "", aliases: aliases, honorifics: honorifics,
                 honorificsAsWritten: honorificsAsWritten, titles: titles,
                 companies: companies, links: links, location: location)
}

/// A fresh, empty directory under the system temporary directory for a test to write into.
func tmp() -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("ties-test-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}
