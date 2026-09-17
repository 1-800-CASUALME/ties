import Foundation

/// What a run has already asked, what it is still allowed to ask, and whether it has been told
/// to stop asking.
///
/// A lookup costs money per call, so three things have to be true across a whole pass rather
/// than per person: the same number is asked about once however many contacts share it, the
/// pass stops at a cap the user set, and a refused key halts everything instead of being
/// refused — and billed — two thousand more times.
public actor LookupBudget {
    public enum Cached: Sendable {
        /// Asked already; this is what came back, `nil` meaning the service had nothing.
        case known(LookupResult?)
        case unknown
    }

    private var remaining: Int
    private var answers: [String: LookupResult] = [:]
    private var misses: Set<String> = []
    private var halted = false

    public init(limit: Int) {
        self.remaining = max(0, limit)
    }

    public var isHalted: Bool { halted }
    public var remainingCount: Int { remaining }

    public func cached(_ key: String) -> Cached {
        if let answer = answers[key] { return .known(answer) }
        if misses.contains(key) { return .known(nil) }
        return .unknown
    }

    /// Claims one call from the budget, or refuses when the pass is out or halted.
    public func take() -> Bool {
        guard !halted, remaining > 0 else { return false }
        remaining -= 1
        return true
    }

    public func store(_ key: String, _ result: LookupResult?) {
        if let result { answers[key] = result } else { misses.insert(key) }
    }

    /// Stops the pass making any further calls. Used when the credentials are refused.
    public func halt() { halted = true }
}

/// The lookup service as one more source of signals, sitting beside Messages, WhatsApp and Mail.
///
/// It is the only source that leaves this Mac, which is why it is the only one that is off until
/// a provider is chosen and given a key: `status()` answers `.unavailable` until then, so the
/// row shows as nothing to read rather than as something waiting for permission.
///
/// What it keeps: the names the service returned, and the labels — "Dr.", "مهندس", "Plumber" —
/// that say what someone does. What it reads but doesn't yet keep: carrier, line type, and a
/// name-match score, none of which `LocalSignals` has a home for. The Lookup settings pane shows
/// them for a number the user tests, so nothing the service says is hidden.
public struct LookupCollector: SourceCollector {
    public let id = LookupCollector.sourceId
    public let displayName = "Lookup"

    public static let sourceId = "lookup"

    /// How many of a person's numbers are worth paying for. The first two cover a mobile and a
    /// work line; a contact card with six numbers is a business, and asking about all six buys
    /// the same answer six times.
    static let maxNumbersPerPerson = 2

    private let provider: (any LookupProvider)?
    private let budget: LookupBudget

    public init(provider: (any LookupProvider)?, budget: LookupBudget) {
        self.provider = provider
        self.budget = budget
    }

    public func status() -> SourceStatus {
        provider == nil ? .unavailable : .ready
    }

    public func collect(for input: ProbeInput, since: Date?) async throws -> LocalSignals {
        guard let provider else { throw SourceError.unavailable }
        if await budget.isHalted { throw SourceError.malformed("The lookup key was refused") }

        var signals = LocalSignals(personId: input.person.id, sources: [id], collectedAt: .now)
        var asked = false

        numbers: for phone in input.phonesE164.prefix(Self.maxNumbersPerPerson) {
            let result: LookupResult?
            switch await budget.cached(phone) {
            case .known(let cached):
                result = cached
            case .unknown:
                // Out of budget, or halted since this person started: stop here rather than
                // asking about their second number and every later person's first.
                guard await budget.take() else { break numbers }
                asked = true
                do {
                    result = try await provider.lookup(LookupQuery(phoneE164: phone, name: input.fullName))
                } catch LookupError.unauthorized {
                    await budget.halt()
                    throw SourceError.malformed("The lookup key was refused")
                } catch {
                    // One number the service couldn't answer about is not a reason to fail the
                    // person: the other sources have already found what they found.
                    continue
                }
                await budget.store(phone, result)
            }
            if let result { merge(result, into: &signals, names: input.aliases) }
        }

        // A person with no numbers, or a pass that has run out of budget before reaching them,
        // gets an empty row that claims no source — otherwise "lookup" would appear in the
        // person's sources as if it had been asked and had nothing to say.
        if signals.isEmpty, !asked { signals.sources = [] }
        return signals
    }

    /// Folds one answer into the row being built.
    ///
    /// A name registered against the line is treated the way a name somebody set on their own
    /// WhatsApp account is: strong enough to admit a web profile. A name a crowd saved is an
    /// alias and nothing more — it is how a number is *labelled*, which is exactly as often
    /// "Dad", "Plumber Do Not Answer" or the name of whoever had the number two years ago.
    func merge(_ result: LookupResult, into signals: inout LocalSignals, names: [String]) {
        for name in result.names {
            append(name.value, to: &signals.aliases)
            if name.kind == .registered { append(name.value, to: &signals.strongAliases) }
            addHonorifics(in: name.value, to: &signals, names: names)
        }

        for tag in result.tags {
            let trimmed = tag.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            if let canonical = Honorifics.canonical(trimmed) {
                append(canonical, to: &signals.honorifics)
                append(trimmed, to: &signals.honorificsAsWritten)
            } else if !addHonorifics(in: trimmed, to: &signals, names: names) {
                // Whatever is left describes what they do — which is what a title is.
                append(trimmed, to: &signals.titles)
            }
        }
    }

    /// Picks "Dr." out of "Dr. Sara" when the rest of the label is a name Ties already has.
    /// Returns whether anything was found, so a label that is only an honorific isn't also
    /// filed as a job title.
    @discardableResult
    private func addHonorifics(in text: String, to signals: inout LocalSignals, names: [String]) -> Bool {
        let found = SignalRules.honorificsFound(in: text, names: names)
        for honorific in found {
            append(honorific.canonical, to: &signals.honorifics)
            append(honorific.asWritten, to: &signals.honorificsAsWritten)
        }
        return !found.isEmpty
    }

    private func append(_ value: String, to list: inout [String]) {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !list.contains(where: { $0.caseInsensitiveCompare(trimmed) == .orderedSame }) else {
            return
        }
        list.append(trimmed)
    }
}
