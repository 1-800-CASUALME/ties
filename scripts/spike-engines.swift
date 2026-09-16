#!/usr/bin/env swift
//
//  spike-engines.swift — Task 8 spike: which search engines can actually be scraped?
//
//  Loads each engine's results page for one query in an off-screen `WKWebView`, runs that
//  engine's result-extraction script against it, and prints how many hits came back. An
//  engine that returns zero hits (or trips its own challenge markers) is one that ships
//  with `enabled: false` in `SearchEngine.all`.
//
//  Usage:
//      swift scripts/spike-engines.swift [engine-id ...] [--query "..."]
//
//  With no engine ids it runs every engine once, in order. Deliberately one load per
//  engine per run: this is a probe, not a crawler.
//

import AppKit
import WebKit

/// One engine as the spike knows it — the same fields `SearchEngine` carries, kept here as a
/// copy so the script stays standalone (`swift scripts/spike-engines.swift` can't import
/// `TiesCore` without building it first).
struct SpikeEngine {
    let id: String
    let name: String
    let urlTemplate: String
    let resultScript: String
    let challengeMarkers: [String]
    /// Turns an engine's redirector into the destination it points at, or `nil` when the URL
    /// isn't one of that engine's wrappers (in which case the URL is already the answer).
    let linkDecoder: ((String) -> String?)?

    init(
        id: String,
        name: String,
        urlTemplate: String,
        resultScript: String,
        challengeMarkers: [String],
        linkDecoder: ((String) -> String?)? = nil
    ) {
        self.id = id
        self.name = name
        self.urlTemplate = urlTemplate
        self.resultScript = resultScript
        self.challengeMarkers = challengeMarkers
        self.linkDecoder = linkDecoder
    }
}

/// The two link decoders under test, written exactly as they are written in `SearchEngine`.
enum SpikeLinks {
    /// `https://www.bing.com/ck/a?…&u=a1<base64url of the destination>&…`
    static func bing(_ url: String) -> String? {
        guard let components = URLComponents(string: url),
              components.host?.hasSuffix("bing.com") == true,
              components.path == "/ck/a",
              let wrapped = components.queryItems?.first(where: { $0.name == "u" })?.value,
              wrapped.hasPrefix("a1")
        else {
            return nil
        }
        return base64URL(String(wrapped.dropFirst(2)))
    }

    /// `https://r.search.yahoo.com/…/RU=<percent-encoded destination>/RK=…`
    static func yahoo(_ url: String) -> String? {
        guard url.contains("search.yahoo.com"), let marker = url.range(of: "/RU=") else { return nil }
        let rest = url[marker.upperBound...]
        let end = rest.range(of: "/RK=")?.lowerBound ?? rest.endIndex
        return String(rest[..<end]).removingPercentEncoding
    }

    private static func base64URL(_ value: String) -> String? {
        var padded = value.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while padded.count % 4 != 0 { padded += "=" }
        guard let data = Data(base64Encoded: padded) else { return nil }
        return String(data: data, encoding: .utf8)
    }
}

enum SpikeEngines {
    static let userAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 14_0) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15"

    static let all: [SpikeEngine] = [
        SpikeEngine(
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
        ),
        SpikeEngine(
            id: "bing",
            name: "Bing",
            urlTemplate: "https://www.bing.com/search?q=%@&setmkt=en-US&setlang=en",
            resultScript: """
            JSON.stringify(Array.from(document.querySelectorAll('li.b_algo')).slice(0,10).map(r => ({
              url: (r.querySelector('h2 a')||{}).href || null,
              title: (r.querySelector('h2 a')||{}).innerText || null,
              snippet: (r.querySelector('.b_caption p')||{}).innerText || null,
              cite: (r.querySelector('cite')||{}).innerText || null })))
            """,
            challengeMarkers: ["captcha", "solve the challenge"],
            linkDecoder: SpikeLinks.bing
        ),
        SpikeEngine(
            id: "mojeek",
            name: "Mojeek",
            urlTemplate: "https://www.mojeek.com/search?q=%@",
            resultScript: """
            JSON.stringify(Array.from(document.querySelectorAll('ul.results-standard li')).slice(0,10).map(r => ({
              url: (r.querySelector('a.ob')||{}).href || null,
              title: (r.querySelector('a.ob')||{}).innerText || null,
              snippet: (r.querySelector('p.s')||{}).innerText || null,
              cite: null })))
            """,
            challengeMarkers: ["captcha", "automated queries", "403 - forbidden"]
        ),
        SpikeEngine(
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
                const pick = s => ((row.querySelector(s)) || {}).innerText || null;
                const lines = (row.innerText || '').split('\\n').map(t => t.trim()).filter(Boolean);
                out.push({ url: a.href,
                           title: pick('h3') || pick('[class*="title"]') || (a.innerText || '').trim() || lines[1] || lines[0] || null,
                           snippet: pick('.compText') || pick('p') || lines.slice(2).join(' ') || null,
                           cite: pick('span.fz-ms') || lines[0] || null });
                if (out.length >= 10) break;
              }
              return JSON.stringify(out);
            })()
            """,
            challengeMarkers: ["captcha", "challenge", "not a bot"],
            linkDecoder: SpikeLinks.yahoo
        ),
        SpikeEngine(
            id: "brave",
            name: "Brave",
            urlTemplate: "https://search.brave.com/search?q=%@",
            resultScript: """
            JSON.stringify(Array.from(document.querySelectorAll('[data-type="web"]')).slice(0,10).map(r => ({
              url: (r.querySelector('a')||{}).href || null,
              title: (r.querySelector('.title')||{}).innerText || null,
              snippet: (r.querySelector('.snippet-description')||{}).innerText || null })))
            """,
            challengeMarkers: ["challenge", "cf-chl"]
        ),
    ]
}

/// Drives one off-screen web view, synchronously, by pumping the run loop — a script has no
/// `await` to hand and WebKit needs the main run loop turning for anything to happen at all.
final class Spike: NSObject, WKNavigationDelegate {
    private let webView: WKWebView
    private var navigationFinished = false
    private var navigationFailure: String?

    override init() {
        webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 1200, height: 900))
        super.init()
        webView.customUserAgent = SpikeEngines.userAgent
        webView.navigationDelegate = self
    }

    /// Loads `engine`'s results page for `query`, polls its result script once a second for
    /// up to 12 attempts, and prints what it found.
    func run(_ engine: SpikeEngine, query: String, timeout: TimeInterval) {
        let deadline = Date().addingTimeInterval(timeout)
        guard let encoded = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let url = URL(string: String(format: engine.urlTemplate, encoded))
        else {
            print("\(engine.name): could not build a URL for the query")
            return
        }
        print("\(engine.name): loading \(url.absoluteString)")

        navigationFinished = false
        navigationFailure = nil
        webView.load(URLRequest(url: url))
        pump(until: { self.navigationFinished || self.navigationFailure != nil }, before: deadline)

        if let navigationFailure {
            print("\(engine.name): 0 hits — navigation failed: \(navigationFailure)")
            return
        }
        guard navigationFinished else {
            print("\(engine.name): 0 hits — page never finished loading within \(Int(timeout))s")
            return
        }

        for attempt in 0..<12 {
            if attempt > 0 {
                pump(until: { false }, before: min(Date().addingTimeInterval(1), deadline))
            }
            guard Date() < deadline else { break }
            let raw = evaluate(engine.resultScript, before: deadline) ?? ""
            let hits = Self.decode(raw)
            if !hits.isEmpty {
                let destinations = hits.map { hit -> String in
                    let raw = hit.url ?? ""
                    if let decoded = engine.linkDecoder?(raw) { return decoded }
                    return raw
                }
                let fromCite = hits.compactMap { hit -> String? in
                    guard let cite = hit.cite, cite.hasPrefix("http") else { return nil }
                    return cite
                }
                let linkedIn = destinations.filter { Self.isLinkedInProfile($0) }.count
                let linkedInFromCite = fromCite.filter { Self.isLinkedInProfile($0) }.count
                print("\(engine.name): \(hits.count) hits (after \(attempt + 1) poll(s)) — \(linkedIn) linkedin.com/in destination(s), \(linkedInFromCite) from cite text")
                for (index, hit) in hits.prefix(4).enumerated() {
                    print("    - \(hit.title ?? "<no title>")")
                    print("      raw:  \((hit.url ?? "<no url>").prefix(110))")
                    print("      dest: \(destinations[index])")
                    if let cite = hit.cite { print("      cite: \(cite)") }
                    print("      snip: \((hit.snippet ?? "<no snippet>").prefix(90))")
                }
                return
            }
        }

        let body = (evaluate("document.body.innerText", before: Date().addingTimeInterval(5)) ?? "").lowercased()
        let tripped = engine.challengeMarkers.filter { body.contains($0) }
        let title = evaluate("document.title", before: Date().addingTimeInterval(5)) ?? ""
        if tripped.isEmpty {
            print("\(engine.name): 0 hits — no challenge marker; title \"\(title)\", \(body.count) chars of body text")
        } else {
            print("\(engine.name): 0 hits — CHALLENGE (markers: \(tripped.joined(separator: ", "))); title \"\(title)\"")
        }
        print("      body starts: \(body.prefix(160).replacingOccurrences(of: "\n", with: " "))")
        let census = evaluate(Self.censusScript, before: Date().addingTimeInterval(5)) ?? "<none>"
        print("      census: \(census)")
    }

    // MARK: - Plumbing

    private struct RawHit: Decodable {
        var url: String?
        var title: String?
        var snippet: String?
        var cite: String?
    }

    private static func decode(_ json: String) -> [RawHit] {
        guard let data = json.data(using: .utf8),
              let raw = try? JSONDecoder().decode([RawHit].self, from: data)
        else {
            return []
        }
        return raw.filter { $0.url != nil && $0.title != nil }
    }

    /// Counts a handful of plausible result containers on whatever page is loaded, so a load
    /// that found nothing still says *why* — a wrong selector and a bot wall look identical
    /// from a hit count of zero.
    private static let censusScript = """
    JSON.stringify({ 'h3 a': document.querySelectorAll('h3 a').length,
      'div.algo': document.querySelectorAll('div.algo').length,
      'li.b_algo': document.querySelectorAll('li.b_algo').length,
      'ul.results-standard li': document.querySelectorAll('ul.results-standard li').length,
      'a[href*="linkedin.com/in"]': document.querySelectorAll('a[href*="linkedin.com/in"]').length,
      'a[href*="/RU="]': document.querySelectorAll('a[href*="/RU="]').length,
      firstRow: ((document.querySelector('div.algo') || document.querySelector('li.b_algo') || {}).outerHTML || '').slice(0, 600) })
    """

    /// Whether `url` is a LinkedIn member profile — the thing this query is looking for, and
    /// so the thing worth counting.
    private static func isLinkedInProfile(_ url: String) -> Bool {
        guard let host = URL(string: url)?.host?.lowercased() else { return false }
        let isLinkedIn = host == "linkedin.com" || host.hasSuffix(".linkedin.com")
        return isLinkedIn && (URL(string: url)?.path.hasPrefix("/in/") ?? false)
    }

    private func evaluate(_ script: String, before deadline: Date) -> String? {
        var done = false
        var value: String?
        webView.evaluateJavaScript(script) { result, error in
            if let error {
                print("      js error: \(error.localizedDescription)")
            }
            value = result as? String
            done = true
        }
        pump(until: { done }, before: deadline)
        return value
    }

    private func pump(until done: () -> Bool, before deadline: Date) {
        while !done() && Date() < deadline {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05))
        }
    }

    // MARK: - WKNavigationDelegate

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        navigationFinished = true
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        navigationFailure = error.localizedDescription
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        navigationFailure = error.localizedDescription
    }
}

// MARK: - Arguments

var requestedIds: [String] = []
var query = "\"Tim Cook\" site:linkedin.com/in"
var arguments = Array(CommandLine.arguments.dropFirst())
while let argument = arguments.first {
    arguments.removeFirst()
    if argument == "--query" {
        query = arguments.first ?? query
        if !arguments.isEmpty { arguments.removeFirst() }
    } else {
        requestedIds.append(argument)
    }
}

let selected = requestedIds.isEmpty
    ? SpikeEngines.all
    : SpikeEngines.all.filter { requestedIds.contains($0.id) }
guard !selected.isEmpty else {
    print("No engine matched \(requestedIds). Known: \(SpikeEngines.all.map(\.id).joined(separator: ", "))")
    exit(1)
}

let application = NSApplication.shared
application.setActivationPolicy(.prohibited)

print("query: \(query)")
let spike = Spike()
for engine in selected {
    spike.run(engine, query: query, timeout: 25)
}
