import Foundation

public struct SourcePage: Identifiable, Codable, Hashable, Sendable {
    public enum Kind: String, Codable, Sendable {
        case gravatar, github, serp, page, username
    }

    public var id: String
    public var candidateId: String
    public var url: String
    public var title: String?
    public var snippet: String?
    public var bodyText: String?
    public var fetchedAt: Date
    public var kind: Kind

    public init(
        id: String = UUID().uuidString,
        candidateId: String,
        url: String,
        title: String? = nil,
        snippet: String? = nil,
        bodyText: String? = nil,
        fetchedAt: Date = .now,
        kind: Kind
    ) {
        self.id = id
        self.candidateId = candidateId
        self.url = url
        self.title = title
        self.snippet = snippet
        self.bodyText = bodyText
        self.fetchedAt = fetchedAt
        self.kind = kind
    }
}
