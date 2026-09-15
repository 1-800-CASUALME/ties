import Foundation

public struct Profile: Codable, Hashable, Sendable {
    public var personId: String
    public var facts: ProfileFacts
    public var confidence: Double
    public var providerId: String
    public var model: String?
    public var extractedAt: Date
    public var embedding: [Float]?

    public init(
        personId: String,
        facts: ProfileFacts,
        confidence: Double,
        providerId: String,
        model: String? = nil,
        extractedAt: Date = .now,
        embedding: [Float]? = nil
    ) {
        self.personId = personId
        self.facts = facts
        self.confidence = confidence
        self.providerId = providerId
        self.model = model
        self.extractedAt = extractedAt
        self.embedding = embedding
    }
}
