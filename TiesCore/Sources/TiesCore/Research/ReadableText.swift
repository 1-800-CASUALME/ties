import Foundation
import SwiftSoup

/// Extracts a page's title and "readable" body text — the parts a human would actually read —
/// discarding chrome like navigation, headers/footers, and scripts.
public enum ReadableText {
    private static let boilerplateSelector = "script, style, nav, header, footer, aside, noscript"
    private static let contentSelector = "p, li, h1, h2, h3"
    private static let minElementLength = 40

    /// - Parameter maxBytes: the body text is truncated to at most this many UTF-8 bytes,
    ///   on a character boundary (never splitting a multi-byte character).
    public static func extract(html: String, maxBytes: Int = 20_000) throws -> (title: String?, text: String) {
        let doc = try SwiftSoup.parse(html)
        try doc.select(boilerplateSelector).remove()

        let title = try extractTitle(doc)
        let container = try contentContainer(doc)

        var parts: [String] = []
        for element in try container.select(contentSelector).array() {
            let text = try element.text().trimmingCharacters(in: .whitespacesAndNewlines)
            if text.count >= minElementLength {
                parts.append(text)
            }
        }

        let joined = parts.joined(separator: "\n")
        return (title, truncate(joined, toByteCount: maxBytes))
    }

    private static func extractTitle(_ doc: Document) throws -> String? {
        let docTitle = try doc.title()
        if !docTitle.isEmpty { return docTitle }

        if let meta = try doc.select("meta[property=og:title]").first() {
            let content = try meta.attr("content")
            if !content.isEmpty { return content }
        }
        return nil
    }

    /// Prefers `<main>`, then `<article>`, then `<body>`, falling back to the whole document.
    private static func contentContainer(_ doc: Document) throws -> Element {
        if let main = try doc.select("main").first() { return main }
        if let article = try doc.select("article").first() { return article }
        if let body = doc.body() { return body }
        return doc
    }

    private static func truncate(_ s: String, toByteCount maxBytes: Int) -> String {
        guard s.utf8.count > maxBytes else { return s }
        guard maxBytes > 0 else { return "" }

        var end = s.startIndex
        var byteCount = 0
        for index in s.indices {
            let charByteCount = String(s[index]).utf8.count
            if byteCount + charByteCount > maxBytes { break }
            byteCount += charByteCount
            end = s.index(after: index)
        }
        return String(s[s.startIndex..<end])
    }
}
