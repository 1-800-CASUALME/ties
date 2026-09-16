import Foundation

public struct Candidate: Identifiable, Codable, Hashable, Sendable {
    public enum Status: String, Codable, Sendable {
        case auto, pending, accepted, rejected
    }

    public var id: String
    public var personId: String
    public var score: Double
    public var status: Status
    public var displayName: String?
    public var headline: String?
    public var company: String?
    public var location: String?
    public var avatarURL: String?
    public var primaryURL: String

    public init(
        id: String = UUID().uuidString,
        personId: String,
        score: Double,
        status: Status,
        displayName: String? = nil,
        headline: String? = nil,
        company: String? = nil,
        location: String? = nil,
        avatarURL: String? = nil,
        primaryURL: String
    ) {
        self.id = id
        self.personId = personId
        self.score = score
        self.status = status
        self.displayName = displayName
        self.headline = headline
        self.company = company
        self.location = location
        self.avatarURL = avatarURL
        self.primaryURL = primaryURL
    }
}
