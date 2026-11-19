import FlotsamBase
import Foundation
import Security

/// The two Keychain operations the key store needs, kept narrow so the decisions about their results (the part that
/// can go wrong) are testable without a Keychain. The real one is `SystemKeychainKeyItem`.
protocol KeychainKeyItem: Sendable {
    /// Looks the key item up. `data` is only meaningful when `status` is `errSecSuccess`.
    func copyKey() -> (status: OSStatus, data: Data?)
    /// Adds the key item. Never replaces an existing one.
    func addKey(_ key: Data) -> OSStatus
}

/// `SecureKeyStore` over one generic-password Keychain item (ADR-0011): the master key of secure clips. The item
/// attributes (this device only, no iCloud sync) are in `SystemKeychainKeyItem`; what this type owns is how each result
/// is read, because a wrong reading either loses every stored secret or leaks the key:
/// - Only `errSecItemNotFound` means "no key yet". Every other failure (locked Keychain, denied access, damaged
///   item) is a failure, and the caller must not create a key on top of it: a new key could not open anything sealed
///   under the old one.
/// - `errSecDuplicateItem` on add means another writer got there first. The stored key is the winner's, so it is read
///   back and returned; the key this caller generated is dropped.
/// - Nothing here logs or reports key bytes. A failure carries the `OSStatus`, which is not secret.
final class KeychainSecureKeyStore: SecureKeyStore {
    private let item: any KeychainKeyItem

    init(item: any KeychainKeyItem = SystemKeychainKeyItem()) { self.item = item }

    func readKey() -> FlotsamResult<Data?> {
        let found = item.copyKey()
        switch found.status {
        case errSecSuccess:
            guard let data = found.data else {
                return .failure(Self.failure("Keychain returned no key data", status: found.status))
            }
            return .success(data)
        case errSecItemNotFound:
            return .success(nil)
        default:
            return .failure(Self.failure("Keychain key could not be read", status: found.status))
        }
    }

    func storeKeyIfAbsent(_ key: Data) -> FlotsamResult<Data> {
        let status = item.addKey(key)
        switch status {
        case errSecSuccess:
            return .success(key)
        case errSecDuplicateItem:
            switch readKey() {
            case .success(let winner?): return .success(winner)
            // Added by someone, gone before the read: the key this caller generated is not stored either.
            case .success(nil): return .failure(Self.failure("Keychain key disappeared after a duplicate", status: status))
            case .failure(let error): return .failure(error)
            }
        default:
            return .failure(Self.failure("Keychain key could not be stored", status: status))
        }
    }

    private static func failure(_ message: StaticString, status: OSStatus) -> FlotsamError {
        FlotsamError(.libDat002, message, underlying: UnderlyingErrorInfo(domain: NSOSStatusErrorDomain, code: Int(status)))
    }
}
