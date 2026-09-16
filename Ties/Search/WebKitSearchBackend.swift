import Foundation
import WebKit
import TiesCore

/// A `SearchBackend` that drives an off-screen `WKWebView` against a scrapable search
/// engine's HTML results page, since none of them has a public API worth the name. Requests
/// are serialized through this instance's single web view (one query at a time, roughly
/// `minInterval` apart) because loading two pages into the same `WKWebView` concurrently
/// would race — running several *searches* at once is `SearchPool`'s job, and it does it by
/// owning several of these.
///
/// Which engine it asks is data (`SearchEngine`) rather than code, and can be changed under a
/// running backend with `switchEngine(_:)` — that is how the pool fails a web view over to
/// another engine after a bot wall.
///
/// Main-actor isolation is what lets this class satisfy `SearchBackend: Sendable` without an
/// explicit conformance: every stored property is only ever touched while isolated to the
/// main actor, so there's nothing for a data race to find.
@MainActor
public final class WebKitSearchBackend: NSObject, SearchEngineSwitching, WKNavigationDelegate {
    /// The engine this backend was built for. Deliberately fixed even when `switchEngine(_:)`
    /// moves the web view onto another one: it names the family of engine — "the web views" —
    /// that `AppModel` and the engine menu talk about, not whichever page is being scraped
    /// this minute.
    public nonisolated let id: String

    /// Which engine the *next* query uses. A query already in flight keeps the engine it
    /// started with: its page was loaded from that engine's URL, and only that engine's
    /// script can read it.
    private var engine: SearchEngine
    private let minInterval: TimeInterval
    private let jitter: TimeInterval
    private let timeout: TimeInterval
    private let webView: WKWebView

    /// FIFO of not-yet-started searches, each paired with the continuation that `search(_:)`
    /// is waiting on. Only `pending.first` is ever in flight; `processNext()` pops it, runs
    /// it, resumes its continuation, and moves on to the next one.
    private var pending: [(query: String, continuation: CheckedContinuation<[SearchHit], Error>)] = []
    private var isRunning = false

    /// When the last page load started, so `runSearch` can wait out the rest of its
    /// jittered interval before starting the next one.
    private var lastRun: Date?

    /// The continuation `load(_:)` is waiting on for the current navigation's `didFinish`
    /// (or `didFail`) callback.
    private var navigationContinuation: CheckedContinuation<Void, Error>?

    /// The `WKNavigation` `load(_:)` is currently waiting on, so delegate callbacks can tell
    /// a stale navigation apart from the one they're actually tracking. Without this, a
    /// timeout's `stopLoading()` can trigger an asynchronous `didFailProvisionalNavigation`
    /// that lands *after* the next query has already installed a new `navigationContinuation`
    /// — resuming that unrelated, still-in-flight continuation with a spurious error.
    private var currentNavigation: WKNavigation?

    public init(
        engine: SearchEngine = .duckduckgo,
        minInterval: TimeInterval = 2.5,
        jitter: TimeInterval = 0.7,
        timeout: TimeInterval = 25
    ) {
        self.id = engine.id
        self.engine = engine
        self.minInterval = minInterval
        self.jitter = jitter
        self.timeout = timeout
        self.webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 1200, height: 900))
        super.init()
        webView.customUserAgent = HTTPDefaults.userAgent
        webView.navigationDelegate = self
    }

    public nonisolated func search(_ query: String) async throws -> [SearchHit] {
        try await enqueue(query)
    }

    /// Points this web view at another engine, from the next query onwards. Called by
    /// `SearchPool` when this backend reports a bot wall; the query being answered when that
    /// happened is finished (badly) on the engine it started on.
    public func switchEngine(_ engine: SearchEngine) {
        self.engine = engine
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
        // Jittered so that a pool of these doesn't fall into lockstep and knock on one engine
        // in bursts of N; see `SearchPool.nextInterval`.
        if let lastRun {
            let interval = SearchPool.nextInterval(base: minInterval, jitter: jitter)
            let remaining = interval - Date().timeIntervalSince(lastRun)
            if remaining > 0 {
                try await Task.sleep(nanoseconds: UInt64(remaining * 1_000_000_000))
            }
        }
        lastRun = Date()

        // Read once, so a `switchEngine(_:)` landing mid-query can't have the page loaded
        // from one engine read back with another's selectors.
        let engine = self.engine
        guard let url = engine.url(for: query) else {
            throw SearchBackendError.transport("could not build \(engine.name) search URL for query: \(query)")
        }

        let timeoutSeconds = timeout
        return try await withThrowingTaskGroup(of: [SearchHit].self) { group in
            group.addTask {
                try await self.load(url)
                return try await self.pollForResults(engine: engine)
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
        currentNavigation = nil
        webView.stopLoading()
        continuation.resume(throwing: error)
    }

    private func load(_ url: URL) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            navigationContinuation = continuation
            currentNavigation = webView.load(URLRequest(url: url))
        }
    }

    /// Polls the engine's result script once a second for up to 12 attempts. If no rows ever
    /// show up, checks the page text for that engine's bot-challenge wording (throws
    /// `.challenge`) or takes it as a "no results" page (returns `[]` rather than treating it
    /// as a challenge).
    private func pollForResults(engine: SearchEngine) async throws -> [SearchHit] {
        for attempt in 0..<12 {
            if attempt > 0 {
                try await Task.sleep(nanoseconds: 1_000_000_000)
            }
            if let raw = try await evaluateJS(engine.resultScript),
               let hits = Self.decodeHits(raw), !hits.isEmpty {
                return hits
            }
        }

        let bodyText = (try await evaluateJS("document.body.innerText")) ?? ""
        if engine.isChallenge(bodyText) {
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
        guard navigation === currentNavigation else { return }
        navigationContinuation?.resume()
        navigationContinuation = nil
        currentNavigation = nil
    }

    public func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        guard navigation === currentNavigation else { return }
        navigationContinuation?.resume(throwing: SearchBackendError.transport(error.localizedDescription))
        navigationContinuation = nil
        currentNavigation = nil
    }

    public func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        guard navigation === currentNavigation else { return }
        navigationContinuation?.resume(throwing: SearchBackendError.transport(error.localizedDescription))
        navigationContinuation = nil
        currentNavigation = nil
    }
}
