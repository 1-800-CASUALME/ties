import Foundation

/// Reads what the person's own mail says about them: the signature blocks they sign with, the
/// name they put in `From`, and how recently and how often you two have written.
///
/// Subjects and message text never leave this type — only the parsed signature facts do
/// (spec §3, §4.2).
public struct MailCollector: SourceCollector {
    /// The 50 most recent messages per address (spec §3, "cap work per person").
    static let messageCap = 50

    /// What `status()` says after a run that came back empty because Spotlight had no index for
    /// the mailbox and the mailbox is too large to walk by hand — the one case where "no signals"
    /// means "we could not look", and the UI has to be able to say so.
    public static let indexMissingMessage = "Mail index found nothing; mailbox too large to scan"

    public static let defaultRoot = URL(fileURLWithPath: NSHomeDirectory() + "/Library/Mail")

    public let id = "mail"
    public let displayName = "your mail"

    private let index: any MailIndex
    private let root: URL
    /// Above this many `.emlx` files, the directory walk that stands in for a missing Spotlight
    /// index is not attempted (`SpotlightMailIndex` applies the same ceiling).
    private let fallbackCeiling: Int
    /// What the last run concluded, so `status()` can report it afterwards.
    private let outcome = Outcome()

    public init(index: any MailIndex = SpotlightMailIndex(), root: URL = MailCollector.defaultRoot) {
        self.init(index: index, root: root, fallbackCeiling: SpotlightMailIndex.directoryFallbackLimit)
    }

    init(index: any MailIndex, root: URL, fallbackCeiling: Int) {
        self.index = index
        self.root = root
        self.fallbackCeiling = fallbackCeiling
    }

    // MARK: - Status

    /// Where the mailbox stands: the file system's answer, unless the last run ended in the one
    /// state the file system cannot see — a mailbox that is there and readable but that neither
    /// Spotlight nor a directory walk could answer for.
    public func status() -> SourceStatus {
        let onDisk = fileSystemStatus()
        guard case .ready = onDisk, let recorded = outcome.value else { return onDisk }
        return recorded
    }

    private func fileSystemStatus() -> SourceStatus {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: root.path) else { return .unavailable }
        guard fileManager.isReadableFile(atPath: root.path) else { return .needsAccess }
        do {
            _ = try fileManager.contentsOfDirectory(atPath: root.path)
        } catch {
            guard SourceSnapshot.isPermissionError(error) else { return .error(error.localizedDescription) }
            return .needsAccess
        }
        return .ready
    }

    // MARK: - Collection

    public func collect(for input: ProbeInput, since: Date?) async throws -> LocalSignals {
        #if DEBUG
        visits.reset()
        #endif
        // This run's own verdict replaces the last one's, so a mailbox that has since been
        // indexed stops reporting the old complaint.
        outcome.record(nil)

        // Ask the file system first: without Full Disk Access the mailbox is not merely
        // unreadable, it is invisible, and an open-first read would call that "not installed".
        switch status() {
        case .unavailable: throw SourceError.unavailable
        case .needsAccess: throw SourceError.needsAccess
        case .error(let message): throw SourceError.malformed(message)
        case .ready: break
        }

        var signals = LocalSignals(personId: input.person.id)
        guard !input.emails.isEmpty else { return signals }

        let messages = try await read(for: input, since: since)
        guard !messages.isEmpty else {
            if mailboxIsTooLargeToWalk() { outcome.record(.error(Self.indexMissingMessage)) }
            return signals
        }
        signals.sources = ["mail"]

        let addresses = Set(input.emails.map { $0.lowercased() })
        let yearAgo = Date.now.addingTimeInterval(-365 * 24 * 60 * 60)

        for message in messages {
            // Contact is contact whichever way it went.
            if let date = message.date {
                signals.lastContact = max(signals.lastContact ?? date, date)
                if date >= yearAgo { signals.interactions += 1 }
            }
            // Everything below is what the person said about themselves, so only their own mail
            // counts: the user's signature sits at the foot of every message they sent.
            guard let from = message.from, addresses.contains(from.address) else { continue }

            if let alias = alias(from: from.name, knownAs: input.fullName), !signals.aliases.contains(alias) {
                signals.aliases.append(alias)
            }
            guard let block = SignalRules.signature(in: message.textBody, senderName: from.name ?? input.fullName)
            else { continue }
            add(block.titles, to: &signals.titles)
            add(block.companies, to: &signals.companies)
            add(block.phones, to: &signals.phones)
            add(block.links, to: &signals.links)
            if signals.location == nil { signals.location = block.location }
        }
        return signals
    }

    /// The messages behind the person's addresses, newest first, each file opened once however
    /// many of their addresses it involves.
    private func read(for input: ProbeInput, since: Date?) async throws -> [EMLXMessage] {
        var seen = Set<URL>()
        var messages: [EMLXMessage] = []
        for address in input.emails {
            for url in try await index.messageURLs(involving: address, limit: Self.messageCap)
            where seen.insert(url).inserted {
                guard let data = try? Data(contentsOf: url), let message = try? EMLX.parse(data) else { continue }
                #if DEBUG
                visits.count()
                #endif
                if let since, let date = message.date, date < since { continue }
                messages.append(message)
            }
        }
        return messages
    }

    /// Whether the mailbox is past the ceiling above which a missing Spotlight index cannot be
    /// stood in for by reading the files. Only asked when a run found nothing, which is the only
    /// time the answer changes what the user is told.
    private func mailboxIsTooLargeToWalk() -> Bool {
        DirectoryMailIndex.emlxFiles(in: root, limit: fallbackCeiling + 1).count > fallbackCeiling
    }

    /// A `From` display name is an alias only when it isn't the name the Mac already has.
    private func alias(from displayName: String?, knownAs name: String) -> String? {
        guard let candidate = displayName?.trimmingCharacters(in: .whitespaces), !candidate.isEmpty else {
            return nil
        }
        guard NameMatcher.similarity(personName: name, candidateName: candidate) < SignalRules.aliasNameGate
        else { return nil }
        return candidate
    }

    private func add(_ values: [String], to target: inout [String]) {
        for value in values where !target.contains(value) { target.append(value) }
    }

    /// The last run's verdict, in a reference box because the collector is a `Sendable` value
    /// shared across the people of a run.
    private final class Outcome: @unchecked Sendable {
        private let lock = NSLock()
        private var status: SourceStatus?

        var value: SourceStatus? { lock.withLock { status } }
        func record(_ status: SourceStatus?) { lock.withLock { self.status = status } }
    }

    // MARK: - Test support

    #if DEBUG
    /// How many `.emlx` files this collector's last `collect(for:since:)` opened — how the
    /// per-address cap is asserted without a counting file system. Per collector, not global, so
    /// tests running in parallel don't count each other's work.
    public var lastVisited: Int { visits.value }

    private let visits = Visits()

    private final class Visits: @unchecked Sendable {
        private let lock = NSLock()
        private var visited = 0

        var value: Int { lock.withLock { visited } }
        func reset() { lock.withLock { visited = 0 } }
        func count() { lock.withLock { visited += 1 } }
    }
    #endif
}
