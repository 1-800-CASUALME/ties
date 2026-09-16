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

            do {
                fetched += 1
                let response = try await client.get(url, headers: [:])
                let (title, text) = try ReadableText.extract(html: response.text)
                guard NameMatcher.containsName(text, personName: input.fullName) else { continue }

                findings.append(ProbeFinding(
                    url: ProbeFinding.canonical(urlString),
                    pageTitle: title,
                    bodyText: text,
                    pageKind: .page,
                    evidence: [
                        EvidenceItem(kind: .name, weight: 0, detail: "Page text mentions \(input.fullName)", sourceURL: urlString),
                    ]
                ))
            } catch {
                continue
            }
        }

        return findings
    }
}
