import Foundation

/// Secure clips (FRD-001 FR-001-04 gate 3, FRD-007 secure items): what a password manager copies with
/// `org.nspasteboard.ConcealedType`. The text is kept encrypted, shown as a fixed mask, and only handed back after the
/// device owner confirms. This file is the one home of the mask and of the ports the feature needs, so Capture,
/// Storage, Library, Shelf and Paste cannot disagree about any of them.
public enum SecureClip {
    /// What a secure item shows instead of its text, in the Library, in search results and on the Shelf. A fixed
    /// length on purpose: the length of a password must not be readable off the row.
    public static let mask = "\u{2022}\u{2022}\u{2022}\u{2022}\u{2022}\u{2022}\u{2022}\u{2022}"

    /// The prefix of a secure item's `contentKey`. Never a bare hash of the text: see `SecureClipVaulting`.
    public static let contentKeyPrefix = "secure:"
}

/// The Keychain, as the vault needs it (ADR-0011). One 32-byte key, this device only, never in the database, the logs
/// or the repository. The real adapter lives in the app target; tests use a fake.
public protocol SecureKeyStore: Sendable {
    /// The stored key. `.success(nil)` means no key has been stored yet; a failure means the Keychain could not be
    /// read. The two differ: a missing key may be created, an unreadable one must never be replaced, or every secure
    /// item already stored would become unrecoverable.
    func readKey() -> FlotsamResult<Data?>
    /// Stores `key` when none exists. Returns the key that is stored afterwards: the argument, or the winner's when
    /// another writer got there first.
    func storeKeyIfAbsent(_ key: Data) -> FlotsamResult<Data>
}

/// Encrypts and decrypts secure text with the Keychain key. The real vault is in Payload (CryptoKit); Paste and Shelf
/// see only this protocol, so they stay free of CryptoKit.
public protocol SecureClipVaulting: Sendable {
    /// Seals `text` for storage. Creates the key on first use. Fails closed: when no key can be had, the text is not
    /// stored at all.
    func seal(_ text: String) -> FlotsamResult<SealedSecret>
    /// Decrypts a stored ciphertext. `LIB-DAT-002` when the key is missing or unreadable or the bytes do not open.
    /// No authentication here: callers outside tests go through `SecureClipAccess`.
    func open(_ ciphertext: Data) -> FlotsamResult<String>
    /// Whether the key can be read right now. A secure row whose key is gone shows as unavailable.
    var isKeyAvailable: Bool { get }
}

/// What `seal` hands to storage.
public struct SealedSecret: Sendable, Equatable {
    /// AES-GCM combined form (nonce, ciphertext, tag) of the padded text.
    public let ciphertext: Data
    /// Keyed fingerprint of the text (HMAC, key derived from the vault key), so a repeated copy of the same password
    /// bumps one row (FR-001-15) without the database holding anything guessable offline.
    public let fingerprint: String

    public init(ciphertext: Data, fingerprint: String) {
        self.ciphertext = ciphertext
        self.fingerprint = fingerprint
    }
}

/// The device-owner check (`.deviceOwnerAuthentication`: Touch ID, Apple Watch or the account password). The real
/// adapter is `LocalAuthentication` in the app target.
public protocol UserAuthenticator: Sendable {
    /// `reason` completes "Flotsam is trying to ...". Success means the owner confirmed; cancel and failure are both
    /// `LIB-OS-002` (the caller does nothing else with the difference).
    func authenticate(reason: String) async -> FlotsamResult<Void>
}

/// Authenticate, then decrypt: the only path from a stored secure item to its text (FR-003-15, FR-006-05). Every
/// caller (Return, copy, paste-back, Shelf drag-out) asks here, so "every time" is one rule in one place and a new
/// caller cannot forget the check.
public struct SecureClipAccess: Sendable {
    private let vault: any SecureClipVaulting
    private let authenticator: any UserAuthenticator

    public init(vault: any SecureClipVaulting, authenticator: any UserAuthenticator) {
        self.vault = vault
        self.authenticator = authenticator
    }

    /// Whether secure items can be opened on this Mac at all (the key is readable).
    public var isKeyAvailable: Bool { vault.isKeyAvailable }

    /// The text of a secure item. A missing key is reported (`LIB-DAT-002`) before the owner is asked anything: no
    /// prompt for something that cannot succeed. A cancelled or failed check is `LIB-OS-002`, and nothing is
    /// decrypted.
    public func reveal(ciphertext: Data) async -> FlotsamResult<String> {
        guard vault.isKeyAvailable else {
            return .failure(FlotsamError(.libDat002, "Secure item key unavailable"))
        }
        let reason = FlotsamStrings.text(forKey: "ui.secure.authReason") ?? "copy a secure item"
        if case .failure(let error) = await authenticator.authenticate(reason: reason) { return .failure(error) }
        return vault.open(ciphertext)
    }
}
