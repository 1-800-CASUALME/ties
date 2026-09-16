import Foundation

public struct Evidence: Identifiable, Codable, Hashable, Sendable {
    public enum Kind: String, Codable, Sendable {
        case emailHash, phone, company, location, name, username, avatar, conflict
        /// The candidate's URL is one the person shared or signed with themselves.
        case selfLink = "self_link"
        /// The candidate's display name matches an alias the person actually goes by, rather
        /// than the name stored in Contacts.
        case selfName = "self_name"
        /// The candidate's headline matches a job title from the person's mail signature.
        case signatureTitle = "signature_title"
        /// The candidate's headline or snippet names a profession implied by an honorific
        /// other people use for the person ("Dr" → doctor, physician, PhD).
        case honorific
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
