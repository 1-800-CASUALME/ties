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
