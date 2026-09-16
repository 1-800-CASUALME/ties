import Foundation

/// Turns `ImportedContact`s into `Person`/`Channel` records and writes them into the store.
public enum ContactSync {
    /// Converts contacts into store records. Contacts whose given name, family name, and
    /// organization are all blank are skipped. Phones are normalized with `PhoneNormalizer`
    /// using the current locale's region, falling back to a simple digits(+leading `+`)
    /// normalization when parsing fails; emails are lowercased and trimmed; URLs are lowercased,
    /// trimmed, and have a trailing slash removed.
    public static func toRecords(_ contacts: [ImportedContact]) -> (people: [Person], channels: [Channel]) {
        let defaultRegion = Locale.current.region?.identifier ?? "US"

        var people: [Person] = []
        var channels: [Channel] = []

        for contact in contacts {
            guard !contact.hasNoNameOrOrg else {
                continue
            }

            let person = Person(
                cnIdentifier: contact.identifier,
                givenName: contact.givenName,
                familyName: contact.familyName,
                organization: contact.organization,
                jobTitle: contact.jobTitle,
                thumbnail: contact.thumbnail
            )
            people.append(person)

            for phone in contact.phones {
                let normalized = PhoneNormalizer.e164(phone.value, defaultRegion: defaultRegion)
                    ?? digitsWithLeadingPlus(phone.value)
                channels.append(Channel(personId: person.id, kind: .phone, label: phone.label, value: phone.value, normalized: normalized))
            }
            for email in contact.emails {
                let normalized = email.value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                channels.append(Channel(personId: person.id, kind: .email, label: email.label, value: email.value, normalized: normalized))
            }
            for url in contact.urls {
                var normalized = url.value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                if normalized.hasSuffix("/") {
                    normalized.removeLast()
                }
                channels.append(Channel(personId: person.id, kind: .url, label: url.label, value: url.value, normalized: normalized))
            }
        }

        return (people, channels)
    }

    /// Fallback normalization for a phone number `PhoneNormalizer.e164` couldn't parse: digits
    /// only, keeping a leading `+` when the raw value had one.
    private static func digitsWithLeadingPlus(_ raw: String) -> String {
        let digits = PhoneNormalizer.digits(raw)
        return raw.trimmingCharacters(in: .whitespaces).hasPrefix("+") ? "+" + digits : digits
    }

    /// Converts and upserts `contacts` into `store`, returning the number of people written.
    public static func sync(_ contacts: [ImportedContact], into store: Store) throws -> Int {
        let (people, channels) = toRecords(contacts)
        try store.upsertPeople(people, channels: channels)
        return people.count
    }
}
