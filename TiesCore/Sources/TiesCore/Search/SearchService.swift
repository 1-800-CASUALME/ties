import Foundation

/// One hit for a "who can help with X" query: a person, their fused relevance score, and a
/// short excerpt of why they matched.
public struct SearchResult: Sendable, Hashable {
    public var personId: String
    public var score: Double
    public var why: String

    public init(personId: String, score: Double, why: String) {
        self.personId = personId
        self.score = score
        self.why = why
    }
}

/// Answers "who can help with X" by blending FTS5 keyword hits with embedding similarity via
/// reciprocal rank fusion.
public struct SearchService: Sendable {
    /// Tokens carrying no discriminating signal on their own; excluded from `why`-line matching
    /// so a query like "who can help with saas growth" doesn't treat "who", "can", "help", or
    /// "with" as search terms.
    private static let stopWords: Set<String> = [
        "who", "can", "help", "with", "the", "and", "for", "that", "someone",
        "know", "me", "a", "an", "to", "of", "in", "on", "is",
    ]

    /// The maximum length of a `SearchResult.why` excerpt.
    private static let whyLimit = 140

    /// The minimum cosine similarity for a semantic hit to be considered relevant at all.
    private static let cosineThreshold: Float = 0.2

    private let store: Store
    private let embedder: any Embedder

    public init(store: Store, embedder: any Embedder) {
        self.store = store
        self.embedder = embedder
    }

    /// Matches people by name/organization/phone digits, for the plain contact-list filter box.
    public func filter(_ text: String) throws -> [Person] {
        try store.people(matchingNameOrDigits: text)
    }

    /// Answers a natural-language "who can help with X" query, blending FTS5 keyword hits with
    /// embedding cosine similarity via reciprocal rank fusion.
    ///
    /// `terms` are the expansion terms (§7.3), which the caller owns: it runs `QueryExpander`
    /// once, shows the terms as removable chips, and asks again with the ones that are left —
    /// so a term the user dismissed is a term this search never sees, and no chip is ever out
    /// of step with the results below it. An empty `terms` is the plain search.
    ///
    /// The terms search alongside the query: they join the text that is embedded, and each one
    /// runs its own keyword search, all fused into one extra list. (They can't simply be
    /// appended to the keyword query — `ftsSearch` ANDs every term, so "taxes accountant CPA
    /// bookkeeper" would match nobody at all; and one list, not six, keeps an expansion from
    /// outvoting what the user typed.)
    ///
    /// `why` stays on the words the user actually typed, expansion or not — an excerpt
    /// explaining a match with a word the user never wrote reads like a bug.
    public func ask(_ query: String, limit: Int = 20, terms: [String] = []) async throws -> [SearchResult] {
        let cleaned = Self.strip(query)
        let tokens = Self.queryTokens(cleaned)
        let expansion = terms.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }

        // `ftsSearch` ANDs every token prefix, so handing it the raw query lets a single stop
        // word ("who can help with growth") match nothing and leave the fusion cosine-only.
        // Search the significant tokens instead, falling back to the raw query when the user
        // typed nothing but stop words or short tokens.
        let keywordQuery = tokens.isEmpty ? cleaned : tokens.joined(separator: " ")
        let keyword = try store.ftsSearch(keywordQuery, limit: 50).map(\.personId)
        let expanded = RankFusion.rrf(try expansion.map { try store.ftsSearch($0, limit: 50).map(\.personId) }).map(\.id)

        var semantic: [String] = []
        if let queryVector = try? await embedder.embed(([cleaned] + expansion).joined(separator: " ")) {
            let embeddings = try store.allEmbeddings()
            semantic = embeddings
                .map { (personId: $0.personId, cosine: Vector.cosine(queryVector, $0.vector)) }
                .filter { $0.cosine > Self.cosineThreshold }
                .sorted { lhs, rhs in
                    if lhs.cosine != rhs.cosine { return lhs.cosine > rhs.cosine }
                    // Deterministic tiebreak: cosine ties don't have a rank in the brief, so
                    // fall back to id order rather than leaving it to an unstable sort.
                    return lhs.personId < rhs.personId
                }
                .prefix(50)
                .map(\.personId)
        }
        // If the embedder threw, `semantic` stays empty and RRF below fuses the keyword list
        // alone (a list of one is still a valid input to rrf).

        let fused = RankFusion.rrf([keyword, expanded, semantic])
        guard !fused.isEmpty else { return [] }

        let profiles = try store.profilesByPerson()

        return try fused.prefix(limit).map { entry in
            SearchResult(personId: entry.id, score: entry.score, why: try why(personId: entry.id, tokens: tokens, profiles: profiles))
        }
    }

    /// Strips a leading `?` (and surrounding whitespace) so `"?growth"` and `"growth"` search
    /// identically — people naturally type search boxes like question fields.
    private static func strip(_ query: String) -> String {
        var cleaned = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if cleaned.hasPrefix("?") {
            cleaned.removeFirst()
            cleaned = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return cleaned
    }

    /// The query's significant tokens: normalized (lowercased, diacritic-folded), at least 3
    /// characters, and not a stop word.
    private static func queryTokens(_ query: String) -> [String] {
        NameMatcher.normalize(query)
            .split(separator: " ")
            .map(String.init)
            .filter { $0.count >= 3 && !stopWords.contains($0) }
    }

    /// A short excerpt explaining why `personId` matched: the first line of their profile facts
    /// (plus note body, if any) containing one of `tokens`, or their occupation when no line
    /// matches (including when `tokens` is empty because the query was only stop words).
    private func why(personId: String, tokens: [String], profiles: [String: Profile]) throws -> String {
        guard let profile = profiles[personId] else { return "" }
        let facts = profile.facts

        var text = facts.searchableText
        if let note = try store.note(personId: personId), !note.body.isEmpty {
            text += "\n" + note.body
        }

        if !tokens.isEmpty {
            let lines = text.split(separator: "\n", omittingEmptySubsequences: true)
            for line in lines {
                let normalizedLine = NameMatcher.normalize(String(line))
                if tokens.contains(where: { normalizedLine.contains($0) }) {
                    return Self.trimmed(String(line))
                }
            }
        }

        return Self.trimmed(facts.occupation ?? "")
    }

    private static func trimmed(_ text: String) -> String {
        text.count <= whyLimit ? text : String(text.prefix(whyLimit))
    }
}
