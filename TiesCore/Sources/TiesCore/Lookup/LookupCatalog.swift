import Foundation

/// Static description of one lookup service: what to call it, what its two credential fields
/// are, and one honest line about what it can actually answer.
public struct LookupSpec: Identifiable, Sendable, Hashable {
    public let id: String
    public let name: String
    /// Asset name, equal to `id`; a missing asset falls back to `fallbackSymbol`, as in the AI grid.
    public let logo: String
    /// Drawn when there is no logo asset for this service.
    public let fallbackSymbol: String
    /// Label for the first credential, or `nil` when the service needs only one.
    public let identifierLabel: String?
    public let secretLabel: String
    /// Where the user gets the credentials.
    public let keyURL: String?
    /// What this service answers, and where it answers it. Shown under the grid, because a
    /// lookup that returns nothing for every number outside the United States is a fact worth
    /// reading before paying for it.
    public let coverage: String
    /// True when this entry is a described endpoint rather than a coded integration: the user
    /// supplies the URL, and `CustomLookupProvider` does the calling.
    public let usesCustomEndpoint: Bool
    /// The mapping this service's answers usually need, filled in for the user. Never an
    /// endpoint: a preset saves the tedious half — which key in the reply is the name, which is
    /// the count — and leaves the half only the user's own access can supply.
    public let preset: CustomLookupConfig?

    public init(
        id: String,
        name: String,
        logo: String? = nil,
        fallbackSymbol: String = "puzzlepiece.extension",
        identifierLabel: String? = nil,
        secretLabel: String,
        keyURL: String? = nil,
        coverage: String,
        usesCustomEndpoint: Bool = false,
        preset: CustomLookupConfig? = nil
    ) {
        self.id = id
        self.name = name
        self.logo = logo ?? id
        self.fallbackSymbol = fallbackSymbol
        self.identifierLabel = identifierLabel
        self.secretLabel = secretLabel
        self.keyURL = keyURL
        self.coverage = coverage
        self.usesCustomEndpoint = usesCustomEndpoint
        self.preset = preset
    }
}

/// How to reach a service Ties has no built-in knowledge of: the URL to call, the header to
/// call it with, and where the names and tags sit in the answer.
///
/// This is the whole point of the lookup slot. Ties does not ship an integration with any
/// crowd-sourced "what do others call this number" database — those are built by uploading
/// everyone's address book, which is the one thing Ties promises never to do. But a user who
/// has their own access to one, business or otherwise, can describe it here and Ties will use
/// it without a line of code being written.
public struct CustomLookupConfig: Codable, Sendable, Hashable {
    /// The URL to call, with `{phone}`, `{phone_plain}`, `{email}` or `{name}` standing in for
    /// the query. `{phone}` is E.164 with its `+`; `{phone_plain}` is the digits alone.
    public var urlTemplate: String
    /// The header the secret goes in, if any — typically `Authorization`.
    public var headerName: String?
    /// What to put around the secret in that header, with `{key}` standing in for it. Defaults
    /// to the secret alone, so a service wanting `Bearer abc` is written as `Bearer {key}`.
    public var headerTemplate: String
    /// Where the names are, as a `JSONPath`: `result.tags[]`, say.
    public var namesPath: String
    /// The field to read each name out of, when the path lands on objects rather than strings.
    public var nameField: String?
    /// The field holding how many people used that name, when the service counts.
    public var countField: String?
    /// Where the occupational labels are, when the service keeps them apart from the names.
    public var tagsPath: String
    public var tagField: String?
    /// Whether the names this service returns were saved by other people (`true`) or registered
    /// against the line itself (`false`). It decides whether a name is strong enough to admit a
    /// web profile, so it is the user's to state rather than Ties's to guess.
    public var namesAreCrowd: Bool

    public init(
        urlTemplate: String = "",
        headerName: String? = "Authorization",
        headerTemplate: String = "{key}",
        namesPath: String = "",
        nameField: String? = nil,
        countField: String? = nil,
        tagsPath: String = "",
        tagField: String? = nil,
        namesAreCrowd: Bool = true
    ) {
        self.urlTemplate = urlTemplate
        self.headerName = headerName
        self.headerTemplate = headerTemplate
        self.namesPath = namesPath
        self.nameField = nameField
        self.countField = countField
        self.tagsPath = tagsPath
        self.tagField = tagField
        self.namesAreCrowd = namesAreCrowd
    }

    /// True when there is enough here to make a call at all: a placeholder the query can fill,
    /// and a URL left over that a request can actually be sent to.
    public var isUsable: Bool {
        let filled = LookupCatalog.fill(
            urlTemplate,
            with: LookupQuery(phoneE164: "+10000000000", email: "someone@example.com", name: "Test Name")
        )
        guard filled != urlTemplate, let url = URL(string: filled) else { return false }
        return url.scheme?.hasPrefix("http") == true
    }
}

/// The lookup services Ties knows how to talk to.
public enum LookupCatalog {
    public static let twilioId = "twilio"
    public static let getcontactId = "getcontact"
    public static let customId = "custom-lookup"

    /// The shape a "what do other people save this number as" service answers in: a list of
    /// labels, each with how many people used it. It is the mapping, not the service — there is
    /// no URL here, and there is no token here.
    static let tagServicePreset = CustomLookupConfig(
        urlTemplate: "",
        headerName: "Authorization",
        headerTemplate: "{key}",
        namesPath: "result.tags[]",
        nameField: "tag",
        countField: "count",
        tagsPath: "",
        tagField: nil,
        namesAreCrowd: true
    )

    public static let all: [LookupSpec] = [
        LookupSpec(
            id: twilioId,
            name: "Twilio Lookup",
            fallbackSymbol: "phone.badge.checkmark",
            identifierLabel: "Account SID",
            secretLabel: "Auth Token",
            keyURL: "https://www.twilio.com/console",
            coverage: "The name registered to the line (CNAM), plus carrier and line type. Caller name is United States only; carrier and line type are worldwide. Billed per lookup, including lookups that find nothing."
        ),
        LookupSpec(
            id: getcontactId,
            name: "GetContact",
            fallbackSymbol: "person.2.badge.key.fill",
            identifierLabel: nil,
            secretLabel: "Key",
            keyURL: "https://business.getcontact.com/",
            coverage: "The names other people saved a number under. Ties ships no endpoint and no token for it: GetContact has no public API, and the unofficial ones work by uploading your whole address book — which Ties will not do. Bring access you already have, paste its URL, and the reply is already mapped for you.",
            usesCustomEndpoint: true,
            preset: tagServicePreset
        ),
        LookupSpec(
            id: customId,
            name: "Custom",
            identifierLabel: nil,
            secretLabel: "Key",
            keyURL: nil,
            coverage: "Any HTTP service you already have access to. You give the URL and say where the names and tags sit in its answer; the key is kept in the Keychain and sent only in the header you name.",
            usesCustomEndpoint: true
        ),
    ]

    public static func spec(_ id: String) -> LookupSpec? {
        all.first { $0.id == id }
    }

    /// Keychain accounts, namespaced so a lookup key and an AI key of the same provider name
    /// can never collide.
    public static func identifierAccount(_ id: String) -> String { "lookup.\(id).identifier" }
    public static func secretAccount(_ id: String) -> String { "lookup.\(id).secret" }

    /// Substitutes a query into a URL template, percent-encoding each value.
    static func fill(_ template: String, with query: LookupQuery) -> String {
        let plain = query.phoneE164.map { $0.filter(\.isNumber) }
        let replacements = [
            "{phone}": query.phoneE164,
            "{phone_plain}": plain,
            "{email}": query.email,
            "{name}": query.name,
        ]
        var filled = template
        for (token, value) in replacements {
            guard filled.contains(token) else { continue }
            let encoded = (value ?? "").addingPercentEncoding(withAllowedCharacters: .urlQueryValueAllowed) ?? ""
            filled = filled.replacingOccurrences(of: token, with: encoded)
        }
        return filled
    }
}

extension CharacterSet {
    /// `.urlQueryAllowed` still permits `+`, `&` and `=`, which a phone number in E.164 and a
    /// name with an ampersand would both smuggle into the query string as syntax.
    static let urlQueryValueAllowed = CharacterSet.urlQueryAllowed.subtracting(CharacterSet(charactersIn: "+&=?#"))
}
