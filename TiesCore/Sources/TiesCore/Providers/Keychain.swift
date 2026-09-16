import Foundation
import Security

/// A Keychain operation failed; carries the underlying `OSStatus` for diagnostics.
public enum KeychainError: Error, Sendable {
    case unhandled(OSStatus)
}

/// Thin wrapper over the macOS login Keychain for storing provider API keys as generic
/// passwords under a single service name, with `account` (typically a provider id)
/// distinguishing entries. Items are readable once the user has unlocked the device since
/// boot, but aren't tied to biometrics or the device passcode.
public enum Keychain {
    private static let service = "Ties"

    /// Stores `value` under `account`, replacing any existing entry.
    public static func set(_ value: String, account: String) throws {
        delete(account: account)
        var query = baseQuery(account: account)
        query[kSecValueData as String] = Data(value.utf8)
        query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else { throw KeychainError.unhandled(status) }
    }

    /// Returns the stored value for `account`, or `nil` if there is none.
    public static func get(account: String) -> String? {
        var query = baseQuery(account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    /// Removes the entry for `account`, if any. Not an error if there was nothing to remove.
    public static func delete(account: String) {
        SecItemDelete(baseQuery(account: account) as CFDictionary)
    }

    /// Removes every entry Ties has stored, whatever the account. Used by "Delete Everything".
    public static func deleteAll() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
        ]
        SecItemDelete(query as CFDictionary)
    }

    private static func baseQuery(account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }
}
