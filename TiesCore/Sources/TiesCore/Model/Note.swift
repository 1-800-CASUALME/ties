import Foundation

public struct Note: Codable, Hashable, Sendable {
    public var personId: String
    public var body: String
    public var updatedAt: Date

    public init(
        personId: String,
        body: String,
        updatedAt: Date = .now
    ) {
        self.personId = personId
        self.body = body
        self.updatedAt = updatedAt
    }
}
