import Foundation
import WebKit
import TiesCore

/// A `SearchBackend` that drives an off-screen `WKWebView` against DuckDuckGo's HTML results
/// page, since DuckDuckGo has no public search API. Requests are serialized through a single
/// shared web view (one query at a time, `minInterval` apart) because loading two pages into
/// the same `WKWebView` concurrently would race.
///
/// Main-actor isolation is what lets this class satisfy `SearchBackend: Sendable` without an
/// explicit conformance: every stored property is only ever touched while isolated to the
/// main actor, so there's nothing for a data race to find.
@MainActor
public final class WebKitSearchBackend: NSObject, SearchBackend, WKNavigationDelegate {
    public let id = "duckduckgo"

    private let minInterval: TimeInterval
    private let timeout: TimeInterval
    private let webView: WKWebView

    /// FIFO of not-yet-started searches, each paired with the continuation that `search(_:)`
    /// is waiting on. Only `pending.first` is ever in flight; `processNext()` pops it, runs
    /// it, resumes its continuation, and moves on to the next one.
    private var pending: [(query: String, continuation: CheckedContinuation<[SearchHit], Error>)] = []
    private var isRunning = false

    /// When the last page load started, so `runSearch` can wait out the rest of
    /// `minInterval` before starting the next one.
    private var lastRun: Date?

    /// The continuation `load(_:)` is waiting on for the current navigation's `didFinish`
    /// (or `didFail`) callback.
    private var navigationContinuation: CheckedContinuation<Void, Error>?

    public init(minInterval: TimeInterval = 2.5, timeout: TimeInterval = 25) {
        self.minInterval = minInterval
        self.timeout = timeout
        self.webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 1200, height: 900))
        super.init()
        webView.customUserAgent = HTTPDefaults.userAgent
        webView.navigationDelegate = self
    }

    public nonisolated func search(_ query: String) async throws -> [SearchHit] {
        try await enqueue(query)
    }

    // MARK: - Queueing

    private func enqueue(_ query: String) async throws -> [SearchHit] {
        try await withCheckedThrowingContinuation { continuation in
            pending.append((query, continuation))
            if !isRunning {
                processNext()
            }
        }
    }

    private func processNext() {
        guard !pending.isEmpty else {
            isRunning = false
            return
        }
        isRunning = true
        let next = pending.removeFirst()
        Task {
            do {
                let hits = try await runSearch(next.query)
                next.continuation.resume(returning: hits)
            } catch {
                next.continuation.resume(throwing: error)
            }
            processNext()
        }
    }

    // MARK: - Search

    private func runSearch(_ query: String) async throws -> [SearchHit] {
        if let lastRun {
            let remaining = minInterval - Date().timeIntervalSince(lastRun)
            if remaining > 0 {
                try await Task.sleep(nanoseconds: UInt64(remaining * 1_000_000_000))
            }
        }
        lastRun = Date()

        guard let encoded = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let url = URL(string: "https://duckduckgo.com/?ia=web&q=\(encoded)")
        else {
            throw SearchBackendError.transport("could not build DuckDuckGo search URL for query: \(query)")
        }

        let timeoutSeconds = timeout
        return try await withThrowingTaskGroup(of: [SearchHit].self) { group in
            group.addTask {
                try await self.load(url)
                return try await self.pollForResults()
            }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(timeoutSeconds * 1_000_000_000))
                throw SearchBackendError.timeout
            }
            do {
                let result = try await group.next()!
                group.cancelAll()
                return result
            } catch {
                group.cancelAll()
                // If the timeout fired mid-page-load, the cancelled `load()` child task above
                // is still suspended waiting for a `didFinish`/`didFail` callback that may
                // never arrive promptly — resume it ourselves so that child task can finish
                // and this task group's implicit end-of-scope drain doesn't hang forever.
                // (A no-op when the navigation already completed on its own.)
                failPendingNavigation(with: SearchBackendError.timeout)
                throw error
            }
        }
    }

    /// Resumes a still-pending navigation continuation with `error` instead of leaving it
    /// dangling. Safe to call when there's no pending navigation (e.g. it already finished) —
    /// it's a no-op in that case.
    private func failPendingNavigation(with error: Error) {
        guard let continuation = navigationContinuation else { return }
        navigationContinuation = nil
        webView.stopLoading()
        continuation.resume(throwing: error)
    }

    private func load(_ url: URL) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            navigationContinuation = continuation
            webView.load(URLRequest(url: url))
        }
    }

    private static let pollScript = """
    JSON.stringify(Array.from(document.querySelectorAll('[data-testid="result"]')).slice(0,10).map(r => ({
      url: (r.querySelector('a[data-testid="result-title-a"]')||{}).href || null,
      title: (r.querySelector('a[data-testid="result-title-a"]')||{}).innerText || null,
      snippet: (r.querySelector('[data-result="snippet"]')||{}).innerText || null })))
    """

    /// Polls the results script once a second for up to 12 attempts. If no rows ever show up,
    /// checks the page text for DuckDuckGo's bot-challenge wording (throws `.challenge`) or a
    /// "no results" message (returns `[]` rather than treating it as a challenge).
    private func pollForResults() async throws -> [SearchHit] {
        for attempt in 0..<12 {
            if attempt > 0 {
                try await Task.sleep(nanoseconds: 1_000_000_000)
            }
            if let raw = try await evaluateJS(Self.pollScript),
               let hits = Self.decodeHits(raw), !hits.isEmpty {
                return hits
            }
        }

        let bodyText = (try await evaluateJS("document.body.innerText")) ?? ""
        let lowered = bodyText.lowercased()
        if lowered.contains("challenge") || lowered.contains("bots") {
            throw SearchBackendError.challenge
        }
        return []
    }

    /// Runs `script` and returns its result as a `String`, if it produced one. The result is
    /// cast to `String` inside the completion handler (rather than resumed as `Any?`) so a
    /// non-`Sendable` JS value never has to cross the continuation boundary.
    @discardableResult
    private func evaluateJS(_ script: String) async throws -> String? {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<String?, Error>) in
            webView.evaluateJavaScript(script) { result, error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: result as? String)
                }
            }
        }
    }

    private static func decodeHits(_ json: String) -> [SearchHit]? {
        guard let data = json.data(using: .utf8),
              let raw = try? JSONDecoder().decode([RawHit].self, from: data)
        else {
            return nil
        }
        return raw.compactMap { hit in
            guard let url = hit.url, let title = hit.title else { return nil }
            return SearchHit(url: url, title: title, snippet: hit.snippet ?? "")
        }
    }

    private struct RawHit: Decodable {
        var url: String?
        var title: String?
        var snippet: String?
    }

    // MARK: - WKNavigationDelegate

    public func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        navigationContinuation?.resume()
        navigationContinuation = nil
    }

    public func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        navigationContinuation?.resume(throwing: SearchBackendError.transport(error.localizedDescription))
        navigationContinuation = nil
    }

    public func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        navigationContinuation?.resume(throwing: SearchBackendError.transport(error.localizedDescription))
        navigationContinuation = nil
    }
}
