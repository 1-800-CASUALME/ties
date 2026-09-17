import Foundation

/// How firmly a looked-up name is attached to the number it came back for.
public enum LookupNameKind: String, Codable, Sendable {
    /// Registered against the line itself — a carrier's CNAM record, a verified business name.
    /// Nobody chose it socially, so it carries the weight of a name the person set themselves.
    case registered
    /// What other people saved the number as. Good enough to show as a "known as" chip and to
    /// read an honorific out of, never good enough on its own to admit a web profile as this
    /// person: a crowd can be confidently wrong together, and often is about a common name.
    case crowd
}

/// One name a lookup service returned for a number, with how many people used it when the
/// service counts.
public struct LookupName: Codable, Hashable, Sendable {
    public var value: String
    public var kind: LookupNameKind
    public var count: Int?

    public init(value: String, kind: LookupNameKind, count: Int? = nil) {
        self.value = value
        self.kind = kind
        self.count = count
    }
}

/// What Ties asks a lookup service about one person. Only ever one channel per call: a service
/// bills per lookup, and asking about a number and an address at once would hide which of them
/// the answer is about.
public struct LookupQuery: Sendable, Hashable {
    public var phoneE164: String?
    public var email: String?
    /// The name Ties already holds, for the services that answer "does this name belong to this
    /// line?" rather than "what is this line called?". Never sent by a provider that has no use
    /// for it.
    public var name: String?

    public init(phoneE164: String? = nil, email: String? = nil, name: String? = nil) {
        self.phoneE164 = phoneE164
        self.email = email
        self.name = name
    }
}

/// What a lookup service knows about one number or address.
public struct LookupResult: Codable, Hashable, Sendable {
    public var names: [LookupName]
    /// Labels that say what someone *is* rather than what to call them — "Doctor", "Plumber",
    /// "مهندس" — spelled as the service returned them.
    public var tags: [String]
    public var carrier: String?
    public var lineType: String?
    /// `0...1` when the service was asked whether `LookupQuery.name` belongs to this line and
    /// answered with a score.
    public var nameMatch: Double?
    public var providerId: String

    public init(
        names: [LookupName] = [],
        tags: [String] = [],
        carrier: String? = nil,
        lineType: String? = nil,
        nameMatch: Double? = nil,
        providerId: String
    ) {
        self.names = names
        self.tags = tags
        self.carrier = carrier
        self.lineType = lineType
        self.nameMatch = nameMatch
        self.providerId = providerId
    }

    /// True when the service answered but had nothing on this number — a paid call that bought
    /// no signal, which the collector records as a miss rather than storing an empty row.
    public var isEmpty: Bool {
        names.isEmpty && tags.isEmpty && carrier == nil && lineType == nil && nameMatch == nil
    }
}

public enum LookupError: Error, Sendable, Equatable {
    /// No provider chosen, or the chosen one has no credentials yet.
    case notConfigured
    /// The credentials were refused. Worth stopping the whole pass for: every later call would
    /// be refused too, and some services bill for a refusal.
    case unauthorized
    case rateLimited(retryAfter: TimeInterval?)
    case http(Int)
    case malformed(String)
}

/// One service that answers "whose number is this, and what do other people call it?".
///
/// Ties ships two: a documented commercial API, and a configurable HTTP endpoint for whatever
/// service the user has their own access to. Neither is built in to the research run — a number
/// leaves this Mac only when the user has chosen a provider, given it a key, and left the
/// Lookup source switched on.
public protocol LookupProvider: Sendable {
    var id: String { get }
    /// `nil` when the service answered and has nothing on this query, which is a normal outcome
    /// and not an error. Throws `LookupError` when the call itself failed.
    func lookup(_ query: LookupQuery) async throws -> LookupResult?
}
