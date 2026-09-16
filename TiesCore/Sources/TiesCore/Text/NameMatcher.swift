import Foundation

/// Fuzzy name matching for reconciling contact names against names found on the web.
public enum NameMatcher {
    /// The similarity score above which two names are considered a match.
    public static let gate: Double = 0.8

    /// Canonical name -> known nicknames/variants. Every token of both names is expanded to
    /// its canonical form (if any) before the nickname-aware comparison is run.
    private static let nicknames: [String: [String]] = [
        "robert": ["bob", "rob", "bobby"],
        "michael": ["mike", "mikey"],
        "sarah": ["sara"],
        "alexander": ["alex"],
        "alexandra": ["alex"],
        "william": ["will", "bill", "billy"],
        "elizabeth": ["liz", "beth", "betty"],
        "james": ["jim", "jimmy"],
        "david": ["dave"],
        "thomas": ["tom", "tommy"],
        "mohammed": ["mo", "mohamed", "muhammad"],
    ]

    /// variant -> canonical, built once from `nicknames`. Iterates canonical keys in sorted
    /// order so that when a variant (e.g. "alex") is claimed by more than one canonical
    /// ("alexander" and "alexandra"), the winner is deterministic across runs rather than
    /// depending on Dictionary's unspecified iteration order.
    private static let variantToCanonical: [String: String] = {
        var map: [String: String] = [:]
        for canonical in nicknames.keys.sorted() {
            for variant in nicknames[canonical] ?? [] {
                map[variant] = canonical
            }
        }
        return map
    }()

    /// Tokens that carry no discriminating identity signal (e.g. Arabic "Abu" — "father of").
    private static let ignoredTokens: Set<String> = ["abu"]

    /// Lowercases, folds diacritics, turns punctuation into spaces, and collapses whitespace.
    public static func normalize(_ s: String) -> String {
        // Fixed POSIX locale: casing/diacritic folding must be identical on every device
        // regardless of the user's system locale, since normalized names are compared and
        // persisted, not just displayed.
        let folded = s.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "en_US_POSIX"))
        var result = ""
        result.reserveCapacity(folded.count)
        var lastWasSpace = false
        for scalar in folded.unicodeScalars {
            if CharacterSet.alphanumerics.contains(scalar) {
                result.unicodeScalars.append(scalar)
                lastWasSpace = false
            } else if !lastWasSpace {
                result.append(" ")
                lastWasSpace = true
            }
        }
        return result.trimmingCharacters(in: .whitespaces)
    }

    private static func tokens(_ normalized: String) -> [String] {
        normalized.split(separator: " ").map(String.init)
    }

    private static func canonicalToken(_ token: String) -> String {
        variantToCanonical[token] ?? token
    }

    /// Standard Jaro-Winkler similarity in [0, 1].
    public static func jaroWinkler(_ a: String, _ b: String) -> Double {
        let s1 = Array(a)
        let s2 = Array(b)
        if s1 == s2 { return 1.0 }
        let len1 = s1.count
        let len2 = s2.count
        if len1 == 0 || len2 == 0 { return 0.0 }

        let matchDistance = max(len1, len2) / 2 - 1
        var s1Matches = [Bool](repeating: false, count: len1)
        var s2Matches = [Bool](repeating: false, count: len2)

        var matches = 0
        for i in 0..<len1 {
            let lo = max(0, i - matchDistance)
            let hi = min(i + matchDistance, len2 - 1)
            if lo > hi { continue }
            for j in lo...hi {
                if s2Matches[j] { continue }
                if s1[i] != s2[j] { continue }
                s1Matches[i] = true
                s2Matches[j] = true
                matches += 1
                break
            }
        }
        if matches == 0 { return 0.0 }

        var transpositions = 0
        var k = 0
        for i in 0..<len1 {
            if !s1Matches[i] { continue }
            while !s2Matches[k] { k += 1 }
            if s1[i] != s2[k] { transpositions += 1 }
            k += 1
        }
        let t = Double(transpositions) / 2.0

        let m = Double(matches)
        let jaro = (m / Double(len1) + m / Double(len2) + (m - t) / m) / 3.0

        var prefix = 0
        let maxPrefix = 4
        for i in 0..<min(min(len1, len2), maxPrefix) {
            if s1[i] == s2[i] { prefix += 1 } else { break }
        }
        let scale = 0.1
        return jaro + Double(prefix) * scale * (1.0 - jaro)
    }

    /// Set-based token overlap ratio, gated on EVERY significant token of the person's name
    /// (length >= 2, excluding ignored tokens like "abu") appearing somewhere in the
    /// candidate's token set — order-independent, so a reordered name ("Ahmed Sara" for person
    /// "Sara Ahmed") still counts as a match, and a candidate that merely shares one token with
    /// the person's name (e.g. just the family name) does not.
    private static func tokenSetRatio(person: String, candidate: String) -> Double {
        let personTokens = tokens(person)
        let candidateTokens = tokens(candidate)
        let tb = Set(candidateTokens)

        let gatingTokens = personTokens.filter { $0.count >= 2 && !ignoredTokens.contains($0) }
        guard !gatingTokens.isEmpty, gatingTokens.allSatisfy({ tb.contains($0) }) else { return 0.0 }

        let ta = Set(personTokens)
        return Double(ta.intersection(tb).count) / Double(max(1, min(ta.count, tb.count)))
    }

    /// Expands every token to its nickname-canonical form (ignoring tokens like "abu"), then
    /// runs Jaro-Winkler on the rejoined strings, preserving each name's own token order.
    /// (Token order independence is the token-set path's job, not this one's: sorting tokens
    /// here before joining would let any two names that merely share a single token — e.g. both
    /// containing "ahmed" — produce a large spurious common prefix once that shared token sorts
    /// to the front on both sides, inflating the score even when the rest of the name differs.)
    private static func nicknameExpandedSimilarity(_ a: String, _ b: String) -> Double {
        func canonicalize(_ normalized: String) -> String {
            tokens(normalized)
                .filter { !ignoredTokens.contains($0) }
                .map(canonicalToken)
                .joined(separator: " ")
        }
        let ca = canonicalize(a)
        let cb = canonicalize(b)
        if ca.isEmpty || cb.isEmpty { return 0.0 }
        return jaroWinkler(ca, cb)
    }

    /// The similarity between a contact's name and a candidate name found elsewhere, as the
    /// max of three signals: whole-name Jaro-Winkler, token-set overlap (gated on every
    /// significant person-name token appearing in the candidate), and Jaro-Winkler after
    /// nickname canonicalisation (also order-independent).
    public static func similarity(personName: String, candidateName: String) -> Double {
        let a = normalize(personName)
        let b = normalize(candidateName)
        if a.isEmpty || b.isEmpty { return 0.0 }
        if a == b { return 1.0 }

        let whole = jaroWinkler(a, b)
        let tokenSet = tokenSetRatio(person: a, candidate: b)
        let nickname = nicknameExpandedSimilarity(a, b)
        return max(whole, tokenSet, nickname)
    }

    /// True when every token (length >= 2) of the normalized person name occurs somewhere in
    /// the normalized text.
    public static func containsName(_ text: String, personName: String) -> Bool {
        let normalizedText = normalize(text)
        let textTokens = Set(tokens(normalizedText))
        let nameTokens = tokens(normalize(personName)).filter { $0.count >= 2 }
        guard !nameTokens.isEmpty else { return false }
        return nameTokens.allSatisfy { textTokens.contains($0) }
    }
}
