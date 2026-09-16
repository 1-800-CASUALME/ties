import Foundation

/// One scrapable web search engine: where its results page lives, how to pull the organic
/// results out of it, and how to tell when it has put up a bot wall instead.
///
/// The engines are data rather than subclasses because the only thing that differs between
/// them is those three strings — which is also what makes `scripts/spike-engines.swift` able
/// to check a candidate engine without any of this code being involved.
public struct SearchEngine: Sendable, Hashable, Identifiable {
    /// A short, stable identifier ("duckduckgo", "bing", "brave").
    public let id: String
    /// What the UI calls this engine.
    public let name: String
    /// The results URL, with `%@` where the percent-encoded query goes.
    public let urlTemplate: String
    /// JavaScript returning a JSON string: an array of `{url, title, snippet}` objects, at
    /// most ten of them, for the organic results on the page.
    public let resultScript: String
    /// Lowercased substrings of the page's text that mean "this is a challenge page, not
    /// results" — checked only once the result script has come up empty.
    public let challengeMarkers: [String]
    /// Whether this engine is actually used. An engine whose selectors don't survive the
    /// spike ships `false` rather than being deleted: the definition is the record of what
    /// was tried, and re-enabling it is a one-word change once its page changes again.
    public let enabled: Bool

    public init(
        id: String,
        name: String,
        urlTemplate: String,
        resultScript: String,
        challengeMarkers: [String],
        enabled: Bool = true
    ) {
        self.id = id
        self.name = name
        self.urlTemplate = urlTemplate
        self.resultScript = resultScript
        self.challengeMarkers = challengeMarkers
        self.enabled = enabled
    }

    /// This engine's results page for `query`, or `nil` if the query can't be percent-encoded
    /// into the template.
    public func url(for query: String) -> URL? {
        guard let encoded = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) else {
            return nil
        }
        return URL(string: String(format: urlTemplate, encoded))
    }

    /// True when `text` (the page's visible text) contains any of this engine's challenge
    /// markers. Case-insensitive: the markers are written lowercase.
    public func isChallenge(_ text: String) -> Bool {
        let lowered = text.lowercased()
        return challengeMarkers.contains { lowered.contains($0) }
    }

    // MARK: - The engines

    /// The one engine the spike found working: ten LinkedIn results, first poll, real
    /// destination URLs.
    public static let duckduckgo = SearchEngine(
        id: "duckduckgo",
        name: "DuckDuckGo",
        urlTemplate: "https://duckduckgo.com/?ia=web&q=%@",
        resultScript: """
        JSON.stringify(Array.from(document.querySelectorAll('[data-testid="result"]')).slice(0,10).map(r => ({
          url: (r.querySelector('a[data-testid="result-title-a"]')||{}).href || null,
          title: (r.querySelector('a[data-testid="result-title-a"]')||{}).innerText || null,
          snippet: (r.querySelector('[data-result="snippet"]')||{}).innerText || null })))
        """,
        challengeMarkers: ["anomaly", "challenge", "bots"]
    )

    /// Disabled by the spike: `li.b_algo` does match ten rows, but on a page of results that
    /// have nothing to do with the query, and every `h2 a` href is a `bing.com/ck/a?…`
    /// redirector rather than the destination — which `SearchProbe` can make nothing of.
    public static let bing = SearchEngine(
        id: "bing",
        name: "Bing",
        urlTemplate: "https://www.bing.com/search?q=%@",
        resultScript: """
        JSON.stringify(Array.from(document.querySelectorAll('li.b_algo')).slice(0,10).map(r => ({
          url: (r.querySelector('h2 a')||{}).href || null,
          title: (r.querySelector('h2 a')||{}).innerText || null,
          snippet: (r.querySelector('.b_caption p')||{}).innerText || null })))
        """,
        challengeMarkers: ["captcha"],
        enabled: false
    )

    /// Disabled by the spike: the first anonymous load is a "verifying you're not a bot"
    /// interstitial, so there are no results to select at all. `"not a bot"` is in the
    /// markers because that page says exactly that and says neither "challenge" nor "cf-chl"
    /// anywhere a script can read.
    public static let brave = SearchEngine(
        id: "brave",
        name: "Brave",
        urlTemplate: "https://search.brave.com/search?q=%@",
        resultScript: """
        JSON.stringify(Array.from(document.querySelectorAll('[data-type="web"]')).slice(0,10).map(r => ({
          url: (r.querySelector('a')||{}).href || null,
          title: (r.querySelector('.title')||{}).innerText || null,
          snippet: (r.querySelector('.snippet-description')||{}).innerText || null })))
        """,
        challengeMarkers: ["challenge", "cf-chl", "not a bot"],
        enabled: false
    )

    /// Every engine that has been tried, in failover order. `SearchPool` uses the enabled
    /// ones; the rest are here as the record of what the spike found.
    public static let all: [SearchEngine] = [.duckduckgo, .bing, .brave]

    /// The engines a pool may actually move a worker onto.
    public static var enabledEngines: [SearchEngine] { all.filter(\.enabled) }
}

/// A `SearchBackend` that can be pointed at a different `SearchEngine` while it is running,
/// which is how `SearchPool` fails one of its workers over after a bot wall. Implementations
/// apply the change to their *next* query, never to one in flight.
public protocol SearchEngineSwitching: SearchBackend {
    func switchEngine(_ engine: SearchEngine) async
}
