import Foundation

/// Fetches the URLs among a person's channels (skipping LinkedIn, which blocks scraping and
/// is handled separately) and keeps the ones whose readable text actually mentions the
/// person's name.
public struct PageFetchProbe: Probe {
    public let id = "page"
    public let displayName = "their pages"

    /// How many pages are worth fetching for one person. Every page is a full download and a
    /// text extraction, so a contact with a dozen links can cost more than all the searches
    /// put together; a quick run reads the first few and leaves the rest.
    private let maxPages: Int

    public init(maxPages: Int = .max) {
        self.maxPages = maxPages
    }

    public func run(_ input: ProbeInput, client: any HTTPClient) async throws -> [ProbeFinding] {
        var findings: [ProbeFinding] = []
        var fetched = 0

        for urlString in input.urls {
            guard fetched < maxPages else { break }
            guard let url = URL(string: urlString), let host = url.host?.lowercased() else { continue }
            guard !host.contains("linkedin.com") else { continue }

            fetched += 1
            guard let page = await readable(url, client: client) else { continue }
            // A URL on a contact card is only evidence if the page it leads to is about the
            // person — a company's home page is on many cards and identifies nobody.
            guard NameMatcher.containsName(page.text, personName: input.fullName) else { continue }

            findings.append(ProbeFinding(
                url: ProbeFinding.canonical(urlString),
                pageTitle: page.title,
                bodyText: page.text,
                pageKind: .page,
                evidence: [
                    EvidenceItem(kind: .name, weight: 0, detail: "Page text mentions \(input.fullName)", sourceURL: urlString),
                ]
            ))
        }

        return findings
    }

    /// Fetches links the person shared or signed with themselves, in the order given.
    ///
    /// These aren't pages that happen to mention the person — they are pages the person pointed
    /// at — so neither the name gate nor the LinkedIn skip that `run(_:client:)` applies belongs
    /// here, and a URL that can't be read comes back as a finding all the same: what makes it
    /// evidence is the link itself, which `CandidateScorer` scores as `.selfLink`, not anything
    /// written on the page.
    public func fetchDirect(urls: [String], input: ProbeInput, client: any HTTPClient) async -> [ProbeFinding] {
        var findings: [ProbeFinding] = []

        for urlString in urls.prefix(maxPages) {
            guard let url = URL(string: urlString), let host = url.host?.lowercased() else { continue }

            // LinkedIn blocks scraping, so there is nothing to read; the URL is still theirs.
            let page = host.contains("linkedin.com") ? nil : await readable(url, client: client)
            let mentionsName = page.map { NameMatcher.containsName($0.text, personName: input.fullName) } ?? false

            findings.append(ProbeFinding(
                url: ProbeFinding.canonical(urlString),
                pageTitle: page?.title,
                bodyText: page?.text,
                pageKind: .page,
                evidence: mentionsName
                    ? [EvidenceItem(kind: .name, weight: 0, detail: "Page text mentions \(input.fullName)", sourceURL: urlString)]
                    : []
            ))
        }

        return findings
    }

    /// Downloads a page and extracts its readable text, or `nil` if either step fails.
    private func readable(_ url: URL, client: any HTTPClient) async -> (title: String?, text: String)? {
        guard let response = try? await client.get(url, headers: [:]),
              let page = try? ReadableText.extract(html: response.text) else { return nil }
        return page
    }
}
