import Foundation

/// Finds the `.emlx` files of the messages a given address took part in, newest first.
public protocol MailIndex: Sendable {
    func messageURLs(involving address: String, limit: Int) async throws -> [URL]
}

/// Asks Spotlight, which has already indexed every message Mail has downloaded — reading the
/// mailbox itself would mean parsing tens of thousands of files.
///
/// An empty answer is not a verdict: Spotlight cannot tell "this person has no mail" from "this
/// folder was never indexed". Standing in for the second is `MailCollector`'s job, not this
/// type's, because the stand-in is a whole-mailbox read that has to happen once for a run
/// rather than once for every address it is asked about.
public struct SpotlightMailIndex: MailIndex {
    /// How long Spotlight gets to answer before the run gives up on it.
    static let defaultTimeout: TimeInterval = 5
    /// Reading more `.emlx` files than this by hand costs more than the answer is worth.
    /// `MailCollector` applies this ceiling when deciding whether to build the directory index
    /// that stands in for a missing Spotlight index at all.
    public static let directoryFallbackLimit = 5_000

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
        return Array(found.prefix(limit))
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
/// `SpotlightMailIndex`, and the source of the whole-mailbox index that stands in for it.
public struct DirectoryMailIndex: MailIndex {
    /// How much of a `.emlx` file is read to find its header block: Mail's byte-count line plus
    /// the headers. A message whose headers run past this has a `Received` chain no signal is
    /// ever read out of.
    static let headerBytes = 64 * 1024

    public let root: URL

    public init(root: URL) {
        self.root = root
    }

    public func messageURLs(involving address: String, limit: Int) async throws -> [URL] {
        Self.index(of: Self.emlxFiles(in: root, limit: .max)).messageURLs(involving: address, limit: limit)
    }

    // MARK: - Reading the mailbox

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

    /// Reads the headers of `files` and indexes them by every address each message involves,
    /// newest first.
    static func index(of files: [URL]) -> MailboxIndex {
        var dated: [String: [(url: URL, date: Date)]] = [:]
        for url in files {
            guard let header = headers(of: url) else { continue }
            for address in header.addresses {
                dated[address, default: []].append((url, header.date))
            }
        }
        let byAddress = dated.mapValues { messages in
            messages.sorted { $0.date > $1.date }.map(\.url)
        }
        return MailboxIndex(messagesByAddress: byAddress, fileCount: files.count)
    }

    /// Every address one message involves — its `From`, `To` and `Cc` — and when it was sent,
    /// read from the head of the file and nothing else.
    ///
    /// Whether a message involves an address is a question about four header fields. Parsing
    /// the body to answer it meant decoding base64 attachments and stripping HTML for every
    /// message in the mailbox, which is what made reading the mailbox unaffordable; the body is
    /// read later, by `MailCollector`, for the fifty messages that turn out to be the person's.
    static func headers(of url: URL) -> (addresses: Set<String>, date: Date)? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let head = try? handle.read(upToCount: headerBytes), !head.isEmpty else { return nil }

        // The byte-count line Mail writes first is not part of the message.
        guard let firstNewline = head.firstIndex(of: 0x0A) else { return nil }
        let fields = EMLX.Headers(headerBlock(of: head[head.index(after: firstNewline)...]))

        var addresses = Set<String>()
        for list in fields.values("from") + fields.values("to") + fields.values("cc") {
            addresses.formUnion(EMLX.addresses(in: list).map(\.address))
        }
        guard !addresses.isEmpty else { return nil }
        return (addresses, fields.value("date").flatMap(EMLX.date(from:)) ?? .distantPast)
    }

    /// Everything up to the blank line that ends the headers — or the whole slice when the read
    /// prefix stopped short of one.
    private static func headerBlock(of data: Data.SubSequence) -> Data {
        var index = data.startIndex
        while let newline = data[index...].firstIndex(of: 0x0A) {
            let afterNewline = data.index(after: newline)
            guard afterNewline < data.endIndex else { break }
            if data[afterNewline] == 0x0A {
                return Data(data[data.startIndex..<newline])
            }
            if data[afterNewline] == 0x0D {
                let third = data.index(after: afterNewline)
                if third < data.endIndex, data[third] == 0x0A {
                    return Data(data[data.startIndex..<newline])
                }
            }
            index = afterNewline
        }
        return Data(data)
    }
}

/// A mailbox read once: every address it holds mapped to the messages that address took part
/// in, newest first.
///
/// This is what stands in for a Spotlight index that isn't there. A Spotlight miss looks exactly
/// like "this person has no mail" — which is the common case — so the stand-in is reached for
/// most of an address book, and walking and parsing the mailbox again for each of them was
/// `people × addresses × mailbox size` file reads. Built once per collection run instead
/// (`MailCollector.beginSession`), it answers each of them from memory.
public struct MailboxIndex: Sendable {
    static let empty = MailboxIndex(messagesByAddress: [:], fileCount: 0)

    /// Lowercased address -> the messages it took part in, newest first.
    let messagesByAddress: [String: [URL]]
    /// How many files were walked to build it.
    let fileCount: Int

    public func messageURLs(involving address: String, limit: Int) -> [URL] {
        Array((messagesByAddress[address.lowercased()] ?? []).prefix(limit))
    }
}
