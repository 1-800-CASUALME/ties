import Foundation

/// Reads what the person's own mail says about them: the signature blocks they sign with, the
/// name they put in `From`, and how recently and how often you two have written.
///
/// Subjects and message text never leave this type — only the parsed signature facts do
/// (spec §3, §4.2).
public struct MailCollector: SourceCollector {
    /// The 50 most recent messages per address (spec §3, "cap work per person").
    static let messageCap = 50
    /// At or above this `NameMatcher.similarity` the `From` display name is just the person's
    /// known name again, not another name they go by.
    static let aliasGate = 0.9

    public static let defaultRoot = URL(fileURLWithPath: NSHomeDirectory() + "/Library/Mail")

    public let id = "mail"
    public let displayName = "your mail"

    private let index: any MailIndex
    private let root: URL

    public init(index: any MailIndex = SpotlightMailIndex(), root: URL = MailCollector.defaultRoot) {
        self.index = index
        self.root = root
    }

    // MARK: - Status

    public func status() -> SourceStatus {
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

        switch status() {
        case .unavailable: throw SourceError.unavailable
        case .needsAccess: throw SourceError.needsAccess
        case .error(let message): throw SourceError.malformed(message)
        case .ready: break
        }

        var signals = LocalSignals(personId: input.person.id)
        guard !input.emails.isEmpty else { return signals }

        let messages = try await read(for: input, since: since)
        guard !messages.isEmpty else { return signals }
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

    /// A `From` display name is an alias only when it isn't the name the Mac already has.
    private func alias(from displayName: String?, knownAs name: String) -> String? {
        guard let candidate = displayName?.trimmingCharacters(in: .whitespaces), !candidate.isEmpty else {
            return nil
        }
        guard NameMatcher.similarity(personName: name, candidateName: candidate) < Self.aliasGate else { return nil }
        return candidate
    }

    private func add(_ values: [String], to target: inout [String]) {
        for value in values where !target.contains(value) { target.append(value) }
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
