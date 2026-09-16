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

    /// Every key the app reads except the note, which is asked for separately. Built per call
    /// rather than held in a `static let`, because `CNKeyDescriptor` is not `Sendable`.
    private var keys: [CNKeyDescriptor] { [
        CNContactGivenNameKey as CNKeyDescriptor,
        CNContactFamilyNameKey as CNKeyDescriptor,
        CNContactOrganizationNameKey as CNKeyDescriptor,
        CNContactJobTitleKey as CNKeyDescriptor,
        CNContactNicknameKey as CNKeyDescriptor,
        CNContactPhoneNumbersKey as CNKeyDescriptor,
        CNContactEmailAddressesKey as CNKeyDescriptor,
        CNContactUrlAddressesKey as CNKeyDescriptor,
        CNContactPostalAddressesKey as CNKeyDescriptor,
        CNContactThumbnailImageDataKey as CNKeyDescriptor,
    ] }

    /// Fetches every contact, skipping ones with no name and no organization.
    ///
    /// The note is asked for first and dropped if Contacts refuses. Reading notes needs
    /// `com.apple.developer.contacts.notes`, which Apple grants by request and which an unsigned
    /// or locally-signed build cannot hold at all; Contacts then rejects the *whole* fetch
    /// (`CNErrorDomain` / `CNErrorCodeUnauthorizedKeys`, 102), so without the retry a developer
    /// build would import no contacts whatsoever. The retry is keyed on the failure rather than
    /// on that code, so a refusal for some other reason still costs only the notes.
    public func fetchAll() throws -> [ImportedContact] {
        do {
            return try fetch(keys: keys + [CNContactNoteKey as CNKeyDescriptor])
        } catch {
            return try fetch(keys: keys)
        }
    }

    private func fetch(keys: [CNKeyDescriptor]) throws -> [ImportedContact] {
        let request = CNContactFetchRequest(keysToFetch: keys)
        request.sortOrder = .givenName

        var results: [ImportedContact] = []
        try store.enumerateContacts(with: request) { contact, _ in
            let imported = ImportedContact(cnContact: contact, identifier: contact.identifier)
            guard !imported.hasNoNameOrOrg else {
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
