import Foundation

public struct Person: Identifiable, Codable, Hashable, Sendable {
    public enum Source: String, Codable, Sendable {
        case contacts, manual
    }

    public var id: String
    public var cnIdentifier: String?
    public var givenName: String
    public var familyName: String
    public var displayName: String
    public var organization: String?
    public var jobTitle: String?
    public var thumbnail: Data?
    public var source: Source
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        id: String = UUID().uuidString,
        cnIdentifier: String? = nil,
        givenName: String,
        familyName: String,
        displayName: String? = nil,
        organization: String? = nil,
        jobTitle: String? = nil,
        thumbnail: Data? = nil,
        source: Source = .contacts,
        createdAt: Date = .now,
        updatedAt: Date = .now
    ) {
        self.id = id
        self.cnIdentifier = cnIdentifier
        self.givenName = givenName
        self.familyName = familyName
        self.organization = organization
        self.jobTitle = jobTitle
        self.thumbnail = thumbnail
        self.source = source
        self.createdAt = createdAt
        self.updatedAt = updatedAt

        let joined = "\(givenName) \(familyName)".trimmingCharacters(in: .whitespaces)
        self.displayName = displayName ?? (joined.isEmpty ? (organization ?? "") : joined)
    }
}
