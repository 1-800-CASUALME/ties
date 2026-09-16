import Foundation

/// Derives plausible social/web usernames for a person from their contact details, to use as
/// search seeds. Order reflects confidence: email local-parts are the strongest signal, then
/// handles scraped from known profile URLs, then generated name patterns.
public enum UsernameDeriver {
    private static let maxCandidates = 8
    private static let minLength = 3
    private static let genericNames: Set<String> = [
        "info", "admin", "contact", "hello", "mail", "me", "support", "sales", "office",
    ]

    /// Hosts (without a leading "www.") whose first path segment (or, for LinkedIn/Medium, the
    /// segment after their fixed prefix) is a profile handle.
    private static let simpleHandleHosts: Set<String> = ["github.com", "x.com", "twitter.com", "instagram.com"]

    public static func candidates(givenName: String, familyName: String, emails: [String], urls: [String]) -> [String] {
        var ordered: [String] = []

        for email in emails {
            ordered.append(contentsOf: localPartCandidates(email))
        }

        for url in urls {
            if let handle = handle(fromURL: url) {
                ordered.append(handle)
            }
        }

        let given = givenName.lowercased()
        let family = familyName.lowercased()
        if !given.isEmpty && !family.isEmpty {
            ordered.append("\(given).\(family)")
            ordered.append("\(given)\(family)")
            ordered.append("\(given.prefix(1))\(family)")
            ordered.append("\(given)_\(family)")
        }

        var seen = Set<String>()
        var result: [String] = []
        for raw in ordered {
            let candidate = raw.lowercased()
            guard candidate.count >= minLength else { continue }
            guard !genericNames.contains(candidate) else { continue }
            guard !seen.contains(candidate) else { continue }
            seen.insert(candidate)
            result.append(candidate)
            if result.count == maxCandidates { break }
        }
        return result
    }

    /// The local-part(s) of an email address, minus any `+tag`, lowercase. When the local part
    /// contains dots, both the dotted form and the undotted form are emitted (dotted first).
    private static func localPartCandidates(_ email: String) -> [String] {
        guard let atIndex = email.firstIndex(of: "@") else { return [] }
        var local = String(email[email.startIndex..<atIndex])
        if let plusIndex = local.firstIndex(of: "+") {
            local = String(local[local.startIndex..<plusIndex])
        }
        local = local.lowercased()
        guard !local.isEmpty else { return [] }
        if local.contains(".") {
            return [local, local.replacingOccurrences(of: ".", with: "")]
        }
        return [local]
    }

    /// Extracts a profile handle from a known social/profile URL, or `nil` if the URL doesn't
    /// match a recognized host/path shape.
    private static func handle(fromURL urlString: String) -> String? {
        guard let url = URL(string: urlString), let rawHost = url.host?.lowercased() else { return nil }
        let host = rawHost.hasPrefix("www.") ? String(rawHost.dropFirst(4)) : rawHost

        let segments = url.path.split(separator: "/").map(String.init)
        guard !segments.isEmpty else { return nil }

        if simpleHandleHosts.contains(host) {
            return segments[0]
        }
        if host == "linkedin.com", segments.count >= 2, segments[0] == "in" {
            return segments[1]
        }
        if host == "medium.com" {
            let first = segments[0]
            return first.hasPrefix("@") ? String(first.dropFirst()) : first
        }
        return nil
    }
}
