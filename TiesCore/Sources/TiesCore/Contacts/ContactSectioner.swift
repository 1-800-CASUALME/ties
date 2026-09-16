import Foundation

/// A letter-indexed group of items, e.g. for an alphabetical contact list with a section index.
public struct ContactSection<Item: Sendable>: Sendable, Identifiable {
    public var id: String { letter }
    public var letter: String
    public var items: [Item]

    public init(letter: String, items: [Item]) {
        self.letter = letter
        self.items = items
    }
}

/// Groups items into A-Z (plus "#" for anything that doesn't start with a letter) sections,
/// sorted A-Z with "#" last, and sorts items within each section.
public enum ContactSectioner {
    public static func sections<Item: Sendable>(_ items: [Item], name: (Item) -> String) -> [ContactSection<Item>] {
        var itemsByLetter: [String: [Item]] = [:]
        var lettersSeen: [String] = []

        for item in items {
            let letter = sectionLetter(for: name(item))
            if itemsByLetter[letter] == nil {
                itemsByLetter[letter] = []
                lettersSeen.append(letter)
            }
            itemsByLetter[letter]?.append(item)
        }

        let orderedLetters = lettersSeen.sorted { lhs, rhs in
            switch (lhs, rhs) {
            case ("#", "#"): return false
            case ("#", _): return false
            case (_, "#"): return true
            default: return lhs < rhs
            }
        }

        return orderedLetters.map { letter in
            let sortedItems = (itemsByLetter[letter] ?? []).sorted {
                name($0).localizedCaseInsensitiveCompare(name($1)) == .orderedAscending
            }
            return ContactSection(letter: letter, items: sortedItems)
        }
    }

    /// The section letter for `name`: the first character after diacritic- and
    /// case-insensitive folding, uppercased, or "#" when that character isn't a letter
    /// (or `name` is empty).
    private static func sectionLetter(for name: String) -> String {
        let folded = name.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
        guard let first = folded.first, first.isLetter else {
            return "#"
        }
        return String(first).uppercased()
    }
}
