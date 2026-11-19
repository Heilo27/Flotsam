import Foundation
import Security

/// The secure-clip master key as one generic-password item in the user's Keychain. Not synchronizable and
/// `WhenUnlockedThisDeviceOnly`: it never leaves this Mac and is readable only while the Mac is unlocked (ADR-0011).
/// The app is not sandboxed, so this is the login Keychain; no access group or entitlement is involved.
///
/// Not unit tested: it talks to the real Keychain. `KeychainSecureKeyStore` holds the logic and is tested against a fake.
struct SystemKeychainKeyItem: KeychainKeyItem {
    private static let service = "com.flotsam.secure-clip"
    private static let account = "master-key"

    /// What identifies the item: lookup and add use the same attributes, so they cannot address different items.
    private static var identity: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrSynchronizable as String: kCFBooleanFalse as Any,
        ]
    }

    func copyKey() -> (status: OSStatus, data: Data?) {
        var query = Self.identity
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        return (status, status == errSecSuccess ? result as? Data : nil)
    }

    func addKey(_ key: Data) -> OSStatus {
        var attributes = Self.identity
        attributes[kSecValueData as String] = key
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        return SecItemAdd(attributes as CFDictionary, nil)
    }
}
