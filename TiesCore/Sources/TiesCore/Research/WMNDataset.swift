import Foundation

/// One site entry from the WhatsMyName (WMN) dataset: a URL template to check a username
/// against, and the signals that distinguish an existing account from a missing one.
public struct WMNSite: Codable, Sendable {
    public var name: String
    public var uriCheck: String
    public var eCode: Int
    public var eString: String
    public var mString: String?
    public var mCode: Int?
    public var cat: String

    public init(name: String, uriCheck: String, eCode: Int, eString: String, mString: String?, mCode: Int?, cat: String) {
        self.name = name
        self.uriCheck = uriCheck
        self.eCode = eCode
        self.eString = eString
        self.mString = mString
        self.mCode = mCode
        self.cat = cat
    }

    enum CodingKeys: String, CodingKey {
        case name
        case uriCheck = "uri_check"
        case eCode = "e_code"
        case eString = "e_string"
        case mString = "m_string"
        case mCode = "m_code"
        case cat
    }
}

/// The bundled WhatsMyName username-enumeration dataset (CC BY-SA 4.0, Micah Hoffman —
/// see `Resources/WMN-LICENSE.txt`), plus a curated subset of "professional" sites worth
/// checking during a research run.
public struct WMNDataset: Sendable {
    public var sites: [WMNSite]

    public init(sites: [WMNSite]) {
        self.sites = sites
    }

    /// Loads and decodes the dataset copied into the package's `Resources` directory.
    public static func bundled() throws -> WMNDataset {
        guard let url = Bundle.module.url(forResource: "wmn-data", withExtension: "json", subdirectory: "Resources") else {
            throw WMNDatasetError.resourceNotFound
        }
        let data = try Data(contentsOf: url)
        let file = try JSONDecoder().decode(WMNFile.self, from: data)
        return WMNDataset(sites: file.sites)
    }

    /// Categories worth checking for a professional-identity research pass. Excludes
    /// (among others) "xx NSFW xx", "dating", and "gaming".
    private static let allowedCategories: Set<String> = [
        "social", "coding", "tech", "business", "art", "blog", "news", "finance", "music",
    ]

    /// Canonical display names, in priority order: sites most likely to carry a professional
    /// identity come first. Matched case-insensitively (ignoring punctuation/spacing) against
    /// `WMNSite.name`.
    private static let priorityNames: [String] = [
        "GitHub", "GitLab", "Medium", "Dev.to", "Behance", "Dribbble", "Stack Overflow", "Kaggle",
        "Product Hunt", "Substack", "Mastodon", "Hacker News", "Docker Hub", "npm", "PyPI",
        "Codepen", "Replit", "HackerRank", "LeetCode", "Speaker Deck", "SlideShare", "Vimeo",
        "YouTube", "Flickr", "500px", "About.me", "Linktree", "Keybase", "Gravatar", "WordPress",
    ]

    /// The sites to run a username probe against: the fixed `priorityNames` first (one match
    /// each, renamed to their canonical display name), then the remaining allowed-category
    /// sites alphabetically, capped at `limit`.
    public func professionalSites(limit: Int = 40) -> [WMNSite] {
        let pool = sites.filter { Self.allowedCategories.contains($0.cat) }
        var usedNames = Set<String>()
        var result: [WMNSite] = []

        for priorityName in Self.priorityNames {
            let target = Self.fold(priorityName)
            let candidates = pool.filter { !usedNames.contains($0.name) && Self.fold($0.name).hasPrefix(target) }
            guard let match = Self.preferred(among: candidates) else { continue }
            usedNames.insert(match.name)

            var renamed = match
            renamed.name = priorityName
            result.append(renamed)
        }

        let remaining = pool
            .filter { !usedNames.contains($0.name) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        result.append(contentsOf: remaining)

        return Array(result.prefix(limit))
    }

    /// Lowercased, letters-and-digits-only form, so "Dev.to"/"dev.to" and "Stack Overflow"/
    /// "StackOverflow" compare equal regardless of punctuation or spacing.
    private static func fold(_ s: String) -> String {
        s.lowercased().filter { $0.isLetter || $0.isNumber }
    }

    /// Among several sites whose name matches the same priority entry (e.g. "GitHub (User)"
    /// and "GitHub (Gists)"), prefers a profile/user-facing variant over the shortest name.
    private static func preferred(among candidates: [WMNSite]) -> WMNSite? {
        guard !candidates.isEmpty else { return nil }
        let preferredMarkers = ["user", "public", "profile"]
        if let marked = candidates.first(where: { site in
            let lowered = site.name.lowercased()
            return preferredMarkers.contains { lowered.contains($0) }
        }) {
            return marked
        }
        return candidates.min { $0.name.count < $1.name.count }
    }
}

public enum WMNDatasetError: Error, Sendable {
    case resourceNotFound
}

private struct WMNFile: Decodable {
    var sites: [WMNSite]
}
