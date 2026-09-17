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

    /// What Contacts contributes about the person and nothing else: the `contactsSignals` column
    /// `ContactSync` wrote, never the merged columns beside it.
    ///
    /// Reading the merged row instead would make every pass carry the previous pass's Messages,
    /// WhatsApp and Mail values back in under the Contacts name — a row that could never shrink,
    /// so a source switched off would keep contributing for ever.
    public func collect(for input: ProbeInput, since: Date?) async throws -> LocalSignals {
        var signals = try store.contactsSignals(personId: input.person.id)
            ?? LocalSignals(personId: input.person.id)
        signals.personId = input.person.id
        // The relationship is not Contacts' to describe: the counts and dates belong to the chat
        // and mail collectors, and `merged(with:)` adds interaction counts up.
        signals.lastContact = nil
        signals.interactions = 0
        signals.phones = []
        signals.emails = []
        guard !signals.isEmpty else { return LocalSignals(personId: input.person.id) }
        signals.sources = [id]
        return signals
    }
}
