import Foundation

/// A single piece of evidence backing a `ProbeFinding` — e.g. "this email's Gravatar hash
/// resolved to this profile" — carrying the weight a scorer should give it.
public struct EvidenceItem: Sendable, Hashable {
    public var kind: Evidence.Kind
    public var weight: Double
    public var detail: String
    public var sourceURL: String?

    public init(kind: Evidence.Kind, weight: Double, detail: String, sourceURL: String? = nil) {
        self.kind = kind
        self.weight = weight
        self.detail = detail
        self.sourceURL = sourceURL
    }
}

/// A candidate identity or page a `Probe` turned up for a person, with whatever profile
/// details and evidence it could extract.
public struct ProbeFinding: Sendable, Hashable {
    /// Identity URL, canonical (lowercased scheme/host, no leading `www.`, no query/fragment,
    /// no trailing slash) — see `ProbeFinding.canonical(_:)`.
    public var url: String
    public var displayName: String?
    public var headline: String?
    public var company: String?
    public var location: String?
    public var avatarURL: String?
    public var username: String?
    public var pageTitle: String?
    public var snippet: String?
    public var bodyText: String?
    public var pageKind: SourcePage.Kind
    public var evidence: [EvidenceItem]
    /// Other identity URLs this finding vouches for (e.g. Gravatar verified accounts). Also
    /// canonical.
    public var linkedURLs: [String]

    public init(
        url: String,
        displayName: String? = nil,
        headline: String? = nil,
        company: String? = nil,
        location: String? = nil,
        avatarURL: String? = nil,
        username: String? = nil,
        pageTitle: String? = nil,
        snippet: String? = nil,
        bodyText: String? = nil,
        pageKind: SourcePage.Kind,
        evidence: [EvidenceItem],
        linkedURLs: [String] = []
    ) {
        self.url = url
        self.displayName = displayName
        self.headline = headline
        self.company = company
        self.location = location
        self.avatarURL = avatarURL
        self.username = username
        self.pageTitle = pageTitle
        self.snippet = snippet
        self.bodyText = bodyText
        self.pageKind = pageKind
        self.evidence = evidence
        self.linkedURLs = linkedURLs
    }

    /// Lowercases the scheme and host, strips a leading `www.`, drops the query and fragment,
    /// and removes a trailing slash from the path. Falls back to the original string when it
    /// isn't a valid URL.
    public static func canonical(_ s: String) -> String {
        guard var components = URLComponents(string: s) else { return s }

        if let scheme = components.scheme {
            components.scheme = scheme.lowercased()
        }
        if let host = components.host {
            var host = host.lowercased()
            if host.hasPrefix("www.") {
                host = String(host.dropFirst(4))
            }
            components.host = host
        }
        components.query = nil
        components.fragment = nil

        var path = components.path
        if path.count > 1, path.hasSuffix("/") {
            path.removeLast()
        }
        components.path = path

        return components.string ?? s
    }
}
