import Foundation

/// Asks the provider which of a person's competing search results is really them (§7.1).
///
/// It runs only where the automatic scorer left real doubt: two or more candidates still
/// pending, or a single pending one that didn't score convincingly. A person who already has
/// an accepted candidate is never judged — the user has answered that question, and the model
/// doesn't get to reopen it.
///
/// The verdict is advice, not a decision: `judge` returns it for the caller to show as a
/// `sparkle` chip (and to persist with `Store.upsertJudgement` if it wants); nothing here
/// changes a candidate's status.
public struct CandidateJudge: Sendable {
    /// The score above which a lone pending candidate is considered settled enough to skip.
    static let confidentScore = 3.0
    /// How many of a candidate's pages are quoted in the prompt.
    static let snippetsPerCandidate = 2

    private let store: Store
    private let provider: any AIProvider
    private let shareSignals: Bool

    public init(store: Store, provider: any AIProvider, shareSignals: Bool) {
        self.store = store
        self.provider = provider
        self.shareSignals = shareSignals
    }

    /// The provider's verdict on this person's pending candidates, or `nil` when there is
    /// nothing worth asking about (no pending candidates, one convincing candidate, or a
    /// candidate the user has already accepted).
    ///
    /// Throws `ProviderError.badResponse` if the model names a candidate that wasn't offered —
    /// a verdict about a candidate that isn't on the screen can't be shown, and guessing which
    /// one was meant would be worse than failing.
    public func judge(personId: String) async throws -> Judgement? {
        guard let person = try store.person(id: personId) else { return nil }
        let candidates = try store.candidates(personId: personId)
        guard !candidates.contains(where: { $0.status == .accepted }) else { return nil }

        let pending = candidates.filter { $0.status == .pending }.sorted { $0.score > $1.score }
        guard let best = pending.first else { return nil }
        guard pending.count >= 2 || best.score < Self.confidentScore else { return nil }

        var pages: [String: [SourcePage]] = [:]
        for candidate in pending {
            pages[candidate.id] = try store.pages(candidateId: candidate.id)
        }

        let data = try await provider.complete(
            system: AIPrompts.judgeSystem,
            user: AIPrompts.judge(person: person, candidates: pending, pages: pages, signals: try sharedSignals(personId: personId)),
            schemaJSON: AISchemas.judgement,
            schemaName: AISchemas.judgementName
        )
        let verdict = try AISchemas.decode(Verdict.self, from: data)

        let candidateId = verdict.candidateId ?? ""
        guard pending.contains(where: { $0.id == candidateId }) else {
            throw ProviderError.badResponse("judged a candidate that wasn't offered: \(candidateId)")
        }
        return Judgement(
            personId: personId,
            candidateId: candidateId,
            // The schema asks for 0–1 and ≤ 90 characters; a model that ignores it still has to
            // produce a confidence a progress bar can draw and a reason a chip can hold.
            confidence: min(1, max(0, verdict.confidence ?? 0)),
            reason: String((verdict.reason ?? "").trimmingCharacters(in: .whitespacesAndNewlines).prefix(90)),
            providerId: provider.spec.id
        )
    }

    /// The person's signals, stripped to what may leave this Mac — or `nil` when they may not
    /// leave it at all (§7.5: a cloud provider sees them only with the switch on; the on-device
    /// model always may).
    private func sharedSignals(personId: String) throws -> LocalSignals? {
        guard shareSignals || provider.spec.tier == .onDevice else { return nil }
        guard let signals = try store.signals(personId: personId), !signals.isEmpty else { return nil }
        return signals.publicSafe
    }

    /// Every field optional: a model that omits one costs us that field, not the verdict.
    private struct Verdict: Decodable {
        var candidateId: String?
        var confidence: Double?
        var reason: String?
    }
}
