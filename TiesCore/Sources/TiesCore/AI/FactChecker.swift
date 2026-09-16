import Foundation

/// The extractor's second pass: re-reads each extracted fact against the pages it cites and
/// marks the ones the sources don't actually support (§7.6).
///
/// One call per person, not per fact: the facts are flattened into a numbered list — companies,
/// achievements, certificates, experience, in that order — and the model answers with one
/// boolean per number. `occupation`, `summary` and `canHelpWith` are left alone; they are the
/// model's own summarising, not claims with sources behind them.
public struct FactChecker: Sendable {
    private let provider: any AIProvider

    public init(provider: any AIProvider) {
        self.provider = provider
    }

    /// `facts` with every `Fact.supported` filled in. Returns the facts untouched — without
    /// calling the provider — when there is nothing with sources to check.
    ///
    /// Throws `ProviderError.badResponse` when the answer doesn't have exactly one boolean per
    /// fact: the flags are only meaningful in order, so a list of the wrong length can't be
    /// trusted to line up, and a wrongly marked fact is worse than an unchecked one.
    public func check(_ facts: ProfileFacts, pages: [SourcePage]) async throws -> ProfileFacts {
        let flattened = facts.companies + facts.achievements + facts.certificates + facts.experience
        guard !flattened.isEmpty else { return facts }

        let data = try await provider.complete(
            system: AIPrompts.factCheckSystem,
            user: AIPrompts.factCheck(facts: flattened, pages: pages),
            schemaJSON: AISchemas.factCheck,
            schemaName: AISchemas.factCheckName
        )
        let supported = try AISchemas.decode(RawCheck.self, from: data).supported ?? []
        guard supported.count == flattened.count else {
            throw ProviderError.badResponse("fact check answered \(supported.count) flags for \(flattened.count) facts")
        }

        var index = 0
        func apply(_ list: [Fact]) -> [Fact] {
            list.map { fact in
                var checked = fact
                checked.supported = supported[index]
                index += 1
                return checked
            }
        }

        var result = facts
        result.companies = apply(facts.companies)
        result.achievements = apply(facts.achievements)
        result.certificates = apply(facts.certificates)
        result.experience = apply(facts.experience)
        return result
    }

    private struct RawCheck: Decodable {
        var supported: [Bool]?
    }
}
