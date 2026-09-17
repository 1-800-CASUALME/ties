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
    ///
    /// Each contact's extras — nickname, note, postal city/country — are written as that person's
    /// Contacts contribution, in the `signal` row's own `contactsSignals` column rather than
    /// merged into the collected ones. `ContactsCollector` reads it back on the next collection
    /// pass, so re-syncing replaces what the address book says (a removed nickname really goes)
    /// without touching what the chats and mail found.
    @discardableResult
    public static func sync(_ contacts: [ImportedContact], into store: Store) throws -> Int {
        let (people, channels) = toRecords(contacts)
        try store.upsertPeople(people, channels: channels)

        // `upsertPeople` keeps the id an already-synced person was stored under, so the signals
        // go to that id rather than to the one just generated for this pass.
        var idByIdentifier: [String: String] = [:]
        for person in try store.allPeople() {
            if let identifier = person.cnIdentifier { idByIdentifier[identifier] = person.id }
        }

        // Keyed by identifier rather than by position: `toRecords` filters the same way this
        // does, but a pairing that depends on two filters agreeing is one edit away from
        // attributing one person's note to another.
        let contactsByIdentifier = Dictionary(contacts.map { ($0.identifier, $0) }, uniquingKeysWith: { _, last in last })

        var extras: [(personId: String, signals: LocalSignals)] = []
        for person in people {
            guard let identifier = person.cnIdentifier, let contact = contactsByIdentifier[identifier] else { continue }
            let personId = idByIdentifier[identifier] ?? person.id
            guard let contribution = signals(from: contact, personId: personId, knownAs: person.displayName)
            else { continue }
            extras.append((personId: personId, signals: contribution))
        }
        try store.upsertContactsSignalsBatch(extras)
        return people.count
    }

    /// What Contacts alone knows about a person (spec §3): the nickname as another name they go
    /// by, the honorifics/aliases/links the user's own note mentions, and the city and country
    /// of their address. `nil` when the contact holds none of it.
    static func signals(from contact: ImportedContact, personId: String, knownAs name: String) -> LocalSignals? {
        var aliases: [String] = []
        var strongAliases: [String] = []
        var honorifics: [String] = []
        var honorificsAsWritten: [String] = []
        var links: [String] = []

        // A nickname that is only the person's name again says nothing new — the same gate the
        // WhatsApp push name and the mail `From` name are held to.
        if let nickname = contact.nickname,
           NameMatcher.similarity(personName: name, candidateName: nickname) < SignalRules.aliasNameGate {
            aliases.append(nickname)
            // Someone typed this name for this person by hand; that is as strong as a push name.
            strongAliases.append(nickname)
        }

        if let note = contact.note {
            let names = [name, contact.givenName, contact.familyName].filter { !$0.isEmpty }
            let found = SignalRules.honorificsFound(in: note, names: names)
            honorifics = found.map(\.canonical)
            honorificsAsWritten = found.map(\.asWritten)
            // The alias rule keeps its usual "at least three mentions" bar. A note is short and
            // its first word is usually capitalised ("Met at the clinic…"), so a lower bar turns
            // ordinary prose into names the person supposedly goes by; the nickname field above
            // is where a note-length text can name someone, and spec §4.2 lists the alias
            // sources as nickname, push name, mail `From` name, and group chats.
            for alias in SignalRules.aliases(in: note, names: names) where !aliases.contains(alias) {
                aliases.append(alias)
            }
            links = SignalRules.links(in: note)
        }

        let place = [contact.postalCity, contact.postalCountry]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: ", ")

        let signals = LocalSignals(
            personId: personId,
            aliases: aliases,
            strongAliases: strongAliases,
            honorifics: honorifics,
            honorificsAsWritten: honorificsAsWritten,
            links: links,
            location: place.isEmpty ? nil : place,
            sources: ["contacts"]
        )
        return signals.isEmpty ? nil : signals
    }
}
