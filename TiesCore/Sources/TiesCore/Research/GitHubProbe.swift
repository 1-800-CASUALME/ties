import Foundation

/// Looks a person up on GitHub two ways: resolving a GitHub profile URL already found among
/// their channels, and searching commit authorship for each of their emails.
public struct GitHubProbe: Probe {
    public let id = "github"

    private let token: String?

    public init(token: String? = nil) {
        self.token = token
    }

    public func run(_ input: ProbeInput, client: any HTTPClient) async throws -> [ProbeFinding] {
        // Keyed by lowercased login so that when the direct-URL path and the commit-search
        // path resolve the same account, the second path merges its evidence into the first
        // path's finding instead of being discarded (or producing a duplicate finding).
        var findingsByLogin: [String: ProbeFinding] = [:]
        var order: [String] = []

        func record(login: String, evidence: EvidenceItem) async throws {
            let key = login.lowercased()
            if var existing = findingsByLogin[key] {
                existing.evidence.append(evidence)
                findingsByLogin[key] = existing
                return
            }
            guard let finding = try await fetchUser(login: login, client: client) else { return }
            var withEvidence = finding
            withEvidence.evidence = [evidence]
            findingsByLogin[key] = withEvidence
            order.append(key)
        }

        for urlString in input.urls {
            guard let login = Self.githubLogin(fromURL: urlString) else { continue }
            try await record(
                login: login,
                evidence: EvidenceItem(kind: .username, weight: 1.5, detail: "GitHub profile linked from contact", sourceURL: urlString)
            )
        }

        for email in input.emails {
            guard let searchURL = URL(string: "https://api.github.com/search/commits?q=author-email:\(email)&per_page=1") else { continue }

            let response: HTTPResponse
            do {
                response = try await client.get(searchURL, headers: headers())
            } catch HTTPError.status(let code, _) where (400..<500).contains(code) {
                continue
            }

            let search = try JSONDecoder().decode(CommitSearchResponse.self, from: response.body)
            guard let login = search.items.first?.author?.login else { continue }

            try await record(
                login: login,
                evidence: EvidenceItem(kind: .emailHash, weight: 8, detail: "GitHub commits signed with \(email)", sourceURL: nil)
            )
        }

        return order.compactMap { findingsByLogin[$0] }
    }

    private func headers() -> [String: String] {
        var headers = ["Accept": "application/vnd.github+json"]
        if let token {
            headers["Authorization"] = "Bearer \(token)"
        }
        return headers
    }

    /// Fetches the GitHub profile for `login`. Carries no evidence of its own — the caller
    /// attaches whichever evidence led it here.
    private func fetchUser(login: String, client: any HTTPClient) async throws -> ProbeFinding? {
        guard let userURL = URL(string: "https://api.github.com/users/\(login)") else { return nil }

        let response: HTTPResponse
        do {
            response = try await client.get(userURL, headers: headers())
        } catch HTTPError.status(let code, _) where (400..<500).contains(code) {
            return nil
        }

        let user = try JSONDecoder().decode(GitHubUser.self, from: response.body)
        var company = user.company
        if let raw = company, raw.hasPrefix("@") {
            company = String(raw.dropFirst())
        }

        return ProbeFinding(
            url: ProbeFinding.canonical(user.htmlURL),
            displayName: user.name ?? user.login,
            company: company,
            location: user.location,
            avatarURL: user.avatarURL,
            username: user.login,
            snippet: user.bio,
            pageKind: .github,
            evidence: []
        )
    }

    /// Extracts a login from a `github.com/<login>` URL, or `nil` if the URL isn't a GitHub
    /// profile link.
    private static func githubLogin(fromURL urlString: String) -> String? {
        guard let url = URL(string: urlString), let rawHost = url.host?.lowercased() else { return nil }
        let host = rawHost.hasPrefix("www.") ? String(rawHost.dropFirst(4)) : rawHost
        guard host == "github.com" else { return nil }
        let segments = url.path.split(separator: "/").map(String.init)
        return segments.first
    }
}

private struct CommitSearchResponse: Decodable {
    struct Item: Decodable {
        struct Author: Decodable {
            var login: String?
        }
        var author: Author?
    }
    var items: [Item]
}

private struct GitHubUser: Decodable {
    var login: String
    var name: String?
    var company: String?
    var location: String?
    var bio: String?
    var avatarURL: String?
    var htmlURL: String

    enum CodingKeys: String, CodingKey {
        case login, name, company, location, bio
        case avatarURL = "avatar_url"
        case htmlURL = "html_url"
    }
}
