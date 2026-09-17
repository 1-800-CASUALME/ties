import SwiftUI
import TiesCore

/// What other people call this person, as small capsules: the honorifics they are addressed
/// with ("Dr", "Eng"), the other names they go by, and — when a link they shared themselves is
/// what verified their identity — a `link` chip saying so (§6).
///
/// Everything here came off this Mac, from Contacts, Messages, WhatsApp and Mail. The chips are
/// the one place the user sees what those collectors read, so a person with no signals draws
/// nothing at all rather than an empty row of placeholders.
struct KnownAsChips: View {
    let signals: LocalSignals?
    /// Whether the identity settled on was verified by a link the person shared or signed with.
    var hasSelfLink = false
    /// How many name chips fit where this is being drawn. The list rows have far less room than
    /// the detail header, so the caller says.
    var limit = 3

    var body: some View {
        if !chips.isEmpty {
            HStack(spacing: 6) {
                ForEach(chips) { chip in
                    capsule(chip)
                }
            }
        }
    }

    private func capsule(_ chip: Chip) -> some View {
        HStack(spacing: 4) {
            Image(systemName: chip.symbol)
            if !chip.text.isEmpty {
                Text(chip.text)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(Capsule().fill(.quaternary.opacity(0.6)))
        .help(chip.help)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(chip.help)
    }

    /// Honorifics first — they are one word each and they qualify the names that follow — then
    /// the aliases, then the self-link chip, which is about the match rather than the name and
    /// so is never crowded out by one.
    private var chips: [Chip] {
        var chips: [Chip] = []
        for (index, honorific) in (signals?.honorifics ?? []).enumerated() {
            let title = Self.display(honorific)
            chips.append(Chip(
                id: "honorific-\(index)",
                text: title,
                symbol: "person.text.rectangle",
                help: "Addressed as \(title)"
            ))
        }
        for (index, alias) in (signals?.aliases ?? []).enumerated() {
            chips.append(Chip(
                id: "alias-\(index)",
                text: alias,
                symbol: "person.text.rectangle",
                help: "Known as \(alias)"
            ))
        }
        chips = Array(chips.prefix(limit))
        if hasSelfLink {
            chips.append(Chip(
                id: "link",
                text: "",
                symbol: "link",
                help: "Verified by a link they shared themselves"
            ))
        }
        return chips
    }

    /// `Honorifics` stores canonical ids (`"dr"`, `"eng"`), which is what makes an Arabic
    /// "دكتور" and an English "Dr." the same signal; this is how one is written on a chip.
    /// An id this build doesn't know is capitalized rather than dropped — a signal collected by
    /// a later version is still worth showing.
    private static func display(_ canonical: String) -> String {
        switch canonical {
        case "dr": "Dr"
        case "eng": "Eng"
        case "prof": "Prof"
        case "sheikh": "Sheikh"
        case "capt": "Capt"
        case "adv": "Adv"
        case "arch": "Arch"
        default: canonical.capitalized
        }
    }

    /// Identified by where it came from rather than by what it says: two people in the same
    /// address book can be "Dr", and a person can go by two spellings of one alias, which as a
    /// `\.self` id made SwiftUI drop the duplicate.
    private struct Chip: Identifiable, Hashable {
        var id: String
        var text: String
        var symbol: String
        var help: String
    }
}
