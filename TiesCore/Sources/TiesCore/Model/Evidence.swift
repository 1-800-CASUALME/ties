import Foundation

public struct Evidence: Identifiable, Codable, Hashable, Sendable {
    public enum Kind: String, Codable, Sendable {
        case emailHash, phone, company, location, name, username, avatar, conflict
    }

    public var id: String
    public var candidateId: String
    public var kind: Kind
    public var weight: Double
    public var detail: String
    public var sourceURL: String?

    public init(
        id: String = UUID().uuidString,
        candidateId: String,
        kind: Kind,
        weight: Double,
        detail: String,
        sourceURL: String? = nil
    ) {
        self.id = id
        self.candidateId = candidateId
        self.kind = kind
        self.weight = weight
        self.detail = detail
        self.sourceURL = sourceURL
    }
}
