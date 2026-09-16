import Foundation

/// The normalized inputs a `Probe` needs to research a person: their name, the contact channels
/// (emails, phones, URLs) gathered from Contacts and prior probes, and whatever this Mac
/// already knows about them locally.
public struct ProbeInput: Sendable {
    public var person: Person
    public var channels: [Channel]
    /// Normalized email addresses, from `channels` where `kind == .email`.
    public var emails: [String]
    /// E.164 phone numbers, from `channels` where `kind == .phone`.
    public var phonesE164: [String]
    /// Normalized URLs, from `channels` where `kind == .url`.
    public var urls: [String]
    /// `person.displayName`.
    public var fullName: String
    /// `person.organization`.
    public var company: String?
    /// What Messages, WhatsApp and Mail already know about this person — `nil` when nothing has
    /// been collected (or when the caller is a probe test that doesn't care).
    public var signals: LocalSignals?

    /// Every name the person goes by: the one in Contacts first, then the aliases the local
    /// signals collected (nickname, WhatsApp push name, the name used in chats).
    public var aliases: [String] { Self.union([fullName], signals?.aliases ?? []) }

    /// Job titles: the one in Contacts first, then the ones read out of mail signatures.
    public var titles: [String] { Self.union([person.jobTitle].compactMap(\.self), signals?.titles ?? []) }

    /// Companies: the Contacts organization first, then the ones read out of mail signatures.
    public var companies: [String] { Self.union([company].compactMap(\.self), signals?.companies ?? []) }

    public init(person: Person, channels: [Channel], signals: LocalSignals? = nil) {
        self.person = person
        self.channels = channels
        self.emails = channels.filter { $0.kind == .email }.map(\.normalized)
        self.phonesE164 = channels.filter { $0.kind == .phone }.map(\.normalized)
        self.urls = channels.filter { $0.kind == .url }.map(\.normalized)
        self.fullName = person.displayName
        self.company = person.organization
        self.signals = signals
    }

    /// `a` followed by the members of `b` it doesn't already hold, trimmed, blanks dropped, each
    /// kept once and compared case-insensitively so "Acme" and "ACME" are one company.
    private static func union(_ a: [String], _ b: [String]) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for value in a + b {
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, seen.insert(trimmed.lowercased()).inserted else { continue }
            result.append(trimmed)
        }
        return result
    }
}
