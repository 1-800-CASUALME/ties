import Foundation
import Contacts
import CryptoKit

public enum VCardImporter {
    /// Parses one or more vCards from `data`. vCards don't carry a stable Contacts identifier,
    /// so each contact's `identifier` is a content hash of its name/organization, first email,
    /// and first phone number instead. Re-parsing the same vCard therefore produces the same
    /// identifier every time, so `ContactSync.sync` (via `Store.upsertPeople`, which matches
    /// existing rows by this identifier) updates the previously-synced person instead of
    /// creating a duplicate.
    public static func parse(_ data: Data) throws -> [ImportedContact] {
        let contacts = try CNContactVCardSerialization.contacts(with: data)
        return contacts.map { contact in
            var imported = ImportedContact(cnContact: contact, identifier: "")
            imported.identifier = "vcf:" + contentHash(for: imported)
            return imported
        }
    }

    /// Hex SHA-256 of `normalizedFullName|firstEmail|firstPhoneDigits`:
    /// - `normalizedFullName` is `"\(given) \(family)"`, trimmed and lowercased, falling back
    ///   to the lowercased organization when that's blank (i.e. both names are blank).
    /// - `firstEmail` is the first email's value, lowercased, or "" when there is none.
    /// - `firstPhoneDigits` is `PhoneNormalizer.digits(...)` of the first phone's value, or ""
    ///   when there is none.
    private static func contentHash(for contact: ImportedContact) -> String {
        let joinedName = "\(contact.givenName) \(contact.familyName)".trimmingCharacters(in: .whitespaces)
        let normalizedFullName = joinedName.isEmpty
            ? (contact.organization ?? "").lowercased()
            : joinedName.lowercased()
        let firstEmail = (contact.emails.first?.value ?? "").lowercased()
        let firstPhoneDigits = contact.phones.first.map { PhoneNormalizer.digits($0.value) } ?? ""

        let seed = "\(normalizedFullName)|\(firstEmail)|\(firstPhoneDigits)"
        let digest = SHA256.hash(data: Data(seed.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}
