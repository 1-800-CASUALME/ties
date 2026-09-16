import Foundation

/// One scrapable web search engine: where its results page lives, how to pull the organic
/// results out of it, and how to tell when it has put up a bot wall instead.
///
/// The engines are data rather than subclasses because the only thing that differs between
/// them is those strings and one small function — which is also what makes
/// `scripts/spike-engines.swift` able to check a candidate engine without any of this code
/// being involved.
public struct SearchEngine: Sendable, Identifiable {
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
    /// Turns one of this engine's redirector links into the destination it points at, or
    /// returns `nil` for a URL that isn't one of its wrappers — which is every URL on an
    /// engine that links straight out, so most engines have no decoder at all.
    ///
    /// It is a function rather than a flag because each engine wraps differently: Bing
    /// base64s the destination into a query parameter, Yahoo percent-encodes it into a path
    /// segment, and the next one will do something else again.
    public let linkDecoder: (@Sendable (String) -> String?)?

    public init(
        id: String,
        name: String,
        urlTemplate: String,
        resultScript: String,
        challengeMarkers: [String],
        enabled: Bool = true,
        linkDecoder: (@Sendable (String) -> String?)? = nil
    ) {
        self.id = id
        self.name = name
        self.urlTemplate = urlTemplate
        self.resultScript = resultScript
        self.challengeMarkers = challengeMarkers
        self.enabled = enabled
        self.linkDecoder = linkDecoder
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

    /// The destination `url` really points at: the decoded target when it is one of this
    /// engine's redirectors, and `url` itself otherwise. Every hit's URL goes through this,
    /// because a result link that stays a redirector tells `SearchProbe` nothing — the host
    /// and path are what say "this is a LinkedIn profile" or "this is a GitHub user".
    public func destination(of url: String) -> String {
        linkDecoder?(url) ?? url
    }

    // MARK: - Redirector decoding

    /// Bing links out through `https://www.bing.com/ck/a?…&u=a1<base64url>&…`, where the
    /// value after the `a1` marker is the destination URL in base64url.
    public static func decodeBingLink(_ url: String) -> String? {
        guard let components = URLComponents(string: url),
              components.host?.hasSuffix("bing.com") == true,
              components.path == "/ck/a",
              let wrapped = components.queryItems?.first(where: { $0.name == "u" })?.value,
              wrapped.hasPrefix("a1")
        else {
            return nil
        }
        return base64URLDecoded(String(wrapped.dropFirst(2)))
    }

    /// Yahoo links out through `https://r.search.yahoo.com/…/RU=<percent-encoded>/RK=…`. Its
    /// plain layout links straight to the destination instead, which is why this returns
    /// `nil` rather than failing on anything without an `/RU=` segment.
    public static func decodeYahooLink(_ url: String) -> String? {
        guard url.contains("search.yahoo.com"), let marker = url.range(of: "/RU=") else { return nil }
        let rest = url[marker.upperBound...]
        let end = rest.range(of: "/RK=")?.lowerBound ?? rest.endIndex
        return String(rest[..<end]).removingPercentEncoding
    }

    /// base64url (the `-`/`_` alphabet, padding optional) as `Data.init(base64Encoded:)`
    /// doesn't do it.
    private static func base64URLDecoded(_ value: String) -> String? {
        var padded = value.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while padded.count % 4 != 0 { padded += "=" }
        guard let data = Data(base64Encoded: padded) else { return nil }
        return String(data: data, encoding: .utf8)
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

    /// Disabled by the spike, twice over: the first pass returned ten `li.b_algo` rows of
    /// results unrelated to the query behind `bing.com/ck/a` redirectors, and pinning the
    /// market with `&setmkt=en-US&setlang=en` got "please solve the challenge below to
    /// continue" instead of results at all. The redirector decoder and the `cite` fallback
    /// are kept and tested, so the day Bing serves results again this is one word away.
    public static let bing = SearchEngine(
        id: "bing",
        name: "Bing",
        urlTemplate: "https://www.bing.com/search?q=%@&setmkt=en-US&setlang=en",
        resultScript: """
        JSON.stringify(Array.from(document.querySelectorAll('li.b_algo')).slice(0,10).map(r => {
          const a = r.querySelector('h2 a') || {};
          const cite = ((r.querySelector('cite')||{}).innerText || '').trim();
          return { url: /^https?:\\/\\//.test(cite) ? cite : (a.href || null),
                   title: a.innerText || null,
                   snippet: (r.querySelector('.b_caption p')||{}).innerText || null }; }))
        """,
        challengeMarkers: ["captcha", "solve the challenge"],
        enabled: false,
        linkDecoder: SearchEngine.decodeBingLink
    )

    /// The second engine the pool can fail over to: seven results for the spike query, every
    /// one of them a `linkedin.com/in` profile, linked straight out with no redirector on the
    /// anonymous layout — and titles and snippets in exactly the shape `LinkedInSnippet`
    /// already parses.
    ///
    /// The rows are `div.algo`, but their title is *not* in an `h3` on that layout (the spike
    /// census counted 0 of those against 7 rows), so the first outbound anchor in the row is
    /// the result link and the title is taken from whichever of `h3`, a `*title*` class, the
    /// anchor's own text or the row's second line of text exists.
    public static let yahoo = SearchEngine(
        id: "yahoo",
        name: "Yahoo",
        urlTemplate: "https://search.yahoo.com/search?p=%@",
        resultScript: """
        (function () {
          const out = [], seen = new Set();
          for (const row of document.querySelectorAll('div.algo')) {
            const a = row.querySelector('a[href^="http"]:not([href*="yahoo.com"])');
            if (!a || seen.has(a.href)) continue;
            seen.add(a.href);
            const pick = s => (((row.querySelector(s)) || {}).innerText || '').trim() || null;
            const lines = (row.innerText || '').split('\\n').map(t => t.trim()).filter(Boolean);
            out.push({ url: a.href,
                       title: pick('h3') || pick('[class*="title"]') || (a.innerText || '').trim() || lines[1] || lines[0] || null,
                       snippet: pick('.compText') || pick('p') || lines.slice(2).join(' ') || null });
            if (out.length >= 10) break;
          }
          return JSON.stringify(out);
        })()
        """,
        challengeMarkers: ["captcha", "solve the challenge", "not a bot"],
        linkDecoder: SearchEngine.decodeYahooLink
    )

    /// Disabled by the spike: Mojeek answered the query with a plain `403 - Forbidden`
    /// ("your network appears to be sending automated queries"), so `ul.results-standard li`
    /// had nothing to match. Its selectors have never been seen to work or fail on a real
    /// results page.
    public static let mojeek = SearchEngine(
        id: "mojeek",
        name: "Mojeek",
        urlTemplate: "https://www.mojeek.com/search?q=%@",
        resultScript: """
        JSON.stringify(Array.from(document.querySelectorAll('ul.results-standard li')).slice(0,10).map(r => ({
          url: (r.querySelector('a.ob')||{}).href || null,
          title: (r.querySelector('a.ob')||{}).innerText || null,
          snippet: (r.querySelector('p.s')||{}).innerText || null })))
        """,
        challengeMarkers: ["captcha", "automated queries", "403 - forbidden"],
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

    /// Every engine that has been tried, in failover order — the ones that work first, so a
    /// challenged web view moves from DuckDuckGo to Yahoo. `SearchPool` uses the enabled
    /// ones; the rest are here as the record of what the spike found.
    public static let all: [SearchEngine] = [.duckduckgo, .yahoo, .bing, .brave, .mojeek]

    /// The engines a pool may actually move a worker onto.
    public static var enabledEngines: [SearchEngine] { all.filter(\.enabled) }
}

/// Two engines are the same engine when everything about them but their decoder matches;
/// functions have no equality, and an engine is identified by what it is pointed at and how
/// it is read, of which the decoder is a consequence rather than a distinguishing part.
extension SearchEngine: Hashable {
    public static func == (lhs: SearchEngine, rhs: SearchEngine) -> Bool {
        lhs.id == rhs.id
            && lhs.name == rhs.name
            && lhs.urlTemplate == rhs.urlTemplate
            && lhs.resultScript == rhs.resultScript
            && lhs.challengeMarkers == rhs.challengeMarkers
            && lhs.enabled == rhs.enabled
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(id)
        hasher.combine(name)
        hasher.combine(urlTemplate)
        hasher.combine(resultScript)
        hasher.combine(challengeMarkers)
        hasher.combine(enabled)
    }
}

/// A `SearchBackend` that can be pointed at a different `SearchEngine` while it is running,
/// which is how `SearchPool` fails one of its workers over after a bot wall. Implementations
/// apply the change to their *next* query, never to one in flight.
public protocol SearchEngineSwitching: SearchBackend {
    func switchEngine(_ engine: SearchEngine) async
}
