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
public enum SearchQueryBuilder {
    /// `[]` when `input.fullName` doesn't have at least two whitespace-separated tokens (a
    /// single name is too ambiguous to search on) — otherwise the ordered queries above.
    ///
    /// `mode` defaults to `.thorough`, so the older `queries(for:)` spelling still means what
    /// it always did.
    public static func queries(for input: ProbeInput, mode: ScanMode = .thorough) -> [String] {
        let name = input.fullName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard name.split(separator: " ").count >= 2 else { return [] }

        let company = input.company?.trimmingCharacters(in: .whitespacesAndNewlines)
        let hasCompany = company?.isEmpty == false

        var queries: [String] = []
        if hasCompany, let company {
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
}
