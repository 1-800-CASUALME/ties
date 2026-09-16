import Foundation

/// The outcome of one update check, in the three shapes Settings has something to say about.
enum UpdateStatus: Equatable, Sendable {
    case upToDate
    case available(tag: String, url: URL)
    case failed(String)
}

/// Asks GitHub what the newest published release is and compares it with the version this
/// build was stamped with. Ties is distributed as an unsigned DMG, so there is no Sparkle feed
/// and nothing to install automatically — the most this can do is point at the release page.
enum UpdateChecker {
    /// Where the user is sent when there is something newer.
    static let releasesURL = URL(string: "https://github.com/1-800-CASUALME/ties/releases/latest")!

    private static let latestReleaseAPI =
        URL(string: "https://api.github.com/repos/1-800-CASUALME/ties/releases/latest")!

    private struct Release: Decodable {
        let tagName: String
    }

    /// The `tag_name` of the newest published release, e.g. `"v0.2.0"`.
    static func latestTag() async throws -> String {
        var request = URLRequest(url: latestReleaseAPI)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw URLError(.badServerResponse)
        }
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(Release.self, from: data).tagName
    }

    /// Never throws: a failed check is something to show in Settings, not an error to handle.
    static func check() async -> UpdateStatus {
        do {
            let tag = try await latestTag()
            return isNewer(tag, than: currentVersion) ? .available(tag: tag, url: releasesURL) : .upToDate
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    /// `CFBundleShortVersionString`, which `project.yml` fills from `MARKETING_VERSION`.
    static var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    }

    /// Compares two dot-separated versions numerically, ignoring a leading `v`, so `v0.10.0`
    /// correctly beats `0.9.0` where a string comparison would not.
    static func isNewer(_ tag: String, than current: String) -> Bool {
        let latest = numbers(in: tag)
        let installed = numbers(in: current)
        for index in 0..<max(latest.count, installed.count) {
            let left = index < latest.count ? latest[index] : 0
            let right = index < installed.count ? installed[index] : 0
            if left != right { return left > right }
        }
        return false
    }

    /// The numeric components of a version string. A component with a suffix (`"1-beta"`)
    /// contributes only its leading digits, and anything unparseable counts as zero.
    private static func numbers(in version: String) -> [Int] {
        var text = version.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("v") { text.removeFirst() }
        return text.split(separator: ".").map { Int($0.prefix(while: \.isNumber)) ?? 0 }
    }
}
