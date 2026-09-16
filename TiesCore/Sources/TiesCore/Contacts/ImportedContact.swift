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
    public var phones: [LabeledValue]
    public var emails: [LabeledValue]
    public var urls: [LabeledValue]
    public var thumbnail: Data?

    public init(
        identifier: String,
        givenName: String,
        familyName: String,
        organization: String? = nil,
        jobTitle: String? = nil,
        phones: [LabeledValue] = [],
        emails: [LabeledValue] = [],
        urls: [LabeledValue] = [],
        thumbnail: Data? = nil
    ) {
        self.identifier = identifier
        self.givenName = givenName
        self.familyName = familyName
        self.organization = organization
        self.jobTitle = jobTitle
        self.phones = phones
        self.emails = emails
        self.urls = urls
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
    init(cnContact contact: CNContact, identifier: String) {
        self.init(
            identifier: identifier,
            givenName: contact.givenName,
            familyName: contact.familyName,
            organization: contact.organizationName.isEmpty ? nil : contact.organizationName,
            jobTitle: contact.jobTitle.isEmpty ? nil : contact.jobTitle,
            phones: contact.phoneNumbers.map { labeled in
                LabeledValue(label: Self.localizedLabel(labeled.label), value: labeled.value.stringValue)
            },
            emails: contact.emailAddresses.map { labeled in
                LabeledValue(label: Self.localizedLabel(labeled.label), value: labeled.value as String)
            },
            urls: contact.urlAddresses.map { labeled in
                LabeledValue(label: Self.localizedLabel(labeled.label), value: labeled.value as String)
            },
            thumbnail: contact.isKeyAvailable(CNContactThumbnailImageDataKey) ? contact.thumbnailImageData : nil
        )
    }

    private static func localizedLabel(_ label: String?) -> String? {
        label.map { CNLabeledValue<NSString>.localizedString(forLabel: $0) }
    }
}
