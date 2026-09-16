import Foundation

/// The address book as a source among the others: it reads back what `ContactSync` already wrote
/// from each contact's nickname, note, and postal address (spec §3).
///
/// Contacts is the one source that is read at import time rather than at collection time — the
/// app has the contacts in hand the moment the user grants access, and re-reading `CNContactStore`
/// per person would be slower and no more accurate. Conforming it to `SourceCollector` anyway lets
/// `SignalCollector` treat it like every other source: it appears in the stage list, it has a
/// status, and a full collection pass carries the address book's contribution into the rebuilt row
/// instead of dropping it.
public struct ContactsCollector: SourceCollector {
    public let id = "contacts"
    public let displayName = "Contacts"

    private let store: Store

    public init(store: Store) {
        self.store = store
    }

    /// Always ready: what this collector returns was read from Contacts when the user granted
    /// access and is on disk here, so nothing has to be granted again for it to answer.
    public func status() -> SourceStatus {
        .ready
    }

    /// What Contacts contributes about the person, and only that: the names they go by, how they
    /// are addressed, the links their note held, and where they are.
    ///
    /// Deliberately not `lastContact`, `interactions`, `phones` or `emails`. Those describe the
    /// relationship rather than the person, they belong to the chat and mail collectors, and
    /// `merged(with:)` adds interaction counts up — returning them here would double every
    /// person's history on every pass.
    public func collect(for input: ProbeInput, since: Date?) async throws -> LocalSignals {
        var signals = LocalSignals(personId: input.person.id)
        guard let stored = try store.signals(personId: input.person.id) else { return signals }
        signals.aliases = stored.aliases
        signals.honorifics = stored.honorifics
        signals.links = stored.links
        signals.location = stored.location
        guard !signals.isEmpty else { return LocalSignals(personId: input.person.id) }
        signals.sources = [id]
        return signals
    }
}
