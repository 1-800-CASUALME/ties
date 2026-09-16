import Foundation

/// Honorific vocabulary in English and Arabic, reduced to canonical ids (`"dr"`, `"eng"`, …).
///
/// The canonical ids double as keys into the profession words each honorific implies, so a
/// signature line reading "Engineer" and a chat message reading "Eng. Sara" produce the same
/// signal.
public enum Honorifics {
    /// Canonical id -> profession words that imply it.
    public static let english: [String: [String]] = [
        "dr": ["doctor", "physician", "dentist", "phd", "md"],
        "eng": ["engineer"],
        "prof": ["professor"],
        "sheikh": [],
        "capt": ["captain", "pilot"],
        "adv": ["lawyer", "attorney", "advocate"],
        "arch": ["architect"],
    ]

    /// Arabic honorific -> canonical id. Matching also covers the undiacriticised spellings and
    /// the definite article ("المهندس"), which are folded away before lookup.
    public static let arabic: [String: String] = [
        "دكتور": "dr",
        "دكتورة": "dr",
        "د.": "dr",
        "مهندس": "eng",
        "مهندسة": "eng",
        "م.": "eng",
        "أستاذ": "prof",
        "استاذ": "prof",
        "أ.": "prof",
        "شيخ": "sheikh",
        "كابتن": "capt",
        "محامي": "adv",
    ]

    /// `arabic`, re-keyed by the folded spelling, so a token stripped of its diacritics still
    /// resolves. Built once; the keys are sorted so a collision resolves deterministically.
    private static let foldedArabic: [String: String] = {
        var map: [String: String] = [:]
        for key in arabic.keys.sorted() {
            map[fold(key)] = arabic[key]
        }
        return map
    }()

    /// Profession word -> canonical id, so "Professor Sara" reads like "Prof. Sara".
    private static let professionToCanonical: [String: String] = {
        var map: [String: String] = [:]
        for canonical in english.keys.sorted() {
            for profession in english[canonical] ?? [] {
                map[profession] = canonical
            }
        }
        return map
    }()

    /// Every profession word across every canonical id.
    static let allProfessions: Set<String> = Set(english.values.flatMap { $0 })

    /// The canonical id for a single token — `"Dr."`, `"DR"`, `"دكتور"` and `"المهندس"` all map
    /// to their id — or `nil` when the token is not an honorific.
    public static func canonical(_ token: String) -> String? {
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        // Arabic first: the single-letter forms ("د.", "م.") depend on the trailing period that
        // the English path strips, and Arabic carries no case to fold.
        if let hit = arabic[trimmed] { return hit }
        let folded = fold(trimmed)
        if let hit = foldedArabic[folded] { return hit }
        if folded.hasPrefix(definiteArticle), let hit = foldedArabic[String(folded.dropFirst(definiteArticle.count))] {
            return hit
        }

        let latin = trimmed.lowercased()
            .trimmingCharacters(in: .punctuationCharacters.union(.whitespaces))
        if english[latin] != nil { return latin }
        return professionToCanonical[latin]
    }

    /// The profession words implied by a canonical id; empty for an unknown id.
    public static func professions(for canonical: String) -> [String] {
        english[canonical] ?? []
    }

    private static let definiteArticle = "ال"

    /// Drops Arabic diacritics and tatweel and unifies the letter shapes that writers vary
    /// freely (alef forms, ta marbuta, alef maqsura), leaving other scripts untouched.
    private static func fold(_ s: String) -> String {
        var folded = ""
        folded.reserveCapacity(s.count)
        for scalar in s.unicodeScalars {
            switch scalar.value {
            case 0x064B...0x0652, 0x0670, 0x0640, 0x200C...0x200F:
                continue  // tashkeel, dagger alef, tatweel, bidi/joiner controls
            case 0x0622, 0x0623, 0x0625, 0x0671:
                folded.append("ا")
            case 0x0629:
                folded.append("ه")
            case 0x0649, 0x06CC:
                folded.append("ي")
            default:
                folded.unicodeScalars.append(scalar)
            }
        }
        return folded
    }
}
