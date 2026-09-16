import AppKit
import SwiftUI
import TiesCore
import UniformTypeIdentifiers

/// The outward-facing things the detail view can do with a person: hand a number or an address
/// to whichever app the user has set for it, and package the whole person up as a vCard.
///
/// Every one of these is a URL scheme macOS routes itself, so Ties never has to know — or ask
/// for permission to know — which app answers a phone call or writes mail on this Mac.
enum Actions {
    static func call(_ phone: String) {
        open("tel:", dialable(phone))
    }

    static func message(_ phone: String) {
        open("sms:", dialable(phone))
    }

    /// Takes either a phone number or an Apple ID email, which is what FaceTime itself accepts.
    static func facetime(_ value: String) {
        open("facetime:", value.contains("@") ? value.trimmingCharacters(in: .whitespaces) : dialable(value))
    }

    static func mail(_ email: String) {
        open("mailto:", email.trimmingCharacters(in: .whitespaces))
    }

    /// A person as a shareable `.vcf`: their name and contact details, plus what the research
    /// found about them in the NOTE field, which is the only place a vCard has for prose.
    static func vCardItem(person: Person, channels: [Channel], facts: ProfileFacts?) -> VCardFile {
        var lines = ["BEGIN:VCARD", "VERSION:3.0"]
        lines.append("N:\(escape(person.familyName));\(escape(person.givenName));;;")
        lines.append("FN:\(escape(person.displayName))")
        if let organization = person.organization, !organization.isEmpty {
            lines.append("ORG:\(escape(organization))")
        }
        if let jobTitle = person.jobTitle, !jobTitle.isEmpty {
            lines.append("TITLE:\(escape(jobTitle))")
        }
        for channel in channels {
            let label = channel.label.map { ";TYPE=\(escape($0))" } ?? ""
            switch channel.kind {
            case .phone: lines.append("TEL\(label):\(escape(channel.value))")
            case .email: lines.append("EMAIL;TYPE=INTERNET\(label):\(escape(channel.value))")
            case .url: lines.append("URL\(label):\(escape(channel.value))")
            }
        }
        let note = [facts?.occupation, facts?.summary]
            .compactMap { $0 }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
        if !note.isEmpty {
            lines.append("NOTE:\(escape(note))")
        }
        lines.append("END:VCARD")

        return VCardFile(fileName: fileName(for: person), text: lines.joined(separator: "\r\n") + "\r\n")
    }

    // MARK: - Helpers

    /// Digits only, keeping a leading `+` so an international number still dials.
    private static func dialable(_ phone: String) -> String {
        let trimmed = phone.trimmingCharacters(in: .whitespaces)
        let digits = trimmed.filter(\.isNumber)
        return trimmed.hasPrefix("+") ? "+" + digits : digits
    }

    private static func open(_ scheme: String, _ value: String) {
        guard !value.isEmpty,
              let encoded = value.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
              let url = URL(string: scheme + encoded)
        else { return }
        NSWorkspace.shared.open(url)
    }

    /// RFC 6350 text escaping: backslashes, commas, semicolons, and newlines all carry meaning
    /// inside a property value and have to be spelled out.
    private static func escape(_ text: String) -> String {
        text
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: ",", with: "\\,")
            .replacingOccurrences(of: ";", with: "\\;")
    }

    private static func fileName(for person: Person) -> String {
        let cleaned = person.displayName
            .components(separatedBy: CharacterSet(charactersIn: "/:\\"))
            .joined(separator: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return (cleaned.isEmpty ? "Contact" : cleaned) + ".vcf"
    }
}

/// One person written out as vCard text, exported as a real `.vcf` file so the share sheet
/// offers every app that takes a contact — Mail, Messages, AirDrop, Contacts itself.
struct VCardFile: Transferable, Sendable {
    let fileName: String
    let text: String

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(exportedContentType: .vCard) { card in
            let url = FileManager.default.temporaryDirectory.appendingPathComponent(card.fileName)
            try card.text.write(to: url, atomically: true, encoding: .utf8)
            return SentTransferredFile(url)
        }
        .suggestedFileName { $0.fileName }
    }
}
