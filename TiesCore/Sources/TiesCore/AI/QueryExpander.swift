import Foundation

/// Turns an ask query into the words a matching profile would actually use — "help with taxes"
/// into accountant, CPA, tax advisor, bookkeeper (§7.3).
///
/// Expansion is an improvement to a search that already works, so it is never allowed to hold
/// one up: the provider races a 2-second clock and anything that goes wrong — a slow model, a
/// missing API key, an answer that isn't JSON — returns no terms at all and leaves the caller
/// searching what the user typed.
public struct QueryExpander: Sendable {
    /// How long a search will wait for the expansion before going ahead without it (§7.3).
    public static let defaultTimeout: Duration = .seconds(2)
    /// At most 6 terms: more than that and the chips under the field stop being readable.
    static let maxTerms = 6

    private let provider: any AIProvider
    private let timeout: Duration

    public init(provider: any AIProvider) {
        self.init(provider: provider, timeout: Self.defaultTimeout)
    }

    /// Testing seam: the same expander with a shorter clock, so a timeout can be asserted
    /// without a test that sleeps for two seconds.
    init(provider: any AIProvider, timeout: Duration) {
        self.provider = provider
        self.timeout = timeout
    }

    /// Up to 6 expansion terms for `query`, or `[]` if the provider is slow, unavailable, or
    /// unintelligible. Never throws, despite the signature: a failed expansion is a search
    /// without expansion, not a failed search.
    public func expand(_ query: String) async throws -> [String] {
        let cleaned = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return [] }

        do {
            return try await withThrowingTaskGroup(of: [String].self) { group in
                group.addTask { try await self.terms(for: cleaned) }
                group.addTask {
                    try await Task.sleep(for: self.timeout)
                    throw Timeout()
                }
                // Whichever finishes first decides: the model's terms, or the clock running out.
                // `cancelAll` stops the loser, and leaving the group cancels and drains it.
                defer { group.cancelAll() }
                return try await group.next() ?? []
            }
        } catch {
            return []
        }
    }

    private func terms(for query: String) async throws -> [String] {
        let data = try await provider.complete(
            system: AIPrompts.queryExpansionSystem,
            user: AIPrompts.queryExpansion(query),
            schemaJSON: AISchemas.queryExpansion,
            schemaName: AISchemas.queryExpansionName
        )
        let raw = try AISchemas.decode(RawExpansion.self, from: data)

        var seen = Set<String>()
        return (raw.terms ?? [])
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && seen.insert($0.lowercased()).inserted }
            .prefix(Self.maxTerms)
            .map { $0 }
    }

    private struct RawExpansion: Decodable {
        var terms: [String]?
    }

    /// Thrown by the clock task to end the race; never escapes `expand`.
    private struct Timeout: Error {}
}
