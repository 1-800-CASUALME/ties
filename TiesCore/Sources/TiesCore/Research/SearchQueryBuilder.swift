import Foundation

/// Builds the ordered list of search-engine queries `SearchProbe` should run for a person:
/// a company-scoped query first (if we know their company), then site-scoped queries for
/// LinkedIn, GitHub, and X/Twitter, then (only when we have no company to scope by) a bare
/// name query as a last resort.
public enum SearchQueryBuilder {
    /// `[]` when `input.fullName` doesn't have at least two whitespace-separated tokens (a
    /// single name is too ambiguous to search on) — otherwise the ordered queries above.
    public static func queries(for input: ProbeInput) -> [String] {
        let name = input.fullName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard name.split(separator: " ").count >= 2 else { return [] }

        let company = input.company?.trimmingCharacters(in: .whitespacesAndNewlines)
        let hasCompany = company?.isEmpty == false

        var queries: [String] = []
        if hasCompany, let company {
            queries.append("\"\(name)\" \"\(company)\"")
        }
        queries.append("\"\(name)\" site:linkedin.com/in")
        queries.append("\"\(name)\" site:github.com")
        queries.append("\"\(name)\" (site:x.com OR site:twitter.com)")
        if !hasCompany {
            queries.append("\"\(name)\"")
        }
        return queries
    }
}
