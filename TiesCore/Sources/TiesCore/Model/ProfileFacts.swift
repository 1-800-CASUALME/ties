import Foundation

public struct Fact: Codable, Hashable, Sendable {
    public var text: String
    public var sources: [String]

    public init(text: String, sources: [String] = []) {
        self.text = text
        self.sources = sources
    }
}

public struct ProfileFacts: Codable, Hashable, Sendable {
    public var occupation: String?
    public var summary: String?
    public var companies: [Fact]
    public var achievements: [Fact]
    public var certificates: [Fact]
    public var experience: [Fact]
    public var canHelpWith: [String]

    public init(
        occupation: String? = nil,
        summary: String? = nil,
        companies: [Fact] = [],
        achievements: [Fact] = [],
        certificates: [Fact] = [],
        experience: [Fact] = [],
        canHelpWith: [String] = []
    ) {
        self.occupation = occupation
        self.summary = summary
        self.companies = companies
        self.achievements = achievements
        self.certificates = certificates
        self.experience = experience
        self.canHelpWith = canHelpWith
    }

    public static let empty = ProfileFacts()

    public var isEmpty: Bool {
        let occupationIsBlank = (occupation ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let summaryIsBlank = (summary ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        return occupationIsBlank
            && summaryIsBlank
            && companies.isEmpty
            && achievements.isEmpty
            && certificates.isEmpty
            && experience.isEmpty
            && canHelpWith.isEmpty
    }

    public var searchableText: String {
        var parts: [String] = []
        if let occupation { parts.append(occupation) }
        if let summary { parts.append(summary) }
        parts += (companies + achievements + certificates + experience).map(\.text)
        parts += canHelpWith
        return parts.joined(separator: "\n")
    }
}
