import Foundation

/// Finds the `.emlx` files of the messages a given address took part in, newest first.
public protocol MailIndex: Sendable {
    func messageURLs(involving address: String, limit: Int) async throws -> [URL]
}

/// Asks Spotlight, which has already indexed every message Mail has downloaded — reading the
/// mailbox itself would mean parsing tens of thousands of files.
public struct SpotlightMailIndex: MailIndex {
    /// How long Spotlight gets to answer before the directory walk takes over.
    static let defaultTimeout: TimeInterval = 5
    /// Walking more `.emlx` files than this by hand costs more than the answer is worth.
    static let directoryFallbackLimit = 5_000

    public let root: URL
    let timeout: TimeInterval

    public init(root: URL = URL(fileURLWithPath: NSHomeDirectory() + "/Library/Mail")) {
        self.init(root: root, timeout: Self.defaultTimeout)
    }

    init(root: URL, timeout: TimeInterval) {
        self.root = root
        self.timeout = timeout
    }

    public func messageURLs(involving address: String, limit: Int) async throws -> [URL] {
        let found = await Self.spotlightURLs(address: address, root: root, timeout: timeout)
        if !found.isEmpty { return Array(found.prefix(limit)) }

        // Nothing came back in time: either Spotlight has no index for this folder, or it is
        // still gathering. Reading the mailbox by hand is only affordable when it is small.
        let files = DirectoryMailIndex.emlxFiles(in: root, limit: Self.directoryFallbackLimit + 1)
        guard files.count <= Self.directoryFallbackLimit else { return [] }
        return try await DirectoryMailIndex(root: root).messageURLs(involving: address, limit: limit)
    }

    // MARK: - The query

    /// Runs one `NSMetadataQuery` to completion on a thread of its own, since the query needs a
    /// run loop and must not be allowed to hold up the collection pass past `timeout`.
    private static func spotlightURLs(address: String, root: URL, timeout: TimeInterval) async -> [URL] {
        await withCheckedContinuation { (continuation: CheckedContinuation<[URL], Never>) in
            let thread = Thread {
                continuation.resume(returning: gather(address: address, root: root, timeout: timeout))
            }
            thread.name = "ties.spotlight-mail"
            thread.start()
        }
    }

    private static func gather(address: String, root: URL, timeout: TimeInterval) -> [URL] {
        let query = NSMetadataQuery()
        query.predicate = NSPredicate(
            format: "(kMDItemAuthorEmailAddresses ==[c] %@) || (kMDItemRecipientEmailAddresses ==[c] %@)",
            address,
            address
        )
        query.searchScopes = [root]
        query.sortDescriptors = [NSSortDescriptor(key: "kMDItemContentCreationDate", ascending: false)]

        let gathered = Flag()
        let observer = NotificationCenter.default.addObserver(
            forName: .NSMetadataQueryDidFinishGathering,
            object: query,
            queue: nil
        ) { _ in gathered.raise() }
        defer { NotificationCenter.default.removeObserver(observer) }

        guard query.start() else { return [] }
        defer { query.stop() }

        let deadline = Date().addingTimeInterval(timeout)
        while !gathered.isRaised, Date() < deadline {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05))
        }
        query.disableUpdates()
        guard gathered.isRaised else { return [] }

        var dated: [(url: URL, date: Date)] = []
        for item in query.results.compactMap({ $0 as? NSMetadataItem }) {
            guard let path = item.value(forAttribute: NSMetadataItemPathKey) as? String else { continue }
            let url = URL(fileURLWithPath: path)
            guard url.pathExtension == "emlx" else { continue }
            let date = item.value(forAttribute: NSMetadataItemContentCreationDateKey) as? Date
            dated.append((url, date ?? .distantPast))
        }
        // The sort descriptor orders the query's own result list; ordering the values read out of
        // it again costs nothing and does not depend on that.
        return dated.sorted { $0.date > $1.date }.map(\.url)
    }

    /// One bool shared between the run loop and the notification block.
    private final class Flag: @unchecked Sendable {
        private let lock = NSLock()
        private var raised = false

        var isRaised: Bool { lock.withLock { raised } }
        func raise() { lock.withLock { raised = true } }
    }
}

/// Walks a mailbox directory and reads the headers itself. The test double for
/// `SpotlightMailIndex`, and its fallback on a small mailbox Spotlight has not indexed.
public struct DirectoryMailIndex: MailIndex {
    public let root: URL

    public init(root: URL) {
        self.root = root
    }

    public func messageURLs(involving address: String, limit: Int) async throws -> [URL] {
        let wanted = address.lowercased()
        var dated: [(url: URL, date: Date)] = []
        for url in Self.emlxFiles(in: root, limit: .max) {
            guard let data = try? Data(contentsOf: url) else { continue }
            guard let message = try? EMLX.parse(data) else { continue }
            guard message.from?.address == wanted || message.to.contains(wanted) else { continue }
            dated.append((url, message.date ?? .distantPast))
        }
        return dated.sorted { $0.date > $1.date }.prefix(limit).map(\.url)
    }

    /// Every `.emlx` file under `root`, stopping after `limit` of them.
    static func emlxFiles(in root: URL, limit: Int) -> [URL] {
        guard let walker = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        var found: [URL] = []
        for case let url as URL in walker where url.pathExtension == "emlx" {
            found.append(url)
            if found.count >= limit { break }
        }
        return found
    }
}
