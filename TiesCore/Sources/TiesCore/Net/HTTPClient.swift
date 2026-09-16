import Foundation

/// A completed HTTP response.
public struct HTTPResponse: Sendable {
    public var status: Int
    public var headers: [String: String]
    public var body: Data

    public var text: String { String(decoding: body, as: UTF8.self) }
}

public enum HTTPError: Error, Sendable {
    /// An HTTP response with a status code `>= 400` (other than 429/503), carrying the response body as text.
    case status(Int, String)
    /// A 429 or 503 response. `retryAfter` is the `Retry-After` header value in seconds, or 30 if absent/unparseable.
    case rateLimited(retryAfter: TimeInterval)
    /// A non-HTTP transport failure (DNS, connection reset, etc).
    case transport(String)
    /// The request timed out.
    case timeout
}

public protocol HTTPClient: Sendable {
    func get(_ url: URL, headers: [String: String]) async throws -> HTTPResponse
    /// As `get`, but with `bypassCache: true` the response must come from the network: no
    /// cached body is returned and the fresh one is not stored. Liveness checks need this —
    /// a cached 200 would keep reporting a stopped local server as running.
    func get(_ url: URL, headers: [String: String], bypassCache: Bool) async throws -> HTTPResponse
    func post(_ url: URL, headers: [String: String], body: Data) async throws -> HTTPResponse
}

extension HTTPClient {
    /// A client with no cache of its own has nothing to bypass, so the flag defaults to being
    /// ignored and every existing conformer keeps compiling unchanged.
    public func get(_ url: URL, headers: [String: String], bypassCache: Bool) async throws -> HTTPResponse {
        try await get(url, headers: headers)
    }
}

public enum HTTPDefaults {
    public static let userAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 14_0) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15"
}

/// The production `HTTPClient`: per-host throttled, with an optional on-disk GET cache.
public final class URLSessionHTTPClient: HTTPClient {
    private let session: URLSession
    private let cache: DiskCache?
    private let throttle: HostThrottle
    private let userAgent: String
    private let timeout: TimeInterval

    public init(
        session: URLSession = .shared,
        cache: DiskCache? = nil,
        throttle: HostThrottle = HostThrottle(),
        userAgent: String = HTTPDefaults.userAgent,
        timeout: TimeInterval = 20
    ) {
        self.session = session
        self.cache = cache
        self.throttle = throttle
        self.userAgent = userAgent
        self.timeout = timeout
    }

    public func get(_ url: URL, headers: [String: String]) async throws -> HTTPResponse {
        try await get(url, headers: headers, bypassCache: false)
    }

    public func get(_ url: URL, headers: [String: String], bypassCache: Bool) async throws -> HTTPResponse {
        let cacheKey = url.absoluteString
        if !bypassCache, let cache, let cached = cache.get(cacheKey) {
            return HTTPResponse(status: 200, headers: [:], body: cached)
        }

        let response = try await send(
            url: url,
            method: "GET",
            headers: headers,
            body: nil,
            // Skip URLSession's own cache too, so bypassing means "ask the server", not
            // "ask the other cache".
            cachePolicy: bypassCache ? .reloadIgnoringLocalAndRemoteCacheData : .useProtocolCachePolicy
        )

        if !bypassCache, response.status == 200, let cache {
            cache.set(cacheKey, response.body)
        }
        return response
    }

    public func post(_ url: URL, headers: [String: String], body: Data) async throws -> HTTPResponse {
        try await send(url: url, method: "POST", headers: headers, body: body)
    }

    private func send(
        url: URL,
        method: String,
        headers: [String: String],
        body: Data?,
        cachePolicy: URLRequest.CachePolicy = .useProtocolCachePolicy
    ) async throws -> HTTPResponse {
        let host = url.host ?? url.absoluteString
        await throttle.waitTurn(host: host)

        var request = URLRequest(url: url, cachePolicy: cachePolicy, timeoutInterval: timeout)
        request.httpMethod = method
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        for (field, value) in headers {
            request.setValue(value, forHTTPHeaderField: field)
        }
        request.httpBody = body

        let data: Data
        let urlResponse: URLResponse
        do {
            (data, urlResponse) = try await session.data(for: request)
        } catch let error as URLError where error.code == .timedOut {
            throw HTTPError.timeout
        } catch let error as URLError {
            throw HTTPError.transport(error.localizedDescription)
        }

        guard let httpResponse = urlResponse as? HTTPURLResponse else {
            throw HTTPError.transport("received a non-HTTP response")
        }

        var responseHeaders: [String: String] = [:]
        for (key, value) in httpResponse.allHeaderFields {
            if let keyString = key as? String, let valueString = value as? String {
                responseHeaders[keyString] = valueString
            }
        }

        if httpResponse.statusCode == 429 || httpResponse.statusCode == 503 {
            let retryAfter = retryAfterSeconds(from: responseHeaders)
            await throttle.backoff(host: host, seconds: retryAfter)
            throw HTTPError.rateLimited(retryAfter: retryAfter)
        }

        if httpResponse.statusCode >= 400 {
            throw HTTPError.status(httpResponse.statusCode, String(decoding: data, as: UTF8.self))
        }

        return HTTPResponse(status: httpResponse.statusCode, headers: responseHeaders, body: data)
    }

    private func retryAfterSeconds(from headers: [String: String]) -> TimeInterval {
        for (key, value) in headers where key.caseInsensitiveCompare("Retry-After") == .orderedSame {
            if let seconds = TimeInterval(value) {
                return seconds
            }
        }
        return 30
    }
}
