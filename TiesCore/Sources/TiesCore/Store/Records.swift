import Foundation
import GRDB

// MARK: - Enum <-> DatabaseValueConvertible

extension Person.Source: DatabaseValueConvertible {}
extension Channel.Kind: DatabaseValueConvertible {}
extension Candidate.Status: DatabaseValueConvertible {}
extension Evidence.Kind: DatabaseValueConvertible {}
extension SourcePage.Kind: DatabaseValueConvertible {}
extension Job.Kind: DatabaseValueConvertible {}
extension Job.State: DatabaseValueConvertible {}

// MARK: - Simple record conformances

extension Person: FetchableRecord, PersistableRecord {
    public static let databaseTableName = "person"
}

extension Channel: FetchableRecord, PersistableRecord {
    public static let databaseTableName = "channel"
}

extension Candidate: FetchableRecord, PersistableRecord {
    public static let databaseTableName = "candidate"
}

extension Evidence: FetchableRecord, PersistableRecord {
    public static let databaseTableName = "evidence"
}

extension SourcePage: FetchableRecord, PersistableRecord {
    public static let databaseTableName = "sourcePage"
}

extension Note: FetchableRecord, PersistableRecord {
    public static let databaseTableName = "note"
}

extension Job: FetchableRecord, PersistableRecord {
    public static let databaseTableName = "job"
}

extension Judgement: FetchableRecord, PersistableRecord {
    public static let databaseTableName = "judgement"
}

// MARK: - JSONColumn

/// SQLite has no array type, so the `[String]` fields of `LocalSignals` and `SmartList` live in
/// text columns as JSON arrays.
enum JSONColumn {
    static func encode(_ values: [String]) throws -> String {
        String(decoding: try JSONEncoder().encode(values), as: UTF8.self)
    }

    static func decode(_ text: String) throws -> [String] {
        try JSONDecoder().decode([String].self, from: Data(text.utf8))
    }
}

// MARK: - SignalRow

/// Storage representation of `LocalSignals`: every `[String]` field is a JSON text column.
struct SignalRow: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "signal"

    var personId: String
    var aliases: String
    var strongAliases: String
    var honorifics: String
    var honorificsAsWritten: String
    var titles: String
    var companies: String
    var links: String
    var phones: String
    var emails: String
    var location: String?
    var lastContact: Date?
    var interactions: Int
    var sources: String
    var collectedAt: Date
    /// The address book's contribution, as a JSON `LocalSignals` — see the `signal` table in
    /// `Migrations`. Held apart from the columns above, which a collection pass rebuilds.
    var contactsSignals: String?

    init(_ signals: LocalSignals, contactsSignals: String? = nil) throws {
        self.personId = signals.personId
        self.aliases = try JSONColumn.encode(signals.aliases)
        self.strongAliases = try JSONColumn.encode(signals.strongAliases)
        self.honorifics = try JSONColumn.encode(signals.honorifics)
        self.honorificsAsWritten = try JSONColumn.encode(signals.honorificsAsWritten)
        self.titles = try JSONColumn.encode(signals.titles)
        self.companies = try JSONColumn.encode(signals.companies)
        self.links = try JSONColumn.encode(signals.links)
        self.phones = try JSONColumn.encode(signals.phones)
        self.emails = try JSONColumn.encode(signals.emails)
        self.location = signals.location
        self.lastContact = signals.lastContact
        self.interactions = signals.interactions
        self.sources = try JSONColumn.encode(signals.sources)
        self.collectedAt = signals.collectedAt
        self.contactsSignals = contactsSignals
    }

    /// The address book's contribution, decoded. `nil` when Contacts has never had anything to
    /// say about this person.
    func contacts() throws -> LocalSignals? {
        guard let contactsSignals else { return nil }
        return try JSONDecoder().decode(LocalSignals.self, from: Data(contactsSignals.utf8))
    }

    func asSignals() throws -> LocalSignals {
        LocalSignals(
            personId: personId,
            aliases: try JSONColumn.decode(aliases),
            strongAliases: try JSONColumn.decode(strongAliases),
            honorifics: try JSONColumn.decode(honorifics),
            honorificsAsWritten: try JSONColumn.decode(honorificsAsWritten),
            titles: try JSONColumn.decode(titles),
            companies: try JSONColumn.decode(companies),
            links: try JSONColumn.decode(links),
            phones: try JSONColumn.decode(phones),
            emails: try JSONColumn.decode(emails),
            location: location,
            lastContact: lastContact,
            interactions: interactions,
            sources: try JSONColumn.decode(sources),
            collectedAt: collectedAt
        )
    }
}

// MARK: - SmartListRow

/// Storage representation of `SmartList`: `personIds` is a JSON text column.
struct SmartListRow: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "smartList"

    var id: String
    var name: String
    var systemImage: String
    var personIds: String
    var createdAt: Date

    init(_ list: SmartList) throws {
        self.id = list.id
        self.name = list.name
        self.systemImage = list.systemImage
        self.personIds = try JSONColumn.encode(list.personIds)
        self.createdAt = list.createdAt
    }

    func asSmartList() throws -> SmartList {
        SmartList(
            id: id,
            name: name,
            systemImage: systemImage,
            personIds: try JSONColumn.decode(personIds),
            createdAt: createdAt
        )
    }
}

// MARK: - ProfileRow

/// Storage representation of `Profile`: `facts` is stored as JSON text, and
/// `embedding` is stored as little-endian Float32 `Data`, since `Profile`
/// itself is a public model type that must not carry GRDB conformance.
struct ProfileRow: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "profile"

    var personId: String
    var facts: String
    var confidence: Double
    var providerId: String
    var model: String?
    var extractedAt: Date
    var embedding: Data?

    static func encodeEmbedding(_ v: [Float]) -> Data {
        v.withUnsafeBufferPointer { Data(buffer: $0) }
    }

    static func decodeEmbedding(_ d: Data) -> [Float] {
        d.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
    }

    init(personId: String, facts: String, confidence: Double, providerId: String, model: String?, extractedAt: Date, embedding: Data?) {
        self.personId = personId
        self.facts = facts
        self.confidence = confidence
        self.providerId = providerId
        self.model = model
        self.extractedAt = extractedAt
        self.embedding = embedding
    }

    init(_ profile: Profile) throws {
        self.personId = profile.personId
        self.facts = String(decoding: try JSONEncoder().encode(profile.facts), as: UTF8.self)
        self.confidence = profile.confidence
        self.providerId = profile.providerId
        self.model = profile.model
        self.extractedAt = profile.extractedAt
        self.embedding = profile.embedding.map(Self.encodeEmbedding)
    }

    func asProfile() throws -> Profile {
        let decodedFacts = try JSONDecoder().decode(ProfileFacts.self, from: Data(facts.utf8))
        return Profile(
            personId: personId,
            facts: decodedFacts,
            confidence: confidence,
            providerId: providerId,
            model: model,
            extractedAt: extractedAt,
            embedding: embedding.map(Self.decodeEmbedding)
        )
    }
}
