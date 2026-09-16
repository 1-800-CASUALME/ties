import Foundation
import Contacts

public enum ContactsAccess: Sendable {
    case notDetermined, denied, authorized
}

/// Wraps `CNContactStore` to check/request access to the user's Apple Contacts and fetch them.
public actor ContactsService {
    private let store = CNContactStore()

    public init() {}

    public func accessStatus() -> ContactsAccess {
        Self.map(CNContactStore.authorizationStatus(for: .contacts))
    }

    public func requestAccess() async -> ContactsAccess {
        do {
            let granted = try await store.requestAccess(for: .contacts)
            return granted ? .authorized : .denied
        } catch {
            return .denied
        }
    }

    /// Fetches every contact, skipping ones with no name and no organization.
    public func fetchAll() throws -> [ImportedContact] {
        let keys: [CNKeyDescriptor] = [
            CNContactGivenNameKey as CNKeyDescriptor,
            CNContactFamilyNameKey as CNKeyDescriptor,
            CNContactOrganizationNameKey as CNKeyDescriptor,
            CNContactJobTitleKey as CNKeyDescriptor,
            CNContactPhoneNumbersKey as CNKeyDescriptor,
            CNContactEmailAddressesKey as CNKeyDescriptor,
            CNContactUrlAddressesKey as CNKeyDescriptor,
            CNContactThumbnailImageDataKey as CNKeyDescriptor,
        ]
        let request = CNContactFetchRequest(keysToFetch: keys)
        request.sortOrder = .givenName

        var results: [ImportedContact] = []
        try store.enumerateContacts(with: request) { contact, _ in
            let imported = ImportedContact(cnContact: contact, identifier: contact.identifier)
            guard !(imported.givenName.isEmpty && imported.familyName.isEmpty && (imported.organization ?? "").isEmpty) else {
                return
            }
            results.append(imported)
        }
        return results
    }

    /// `CNAuthorizationStatus.limited` is marked `unavailable` on macOS in the current SDK (it's
    /// an iOS-only case there), so referencing it directly is a compile error on this platform.
    /// It — along with any other status this SDK doesn't yet expose to us — falls through
    /// `@unknown default`, which we treat as authorized, matching the product decision that
    /// limited access should behave like full access.
    private static func map(_ status: CNAuthorizationStatus) -> ContactsAccess {
        switch status {
        case .notDetermined:
            return .notDetermined
        case .authorized:
            return .authorized
        case .restricted, .denied:
            return .denied
        @unknown default:
            return .authorized
        }
    }
}
