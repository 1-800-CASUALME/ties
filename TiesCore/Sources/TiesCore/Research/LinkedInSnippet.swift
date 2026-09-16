import Foundation

/// The fields `SearchProbe` can pull out of a LinkedIn search-result title and snippet
/// without ever fetching the (scraping-hostile) LinkedIn page itself.
///
/// Title forms seen in the wild: `"Name - Headline | LinkedIn"`, `"Name - Company |
/// LinkedIn"`, `"Name - City, Country - LinkedIn"`, `"Name - Headline - Company -
/// LinkedIn"`. Snippet forms: `"Headline · Experience: Company · Education: X · Location:
/// City · N connections"`.
public struct LinkedInSnippet: Sendable, Equatable {
    public var name: String?
    public var headline: String?
    public var company: String?
    public var location: String?

    public init(name: String? = nil, headline: String? = nil, company: String? = nil, location: String? = nil) {
        self.name = name
        self.headline = headline
        self.company = company
        self.location = location
    }

    public static func parse(title: String, snippet: String) -> LinkedInSnippet {
        var segments = title
            .components(separatedBy: " - ")
            .map { $0.trimmingCharacters(in: .whitespaces) }

        // The trailing "LinkedIn" marker is either its own " - "-separated segment (drop it
        // outright) or glued onto the last real segment as " | LinkedIn" (strip the suffix).
        if let last = segments.last {
            if last == "LinkedIn" {
                segments.removeLast()
            } else if last.hasSuffix(" | LinkedIn") {
                segments[segments.count - 1] = String(last.dropLast(" | LinkedIn".count))
                    .trimmingCharacters(in: .whitespaces)
            }
        }

        let name = segments.first

        // Title segment 2 is the headline UNLESS it looks like a location (e.g. "City,
        // Country" in the "Name - City, Country - LinkedIn" form), in which case it's a
        // location fallback instead.
        var titleHeadline: String?
        var titleLocationFallback: String?
        if segments.count > 1 {
            let second = segments[1]
            if isLocationLike(second) {
                titleLocationFallback = second
            } else {
                titleHeadline = second
            }
        }

        let titleCompanyFallback = segments.count > 2 ? segments[2] : nil

        return LinkedInSnippet(
            name: name,
            headline: titleHeadline,
            company: field("Experience", in: snippet) ?? titleCompanyFallback,
            location: field("Location", in: snippet) ?? titleLocationFallback
        )
    }

    /// A title segment reads as a location when it contains a ", " (as in "City, Country")
    /// but doesn't also look like a headline or trailing marker (containing " at " or "|").
    private static func isLocationLike(_ segment: String) -> Bool {
        segment.contains(", ") && !segment.contains(" at ") && !segment.contains("|")
    }

    /// Extracts `"Label: value"` from a `"·"`-separated snippet, e.g. `"Location: Ottawa"`
    /// out of `"... · Location: Ottawa · 459 connections"`.
    private static func field(_ label: String, in snippet: String) -> String? {
        let prefix = "\(label):"
        for part in snippet.components(separatedBy: "·") {
            let trimmed = part.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix(prefix) else { continue }
            let value = trimmed.dropFirst(prefix.count).trimmingCharacters(in: .whitespaces)
            return value.isEmpty ? nil : value
        }
        return nil
    }
}
