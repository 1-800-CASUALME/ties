import Foundation

/// What the Mac already knows about a person, collected locally from Contacts, Messages,
/// WhatsApp, and Mail — never fetched from the network. One row per person, rebuilt by every
/// collection pass, and the seed for both search queries and candidate verification.
public struct LocalSignals: Codable, Hashable, Sendable {
    public var personId: String
    /// Other names the person goes by: nickname, WhatsApp push name, the name used in chats.
    public var aliases: [String]
    /// The canonical ids (`"dr"`, `"eng"`, `"prof"`) of how other people address them, so a
    /// chat reading "Eng. Sara" and a signature reading "Engineer" are one signal.
    public var honorifics: [String]
    /// The same honorifics spelled the way they were actually written — "Dr.", "دكتور",
    /// "المهندس". A canonical id is a key, not a word anybody searches for: spec §4.3 wants
    /// "<honorific> <name>" searched as written, and `"dr Sara Ahmed"` matches nothing on any
    /// engine. Kept alongside the ids rather than instead of them because the scorer and the
    /// profession rules are keyed by id.
    public var honorificsAsWritten: [String]
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
        honorificsAsWritten: [String] = [],
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
        self.honorificsAsWritten = honorificsAsWritten
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

    /// A tolerant decoder, the way `Fact` has one and for the same reason: this type is stored
    /// as free JSON in `signal.contactsSignals`, so a row written before a field existed has to
    /// keep reading rather than failing the whole row over one missing key.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        personId = try container.decodeIfPresent(String.self, forKey: .personId) ?? ""
        aliases = try container.decodeIfPresent([String].self, forKey: .aliases) ?? []
        honorifics = try container.decodeIfPresent([String].self, forKey: .honorifics) ?? []
        honorificsAsWritten = try container.decodeIfPresent([String].self, forKey: .honorificsAsWritten) ?? []
        titles = try container.decodeIfPresent([String].self, forKey: .titles) ?? []
        companies = try container.decodeIfPresent([String].self, forKey: .companies) ?? []
        links = try container.decodeIfPresent([String].self, forKey: .links) ?? []
        phones = try container.decodeIfPresent([String].self, forKey: .phones) ?? []
        emails = try container.decodeIfPresent([String].self, forKey: .emails) ?? []
        location = try container.decodeIfPresent(String.self, forKey: .location)
        lastContact = try container.decodeIfPresent(Date.self, forKey: .lastContact)
        interactions = try container.decodeIfPresent(Int.self, forKey: .interactions) ?? 0
        sources = try container.decodeIfPresent([String].self, forKey: .sources) ?? []
        collectedAt = try container.decodeIfPresent(Date.self, forKey: .collectedAt) ?? .distantPast
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
        result.honorificsAsWritten = Self.union(honorificsAsWritten, other.honorificsAsWritten)
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
