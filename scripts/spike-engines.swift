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

/// One engine as the spike knows it — the same four fields `SearchEngine` carries, kept
/// here as a copy so the script stays standalone (`swift scripts/spike-engines.swift`
/// can't import `TiesCore` without building it first).
struct SpikeEngine {
    let id: String
    let name: String
    let urlTemplate: String
    let resultScript: String
    let challengeMarkers: [String]
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
            urlTemplate: "https://www.bing.com/search?q=%@",
            resultScript: """
            JSON.stringify(Array.from(document.querySelectorAll('li.b_algo')).slice(0,10).map(r => ({
              url: (r.querySelector('h2 a')||{}).href || null,
              title: (r.querySelector('h2 a')||{}).innerText || null,
              snippet: (r.querySelector('.b_caption p')||{}).innerText || null })))
            """,
            challengeMarkers: ["captcha"]
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
                print("\(engine.name): \(hits.count) hits (after \(attempt + 1) poll(s))")
                for hit in hits.prefix(3) {
                    print("    - \(hit.title ?? "<no title>")")
                    print("      \(hit.url ?? "<no url>")")
                    print("      \((hit.snippet ?? "<no snippet>").prefix(100))")
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
    }

    // MARK: - Plumbing

    private struct RawHit: Decodable {
        var url: String?
        var title: String?
        var snippet: String?
    }

    private static func decode(_ json: String) -> [RawHit] {
        guard let data = json.data(using: .utf8),
              let raw = try? JSONDecoder().decode([RawHit].self, from: data)
        else {
            return []
        }
        return raw.filter { $0.url != nil && $0.title != nil }
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
