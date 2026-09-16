import Foundation
import SwiftSoup

/// Checks whether a person's derived username candidates exist on a curated set of
/// professional sites from the WhatsMyName dataset, gating each apparent hit on the page's
/// title actually matching the person's name (to rule out generic "not found" pages that
/// still return a 200, and unrelated accounts that merely share the username).
public struct UsernameProbe: Probe {
    public let id = "username"
    public let displayName = "username sites"

    private let dataset: WMNDataset
    private let maxSites: Int
    private let maxUsernames: Int
    /// At most this many site checks run concurrently.
    private let maxInFlight = 2

    public init(dataset: WMNDataset, maxSites: Int = 40, maxUsernames: Int = 4) {
        self.dataset = dataset
        self.maxSites = maxSites
        self.maxUsernames = maxUsernames
    }

    public func run(_ input: ProbeInput, client: any HTTPClient) async throws -> [ProbeFinding] {
        let usernames = Array(UsernameDeriver.candidates(
            givenName: input.person.givenName,
            familyName: input.person.familyName,
            emails: input.emails,
            urls: input.urls
        ).prefix(maxUsernames))
        guard !usernames.isEmpty else { return [] }

        let sites = dataset.professionalSites(limit: maxSites)
        var tasks: [(site: WMNSite, username: String)] = []
        for site in sites {
            for username in usernames {
                tasks.append((site, username))
            }
        }

        let personName = input.fullName
        var findings: [ProbeFinding] = []

        try await withThrowingTaskGroup(of: ProbeFinding?.self) { group in
            var index = 0
            var inFlight = 0

            func launchNext() {
                guard index < tasks.count else { return }
                let task = tasks[index]
                index += 1
                inFlight += 1
                group.addTask {
                    await Self.check(site: task.site, username: task.username, personName: personName, client: client)
                }
            }

            while inFlight < maxInFlight, index < tasks.count {
                launchNext()
            }

            while let result = try await group.next() {
                inFlight -= 1
                if let result {
                    findings.append(result)
                }
                launchNext()
            }
        }

        return findings
    }

    /// Fetches one (site, username) pair; returns a finding only if the site's existence
    /// signal fires and the page title matches the person's name. Individual failures
    /// (network errors, non-matching sites) are swallowed, not propagated.
    private static func check(site: WMNSite, username: String, personName: String, client: any HTTPClient) async -> ProbeFinding? {
        let urlString = site.uriCheck.replacingOccurrences(of: "{account}", with: username)
        guard let url = URL(string: urlString) else { return nil }

        do {
            let response = try await client.get(url, headers: [:])
            guard response.status == site.eCode else { return nil }

            let body = response.text
            guard body.contains(site.eString) else { return nil }
            if let mString = site.mString, !mString.isEmpty, body.contains(mString) { return nil }

            let doc = try SwiftSoup.parse(body)
            let title = try doc.title()

            let candidateName: String?
            let matched: Bool
            if !title.isEmpty {
                let name = titleBeforeSeparator(title)
                candidateName = name
                matched = NameMatcher.similarity(personName: personName, candidateName: name) >= NameMatcher.gate
            } else {
                // JSON-API style checks (e.g. GitHub's /users/{account}, Docker Hub's
                // /v2/users/ endpoint) have no <title>. Fall back to checking whether the
                // body mentions the person's name — first stripping the queried username
                // itself, so an API that merely echoes the account back (e.g. a "login"
                // field) doesn't trivially satisfy the check regardless of who actually
                // owns the account.
                candidateName = nil
                let bodyWithoutUsername = body.replacingOccurrences(of: username, with: "", options: .caseInsensitive)
                matched = NameMatcher.containsName(bodyWithoutUsername, personName: personName)
            }
            guard matched else { return nil }

            return ProbeFinding(
                url: ProbeFinding.canonical(urlString),
                displayName: candidateName,
                username: username,
                pageTitle: title.isEmpty ? nil : title,
                pageKind: .username,
                evidence: [
                    EvidenceItem(
                        kind: .username,
                        weight: 3,
                        detail: "\(site.name) profile matches username \(username)",
                        sourceURL: urlString
                    ),
                ]
            )
        } catch {
            return nil
        }
    }

    private static let titleSeparators = [" | ", " - ", " – ", " — ", " · "]

    /// The portion of a page title before the first known separator (e.g. "Sara Ahmed" from
    /// "Sara Ahmed | Dribbble"), or the whole title if no separator is present.
    private static func titleBeforeSeparator(_ title: String) -> String {
        var earliest: Range<String.Index>?
        for separator in titleSeparators {
            guard let range = title.range(of: separator) else { continue }
            if earliest == nil || range.lowerBound < earliest!.lowerBound {
                earliest = range
            }
        }
        guard let earliest else { return title }
        return String(title[title.startIndex..<earliest.lowerBound])
    }
}
