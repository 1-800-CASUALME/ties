import Foundation

/// Combines the per-chunk answers from one extraction run into a single profile.
///
/// Chunks overlap in what they describe, so the same company or achievement comes back
/// worded slightly differently from several of them. Facts are therefore keyed by their
/// normalized text (the same normalization name matching uses: case- and diacritic-folded,
/// punctuation flattened), keeping the first wording and unioning the citations.
public enum FactsMerger {
    /// The most tags a profile carries, matching the limit the prompt asks the model for.
    private static let maxTags = 8

    public static func merge(_ parts: [ProfileFacts]) -> ProfileFacts {
        ProfileFacts(
            occupation: parts.compactMap { cleaned($0.occupation) }.first,
            summary: parts.compactMap { cleaned($0.summary) }.first,
            companies: mergeFacts(parts.flatMap(\.companies)),
            achievements: mergeFacts(parts.flatMap(\.achievements)),
            certificates: mergeFacts(parts.flatMap(\.certificates)),
            experience: mergeFacts(parts.flatMap(\.experience)),
            canHelpWith: mergeTags(parts.flatMap(\.canHelpWith))
        )
    }

    /// De-duplicates by normalized text, in first-seen order, unioning sources.
    private static func mergeFacts(_ facts: [Fact]) -> [Fact] {
        var order: [String] = []
        var merged: [String: Fact] = [:]

        for fact in facts {
            guard let text = cleaned(fact.text) else { continue }
            let key = NameMatcher.normalize(text)
            guard !key.isEmpty else { continue }
            let sources = fact.sources.compactMap { cleaned($0) }
            if var existing = merged[key] {
                for source in sources where !existing.sources.contains(source) {
                    existing.sources.append(source)
                }
                merged[key] = existing
            } else {
                order.append(key)
                var deduped: [String] = []
                for source in sources where !deduped.contains(source) { deduped.append(source) }
                merged[key] = Fact(text: text, sources: deduped)
            }
        }
        return order.compactMap { merged[$0] }
    }

    /// Lowercases, de-duplicates in first-seen order, and caps at `maxTags`.
    private static func mergeTags(_ tags: [String]) -> [String] {
        var seen: Set<String> = []
        var merged: [String] = []
        for tag in tags {
            guard let cleaned = cleaned(tag)?.lowercased(), seen.insert(cleaned).inserted else { continue }
            merged.append(cleaned)
            if merged.count == maxTags { break }
        }
        return merged
    }

    private static func cleaned(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
