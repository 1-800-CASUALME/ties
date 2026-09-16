import Foundation

public struct Job: Identifiable, Codable, Hashable, Sendable {
    public enum Kind: String, Codable, Sendable {
        case scan, extract
    }

    public enum State: String, Codable, Sendable {
        case queued, running, done, failed, skipped
    }

    public var id: String
    public var kind: Kind
    public var personId: String
    public var state: State
    public var error: String?
    public var updatedAt: Date

    public init(
        id: String = UUID().uuidString,
        kind: Kind,
        personId: String,
        state: State,
        error: String? = nil,
        updatedAt: Date = .now
    ) {
        self.id = id
        self.kind = kind
        self.personId = personId
        self.state = state
        self.error = error
        self.updatedAt = updatedAt
    }
}
