import Foundation

/// Fetches every URL among a person's channels (skipping LinkedIn, which blocks scraping and
/// is handled separately) and keeps the ones whose readable text actually mentions the
/// person's name.
public struct PageFetchProbe: Probe {
    public let id = "page"

    public init() {}

    public func run(_ input: ProbeInput, client: any HTTPClient) async throws -> [ProbeFinding] {
        var findings: [ProbeFinding] = []

        for urlString in input.urls {
            guard let url = URL(string: urlString), let host = url.host?.lowercased() else { continue }
            guard !host.contains("linkedin.com") else { continue }

            do {
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
