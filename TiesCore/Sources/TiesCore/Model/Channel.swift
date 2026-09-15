import Foundation

public struct Channel: Codable, Hashable, Sendable {
    public enum Kind: String, Codable, Sendable {
        case phone, email, url
    }

    public var personId: String
    public var kind: Kind
    public var label: String?
    public var value: String
    public var normalized: String

    public init(
        personId: String,
        kind: Kind,
        label: String? = nil,
        value: String,
        normalized: String
    ) {
        self.personId = personId
        self.kind = kind
        self.label = label
        self.value = value
        self.normalized = normalized
    }
}
