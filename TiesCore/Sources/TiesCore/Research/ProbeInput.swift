import Foundation

/// The normalized inputs a `Probe` needs to research a person: their name, and the
/// contact channels (emails, phones, URLs) gathered from Contacts and prior probes.
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

    public init(person: Person, channels: [Channel]) {
        self.person = person
        self.channels = channels
        self.emails = channels.filter { $0.kind == .email }.map(\.normalized)
        self.phonesE164 = channels.filter { $0.kind == .phone }.map(\.normalized)
        self.urls = channels.filter { $0.kind == .url }.map(\.normalized)
        self.fullName = person.displayName
        self.company = person.organization
    }
}
