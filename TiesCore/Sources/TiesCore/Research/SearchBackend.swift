import Foundation

/// A single organic result from a web search: its URL, title, and snippet text, exactly as
/// the backend returned them (not yet canonicalized or evidence-scored).
public struct SearchHit: Sendable, Hashable {
    public var url: String
    public var title: String
    public var snippet: String

    public init(url: String, title: String, snippet: String) {
        self.url = url
        self.title = title
        self.snippet = snippet
    }
}

/// Errors a `SearchBackend` can raise. `.challenge` signals the backend hit a bot-detection
/// wall (e.g. a CAPTCHA) and should be treated specially by callers (see `SearchProbe`, which
/// rethrows it so the scanner can back off instead of hammering the backend further).
public enum SearchBackendError: Error, Sendable {
    case challenge
    case timeout
    case transport(String)
    case unauthorized
}

/// A pluggable web-search provider. Implementations return at most 10 organic hits for a
/// single query string.
public protocol SearchBackend: Sendable {
    /// A short, stable identifier for this backend (e.g. "tavily", "duckduckgo").
    var id: String { get }

    func search(_ query: String) async throws -> [SearchHit]
}

/// Maps a transport-level `HTTPError` onto the `SearchBackendError` a `SearchBackend` should
/// surface, so `TavilySearchBackend` and `ExaSearchBackend` share one mapping. 401/403 map to
/// `.unauthorized`; anything else that isn't already a `SearchBackendError` becomes
/// `.transport` (or `.timeout` for an actual timeout).
func mapSearchHTTPError(_ error: Error) -> Error {
    guard let httpError = error as? HTTPError else { return error }
    switch httpError {
    case .status(let code, let body):
        if code == 401 || code == 403 {
            return SearchBackendError.unauthorized
        }
        return SearchBackendError.transport("HTTP \(code): \(body)")
    case .rateLimited(let retryAfter):
        return SearchBackendError.transport("rate limited, retry after \(retryAfter)s")
    case .transport(let message):
        return SearchBackendError.transport(message)
    case .timeout:
        return SearchBackendError.timeout
    }
}
