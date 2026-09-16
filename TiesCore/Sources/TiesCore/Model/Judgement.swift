import Foundation

/// A provider's verdict on whether the best candidate for a person is really them: the
/// confidence it settled on and the reason it gave. One row per person — the latest judgement
/// replaces the previous one.
public struct Judgement: Codable, Hashable, Sendable {
    public var personId: String
    public var candidateId: String
    public var confidence: Double
    public var reason: String
    public var providerId: String
    public var judgedAt: Date

    public init(
        personId: String,
        candidateId: String,
        confidence: Double,
        reason: String,
        providerId: String,
        judgedAt: Date = .now
    ) {
        self.personId = personId
        self.candidateId = candidateId
        self.confidence = confidence
        self.reason = reason
        self.providerId = providerId
        self.judgedAt = judgedAt
    }
}
