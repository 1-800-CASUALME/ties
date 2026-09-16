import Foundation
import CryptoKit

/// Looks a person's emails up against the Gravatar Profiles API (v3) by SHA-256 hash of the
/// normalized email address. A missing profile (404, or any other 4xx) is not an error — it
/// just means that email has no Gravatar.
public struct GravatarProbe: Probe {
    public let id = "gravatar"
    public let displayName = "Gravatar"

    private let apiKey: String?
    private let maxEmails = 3

    public init(apiKey: String? = nil) {
        self.apiKey = apiKey
    }

    public func run(_ input: ProbeInput, client: any HTTPClient) async throws -> [ProbeFinding] {
        var findings: [ProbeFinding] = []
        for email in input.emails.prefix(maxEmails) {
            guard let url = URL(string: "https://api.gravatar.com/v3/profiles/\(Self.hash(email: email))") else { continue }

            var headers: [String: String] = [:]
            if let apiKey {
                headers["Authorization"] = "Bearer \(apiKey)"
            }

            let response: HTTPResponse
            do {
                response = try await client.get(url, headers: headers)
            } catch HTTPError.status(let code, _) where (400..<500).contains(code) {
                continue
            }

            let profile = try JSONDecoder().decode(GravatarProfile.self, from: response.body)
            findings.append(Self.finding(from: profile, email: email))
        }
        return findings
    }

    /// SHA-256 hex digest of the trimmed, lowercased email address, per Gravatar's hashing spec.
    private static func hash(email: String) -> String {
        let normalized = email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let digest = SHA256.hash(data: Data(normalized.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    private static func finding(from profile: GravatarProfile, email: String) -> ProbeFinding {
        ProbeFinding(
            url: ProbeFinding.canonical(profile.profileURL),
            displayName: profile.displayName,
            headline: profile.jobTitle,
            company: profile.company,
            location: profile.location,
            avatarURL: profile.avatarURL,
            snippet: profile.description,
            pageKind: .gravatar,
            evidence: [
                EvidenceItem(
                    kind: .emailHash,
                    weight: 8,
                    detail: "Gravatar profile for \(email)",
                    sourceURL: profile.profileURL
                ),
            ],
            linkedURLs: (profile.verifiedAccounts ?? []).map { ProbeFinding.canonical($0.url) }
        )
    }
}

private struct GravatarProfile: Decodable {
    var hash: String
    var displayName: String?
    var profileURL: String
    var avatarURL: String?
    var location: String?
    var description: String?
    var jobTitle: String?
    var company: String?
    var verifiedAccounts: [VerifiedAccount]?

    struct VerifiedAccount: Decodable {
        var serviceType: String
        var serviceLabel: String
        var url: String

        enum CodingKeys: String, CodingKey {
            case serviceType = "service_type"
            case serviceLabel = "service_label"
            case url
        }
    }

    enum CodingKeys: String, CodingKey {
        case hash
        case displayName = "display_name"
        case profileURL = "profile_url"
        case avatarURL = "avatar_url"
        case location
        case description
        case jobTitle = "job_title"
        case company
        case verifiedAccounts = "verified_accounts"
    }
}
