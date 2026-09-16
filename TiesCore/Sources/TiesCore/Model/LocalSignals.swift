import Foundation

/// What the Mac already knows about a person, collected locally from Contacts, Messages,
/// WhatsApp, and Mail — never fetched from the network. One row per person, rebuilt by every
/// collection pass, and the seed for both search queries and candidate verification.
public struct LocalSignals: Codable, Hashable, Sendable {
    public var personId: String
    /// Other names the person goes by: nickname, WhatsApp push name, the name used in chats.
    public var aliases: [String]
    /// "Dr", "Eng", "Prof", "دكتور", "مهندس" — how other people address them.
    public var honorifics: [String]
    /// Job titles read out of mail signatures.
    public var titles: [String]
    public var companies: [String]
    /// Canonical URLs the person shared or signed with.
    public var links: [String]
    public var phones: [String]
    public var emails: [String]
    public var location: String?
    /// The most recent message or mail in either direction.
    public var lastContact: Date?
    /// Messages plus mails in the last 365 days.
    public var interactions: Int
    /// Which collectors contributed: "contacts" | "messages" | "whatsapp" | "mail".
    public var sources: [String]
    public var collectedAt: Date

    public init(
        personId: String,
        aliases: [String] = [],
        honorifics: [String] = [],
        titles: [String] = [],
        companies: [String] = [],
        links: [String] = [],
        phones: [String] = [],
        emails: [String] = [],
        location: String? = nil,
        lastContact: Date? = nil,
        interactions: Int = 0,
        sources: [String] = [],
        collectedAt: Date = .now
    ) {
        self.personId = personId
        self.aliases = aliases
        self.honorifics = honorifics
        self.titles = titles
        self.companies = companies
        self.links = links
        self.phones = phones
        self.emails = emails
        self.location = location
        self.lastContact = lastContact
        self.interactions = interactions
        self.sources = sources
        self.collectedAt = collectedAt
    }

    /// True when nothing here can seed a search or verify a candidate. Phones, emails,
    /// `lastContact`, and `interactions` deliberately don't count: they describe the
    /// relationship, not the person's public identity.
    public var isEmpty: Bool {
        aliases.isEmpty
            && honorifics.isEmpty
            && titles.isEmpty
            && companies.isEmpty
            && links.isEmpty
            && (location ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// A copy with everything that describes the user's private relationship with this person
    /// stripped out — safe to hand to a provider or put in a search query.
    public var publicSafe: LocalSignals {
        var copy = self
        copy.phones = []
        copy.emails = []
        copy.lastContact = nil
        copy.interactions = 0
        return copy
    }

    /// Combines two collection passes for the same person: arrays union (this one's order first,
    /// then whatever `other` adds), the later `lastContact` wins, and interaction counts add up.
    /// Keeps this signal's `personId`, so merging a signal collected under another id doesn't
    /// move the row.
    public func merged(with other: LocalSignals) -> LocalSignals {
        var result = self
        result.aliases = Self.union(aliases, other.aliases)
        result.honorifics = Self.union(honorifics, other.honorifics)
        result.titles = Self.union(titles, other.titles)
        result.companies = Self.union(companies, other.companies)
        result.links = Self.union(links, other.links)
        result.phones = Self.union(phones, other.phones)
        result.emails = Self.union(emails, other.emails)
        result.sources = Self.union(sources, other.sources)
        result.location = location ?? other.location
        result.lastContact = [lastContact, other.lastContact].compactMap(\.self).max()
        result.interactions = interactions + other.interactions
        result.collectedAt = max(collectedAt, other.collectedAt)
        return result
    }

    /// `a` followed by the members of `b` it doesn't already contain, each kept once.
    private static func union(_ a: [String], _ b: [String]) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for value in a + b where seen.insert(value).inserted {
            result.append(value)
        }
        return result
    }
}
