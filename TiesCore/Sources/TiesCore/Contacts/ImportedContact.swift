import Foundation
import Contacts

/// A single labeled value (a phone number, email, or URL) as Apple Contacts represents it:
/// a raw value plus an optional, possibly-localized label like "Mobile" or "Work".
public struct LabeledValue: Sendable, Hashable {
    public var label: String?
    public var value: String

    public init(label: String?, value: String) {
        self.label = label
        self.value = value
    }
}

/// A contact read from either Apple Contacts (`ContactsService`) or a vCard
/// (`VCardImporter`), independent of the source.
public struct ImportedContact: Sendable, Hashable {
    public var identifier: String
    public var givenName: String
    public var familyName: String
    public var organization: String?
    public var jobTitle: String?
    /// The name the user filed them under: another name the person goes by (spec §4.2).
    public var nickname: String?
    /// The user's own note about them. Read for honorifics, aliases, and links — never stored
    /// as text, and never sent anywhere.
    public var note: String?
    public var phones: [LabeledValue]
    public var emails: [LabeledValue]
    public var urls: [LabeledValue]
    /// The city and country of the first postal address that carries them — the person's
    /// `location` signal.
    public var postalCity: String?
    public var postalCountry: String?
    public var thumbnail: Data?

    public init(
        identifier: String,
        givenName: String,
        familyName: String,
        organization: String? = nil,
        jobTitle: String? = nil,
        nickname: String? = nil,
        note: String? = nil,
        phones: [LabeledValue] = [],
        emails: [LabeledValue] = [],
        urls: [LabeledValue] = [],
        postalCity: String? = nil,
        postalCountry: String? = nil,
        thumbnail: Data? = nil
    ) {
        self.identifier = identifier
        self.givenName = givenName
        self.familyName = familyName
        self.organization = organization
        self.jobTitle = jobTitle
        self.nickname = nickname
        self.note = note
        self.phones = phones
        self.emails = emails
        self.urls = urls
        self.postalCity = postalCity
        self.postalCountry = postalCountry
        self.thumbnail = thumbnail
    }
}

extension ImportedContact {
    /// True when there's no given name, family name, or organization to identify this contact
    /// by. Both `ContactsService.fetchAll()` and `ContactSync.toRecords` skip such contacts.
    var hasNoNameOrOrg: Bool {
        givenName.isEmpty && familyName.isEmpty && (organization ?? "").isEmpty
    }
}

extension ImportedContact {
    /// Shared `CNContact` -> `ImportedContact` mapping, used by both `ContactsService.fetchAll()`
    /// and `VCardImporter.parse(_:)` so the two importers read fields and labels identically.
    ///
    /// Every optional key is guarded by `isKeyAvailable`: reading a key that was not fetched
    /// raises an Objective-C exception, which in Swift is a crash rather than an error — and the
    /// note key in particular is routinely absent, since an unsigned build cannot hold the
    /// entitlement to fetch it.
    init(cnContact contact: CNContact, identifier: String) {
        let address = contact.isKeyAvailable(CNContactPostalAddressesKey)
            ? contact.postalAddresses.map(\.value).first(where: { !$0.city.isEmpty || !$0.country.isEmpty })
            : nil
        self.init(
            identifier: identifier,
            givenName: contact.givenName,
            familyName: contact.familyName,
            organization: contact.organizationName.isEmpty ? nil : contact.organizationName,
            jobTitle: contact.jobTitle.isEmpty ? nil : contact.jobTitle,
            nickname: Self.nonEmpty(contact.isKeyAvailable(CNContactNicknameKey) ? contact.nickname : nil),
            note: Self.nonEmpty(contact.isKeyAvailable(CNContactNoteKey) ? contact.note : nil),
            phones: contact.phoneNumbers.map { labeled in
                LabeledValue(label: Self.localizedLabel(labeled.label), value: labeled.value.stringValue)
            },
            emails: contact.emailAddresses.map { labeled in
                LabeledValue(label: Self.localizedLabel(labeled.label), value: labeled.value as String)
            },
            urls: contact.urlAddresses.map { labeled in
                LabeledValue(label: Self.localizedLabel(labeled.label), value: labeled.value as String)
            },
            postalCity: Self.nonEmpty(address?.city),
            postalCountry: Self.nonEmpty(address?.country),
            thumbnail: contact.isKeyAvailable(CNContactThumbnailImageDataKey) ? contact.thumbnailImageData : nil
        )
    }

    private static func localizedLabel(_ label: String?) -> String? {
        label.map { CNLabeledValue<NSString>.localizedString(forLabel: $0) }
    }

    /// A trimmed value, or `nil` when there is nothing there — Contacts writes "" for an absent
    /// string, and an empty alias or city is worse than none.
    private static func nonEmpty(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines)
        return (trimmed?.isEmpty ?? true) ? nil : trimmed
    }
}
