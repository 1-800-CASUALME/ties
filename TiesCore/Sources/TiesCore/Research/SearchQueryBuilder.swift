import Foundation

/// Builds the ordered list of search-engine queries `SearchProbe` should run for a person.
///
/// Thorough asks four times: a company-scoped query first (if we know their company), then
/// site-scoped queries for LinkedIn, GitHub, and X/Twitter, then (only when we have no company
/// to scope by) a bare name query as a last resort.
///
/// Quick asks once, or twice at the outside. The company query is the one that finds people —
/// their LinkedIn, their staff page and their conference bio all name their employer — so with
/// a company known it is the only query worth the seconds; without one, the LinkedIn site
/// query takes its place. A bare name is added only for someone we know nothing else about,
/// where it is the single remaining lead rather than noise on top of better ones.
///
/// Whatever the local signals know about the person — the name they actually go by, how other
/// people address them, the title in their mail signature — is then appended as extra seed
/// queries: thorough runs all of them, quick one.
public enum SearchQueryBuilder {
    /// `[]` when `input.fullName` doesn't have at least two whitespace-separated tokens (a
    /// single name is too ambiguous to search on) and the signals hold no seed either —
    /// otherwise the ordered queries above, each appearing once.
    ///
    /// `mode` defaults to `.thorough`, so the older `queries(for:)` spelling still means what
    /// it always did.
    public static func queries(for input: ProbeInput, mode: ScanMode = .thorough) -> [String] {
        var queries = baseQueries(for: input, mode: mode)
        var seen = Set(queries)
        for seed in seedQueries(for: input, mode: mode) where seen.insert(seed).inserted {
            queries.append(seed)
        }
        return queries
    }

    /// The name-driven queries, which are all there was before local signals existed.
    private static func baseQueries(for input: ProbeInput, mode: ScanMode) -> [String] {
        let name = input.fullName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard name.split(separator: " ").count >= 2 else { return [] }

        // `companies` puts the Contacts organization first and falls back to a company read out
        // of a mail signature, so someone whose employer only ever appeared in their signature
        // still gets the query that actually finds people.
        let company = input.companies.first
        let hasCompany = company != nil

        var queries: [String] = []
        if let company {
            queries.append("\"\(name)\" \"\(company)\"")
        }

        if mode == .quick {
            if !hasCompany {
                queries.append("\"\(name)\" site:linkedin.com/in")
                // Nothing else to go on at all — no company, no email, no URL — so the bare
                // name is the only lead there is.
                if input.emails.isEmpty, input.urls.isEmpty {
                    queries.append("\"\(name)\"")
                }
            }
            return queries
        }

        queries.append("\"\(name)\" site:linkedin.com/in")
        queries.append("\"\(name)\" site:github.com")
        queries.append("\"\(name)\" (site:x.com OR site:twitter.com)")
        if !hasCompany {
            queries.append("\"\(name)\"")
        }
        return queries
    }

    /// The queries only the local signals can ask: the name the person actually goes by scoped
    /// by their company, the honorific other people address them with in front of their name
    /// (Arabic honorifics searched as they were written), and — only for a single-token name,
    /// too ambiguous to search on its own — their signature title scoped by their company.
    ///
    /// Quick mode takes the first of these and no more; thorough takes all of them.
    private static func seedQueries(for input: ProbeInput, mode: ScanMode) -> [String] {
        guard let signals = input.signals else { return [] }
        let name = input.fullName.trimmingCharacters(in: .whitespacesAndNewlines)
        let company = input.companies.first
        var seeds: [String] = []

        // An alias that is just the Contacts name again would only repeat the base query.
        for alias in cleaned(signals.aliases) where NameMatcher.normalize(alias) != NameMatcher.normalize(name) {
            if let company {
                seeds.append("\"\(alias)\" \"\(company)\"")
            } else {
                // Same reasoning as the base queries: with no company to scope by, LinkedIn is
                // where a professional is found.
                seeds.append("\"\(alias)\" site:linkedin.com/in")
            }
        }

        if !name.isEmpty {
            for honorific in cleaned(signals.honorifics) {
                seeds.append("\"\(honorific) \(name)\"")
            }
        }

        if name.split(separator: " ").count < 2, let company {
            for title in cleaned(input.titles) {
                seeds.append("\"\(title)\" \"\(company)\"")
            }
        }

        return mode == .quick ? Array(seeds.prefix(1)) : seeds
    }

    /// Trimmed, blanks dropped, each kept once.
    private static func cleaned(_ values: [String]) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for value in values {
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, seen.insert(trimmed.lowercased()).inserted else { continue }
            result.append(trimmed)
        }
        return result
    }
}
