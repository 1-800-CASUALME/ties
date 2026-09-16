import Foundation
import Contacts

public enum VCardImporter {
    /// Parses one or more vCards from `data`. Each resulting contact gets a synthetic
    /// `"vcf:" + UUID` identifier, since vCards don't carry a stable Contacts identifier.
    public static func parse(_ data: Data) throws -> [ImportedContact] {
        let contacts = try CNContactVCardSerialization.contacts(with: data)
        return contacts.map { contact in
            ImportedContact(cnContact: contact, identifier: "vcf:" + UUID().uuidString)
        }
    }
}
