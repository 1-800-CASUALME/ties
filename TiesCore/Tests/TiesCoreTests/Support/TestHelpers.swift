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
    var requested: [String] = []
    private let lock = NSLock()

    func get(_ url: URL, headers: [String: String]) async throws -> HTTPResponse {
        recordRequest(url.absoluteString)
        if let r = routes.first(where: { url.absoluteString.contains($0.contains) }) {
            if r.status >= 400 { throw HTTPError.status(r.status, "") }
            return HTTPResponse(status: r.status, headers: [:], body: r.body)
        }
        throw HTTPError.status(404, "no route")
    }

    // `NSLock.lock()`/`unlock()` can't be called directly from an `async` function body
    // (they're `noasync`); a plain synchronous helper sidesteps that while keeping the same
    // lock-protected append.
    private func recordRequest(_ url: String) {
        lock.lock(); requested.append(url); lock.unlock()
    }

    func post(_ url: URL, headers: [String: String], body: Data) async throws -> HTTPResponse {
        try await get(url, headers: headers)
    }
}

/// Builds a `ProbeInput` for a person with the given name, emails, urls, and company.
func input(name: (String, String), emails: [String] = [], urls: [String] = [], company: String? = nil) -> ProbeInput {
    let p = Person(givenName: name.0, familyName: name.1, organization: company)
    var ch = emails.map { Channel(personId: p.id, kind: .email, label: nil, value: $0, normalized: $0) }
    ch += urls.map { Channel(personId: p.id, kind: .url, label: nil, value: $0, normalized: $0) }
    return ProbeInput(person: p, channels: ch)
}
