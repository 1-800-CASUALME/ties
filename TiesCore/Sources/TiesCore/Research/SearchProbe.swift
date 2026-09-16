import Foundation

/// Runs `SearchQueryBuilder`'s queries against a `SearchBackend` and turns the hits into
/// findings: LinkedIn results (never fetched — LinkedIn blocks scraping) are parsed with
/// `LinkedInSnippet`; GitHub/X/Twitter and other results keep their search-result title and
/// snippet as-is, with a username pulled from the URL path where applicable.
public struct SearchProbe: Probe {
    public let id = "search"

    private let backend: any SearchBackend

    public init(backend: any SearchBackend) {
        self.backend = backend
    }

    public func run(_ input: ProbeInput, client: any HTTPClient) async throws -> [ProbeFinding] {
        let queries = SearchQueryBuilder.queries(for: input)
        guard !queries.isEmpty else { return [] }

        var findings: [ProbeFinding] = []
        for query in queries {
            let hits: [SearchHit]
            do {
                hits = try await backend.search(query)
            } catch SearchBackendError.challenge {
                // The backend hit a bot wall — rethrow so the scanner can back off instead of
                // continuing to hammer it with the remaining queries.
                throw SearchBackendError.challenge
            } catch {
                // Any other per-query failure (timeout, transport, unauthorized) doesn't stop
                // the other queries from running.
                continue
            }

            for hit in hits {
                if let finding = Self.finding(for: hit, input: input) {
                    findings.append(finding)
                }
            }
        }
        return findings
    }

    private static let usernameHosts: Set<String> = ["github.com", "x.com", "twitter.com"]

    private static func finding(for hit: SearchHit, input: ProbeInput) -> ProbeFinding? {
        if isLinkedInProfile(hit.url) {
            return linkedInFinding(for: hit, input: input)
        }
        return generalFinding(for: hit, input: input)
    }

    private static func linkedInFinding(for hit: SearchHit, input: ProbeInput) -> ProbeFinding? {
        let snippet = LinkedInSnippet.parse(title: hit.title, snippet: hit.snippet)

        let nameMatches = snippet.name.map {
            NameMatcher.similarity(personName: input.fullName, candidateName: $0) >= NameMatcher.gate
        } ?? false
        let companyMatched = linkedInCompanyMatches(candidate: snippet.company, input: input)
        guard nameMatches || companyMatched else { return nil }

        return ProbeFinding(
            url: ProbeFinding.canonical(hit.url),
            displayName: snippet.name,
            headline: snippet.headline,
            company: snippet.company,
            location: snippet.location,
            pageTitle: hit.title,
            snippet: hit.snippet,
            bodyText: nil,
            pageKind: .serp,
            evidence: evidence(companyMatched: companyMatched, hit: hit, input: input)
        )
    }

    private static func generalFinding(for hit: SearchHit, input: ProbeInput) -> ProbeFinding? {
        let combinedText = "\(hit.title) \(hit.snippet)"
        let nameMatches = NameMatcher.containsName(combinedText, personName: input.fullName)
        let companyMatched = companyMentioned(in: combinedText, input: input)
        guard nameMatches || companyMatched else { return nil }

        return ProbeFinding(
            url: ProbeFinding.canonical(hit.url),
            username: username(fromURL: hit.url),
            pageTitle: hit.title,
            snippet: hit.snippet,
            pageKind: .serp,
            evidence: evidence(companyMatched: companyMatched, hit: hit, input: input)
        )
    }

    private static func evidence(companyMatched: Bool, hit: SearchHit, input: ProbeInput) -> [EvidenceItem] {
        var evidence = [EvidenceItem(kind: .name, weight: 0, detail: "Search result", sourceURL: hit.url)]
        if companyMatched {
            evidence.append(EvidenceItem(
                kind: .company,
                weight: 3,
                detail: "Company matches \(input.company ?? "")",
                sourceURL: hit.url
            ))
        }
        return evidence
    }

    /// True when the LinkedIn snippet's parsed company field matches `input.company` closely
    /// enough (normalized Jaro-Winkler >= 0.9) to count as corroborating evidence. LinkedIn
    /// hits have a separately parsed company field to compare against, so this uses a fuzzy
    /// whole-string match rather than a substring search.
    private static func linkedInCompanyMatches(candidate: String?, input: ProbeInput) -> Bool {
        guard let inputCompany = input.company, let candidate else { return false }
        let a = NameMatcher.normalize(candidate)
        let b = NameMatcher.normalize(inputCompany)
        guard !a.isEmpty, !b.isEmpty else { return false }
        return NameMatcher.jaroWinkler(a, b) >= 0.9
    }

    /// True when `input.company` (normalized, and at least 3 characters — to avoid a trivially
    /// short company name spuriously matching unrelated text) occurs as a substring of `text`
    /// (also normalized), e.g. "...Senior Engineer at Acme Corp..." mentioning "Acme Corp".
    /// Used for non-LinkedIn hits, which have no separately parsed company field — just the
    /// hit's own title+snippet text — to compare against.
    private static func companyMentioned(in text: String, input: ProbeInput) -> Bool {
        guard let inputCompany = input.company else { return false }
        let normalizedCompany = NameMatcher.normalize(inputCompany)
        guard normalizedCompany.count >= 3 else { return false }
        return NameMatcher.normalize(text).contains(normalizedCompany)
    }

    private static func isLinkedInProfile(_ urlString: String) -> Bool {
        guard let url = URL(string: urlString), let host = normalizedHost(url) else { return false }
        let isLinkedInHost = host == "linkedin.com" || host.hasSuffix(".linkedin.com")
        return isLinkedInHost && url.path.hasPrefix("/in/")
    }

    /// The first path component of `github.com`/`x.com`/`twitter.com` URLs, lowercased —
    /// `nil` for any other host.
    private static func username(fromURL urlString: String) -> String? {
        guard let url = URL(string: urlString), let host = normalizedHost(url), usernameHosts.contains(host) else {
            return nil
        }
        return url.path.split(separator: "/").first.map { $0.lowercased() }
    }

    private static func normalizedHost(_ url: URL) -> String? {
        guard let rawHost = url.host?.lowercased() else { return nil }
        return rawHost.hasPrefix("www.") ? String(rawHost.dropFirst(4)) : rawHost
    }
}
