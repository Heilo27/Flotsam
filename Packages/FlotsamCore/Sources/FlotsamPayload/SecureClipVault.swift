import CryptoKit
import FlotsamBase
import Foundation

/// The CryptoKit side of secure clips (`SecureClipVaulting`). AES-GCM with a 256-bit master key held in the Keychain
/// behind `SecureKeyStore`: the key is never in the database, the logs or the repository.
///
/// Three decisions worth knowing before changing anything here:
/// - One master key, two derived keys (HKDF, distinct `info`): one for AES-GCM, one for the HMAC fingerprint. A key
///   used for two purposes is how cross-protocol attacks start; deriving costs nothing.
/// - The text is padded to a multiple of `paddingBlock` bytes before sealing, so the stored length reveals a length
///   bucket, never the exact length of a password. The real length is a 4-byte prefix inside the sealed bytes.
/// - A key that exists but cannot be read is never replaced. Replacing it would make every secure item already stored
///   unrecoverable. Only a key that is definitely absent is created.
public final class SecureClipVault: SecureClipVaulting {
    /// Ciphertext length is rounded up to this many bytes of plaintext (after the 4-byte length prefix).
    static let paddingBlock = 64
    private static let keyLength = 32
    private static let lengthPrefix = 4
    private static let encryptionInfo = Data("flotsam.secure-clip.encryption.v1".utf8)
    private static let fingerprintInfo = Data("flotsam.secure-clip.fingerprint.v1".utf8)
    /// Authenticated, not secret: binds a ciphertext to this feature and format version.
    private static let associatedData = Data("flotsam.secure-clip.v1".utf8)

    private let store: any SecureKeyStore
    /// Serialises first-use key creation, so two simultaneous first copies cannot each generate a different key.
    private let creation = NSLock()

    public init(store: any SecureKeyStore) { self.store = store }

    public var isKeyAvailable: Bool {
        if case .success(let key?) = store.readKey(), key.count == Self.keyLength { return true }
        return false
    }

    public func seal(_ text: String) -> FlotsamResult<SealedSecret> {
        let master: Data
        switch obtainKey(creating: true) {
        case .success(let key): master = key
        case .failure(let error): return .failure(error)
        }
        do {
            let sealed = try AES.GCM.seal(
                Self.pad(Data(text.utf8)), using: Self.derive(master, info: Self.encryptionInfo),
                authenticating: Self.associatedData)
            guard let combined = sealed.combined else {
                return .failure(FlotsamError(.libDat002, "Sealed box has no combined form"))
            }
            let mac = HMAC<SHA256>.authenticationCode(
                for: Data(text.utf8), using: Self.derive(master, info: Self.fingerprintInfo))
            return .success(SealedSecret(ciphertext: combined, fingerprint: Data(mac).hexString))
        } catch {
            return .failure(FlotsamError(.libDat002, "Secure text could not be sealed"))
        }
    }

    public func open(_ ciphertext: Data) -> FlotsamResult<String> {
        let master: Data
        switch obtainKey(creating: false) {
        case .success(let key): master = key
        case .failure(let error): return .failure(error)
        }
        do {
            let box = try AES.GCM.SealedBox(combined: ciphertext)
            let padded = try AES.GCM.open(
                box, using: Self.derive(master, info: Self.encryptionInfo), authenticating: Self.associatedData)
            guard let text = Self.unpad(padded) else {
                return .failure(FlotsamError(.libDat002, "Secure item padding is malformed"))
            }
            return .success(text)
        } catch {
            return .failure(FlotsamError(.libDat002, "Secure item did not open with the stored key"))
        }
    }

    // MARK: Key

    /// The master key. `creating` is true only for sealing; opening never makes a key (a new key could not open
    /// anything stored under the old one, and would hide that the old one is gone).
    private func obtainKey(creating: Bool) -> FlotsamResult<Data> {
        switch store.readKey() {
        case .failure: return .failure(FlotsamError(.libDat002, "Keychain key unreadable"))
        case .success(let key?): return validated(key)
        case .success(nil):
            guard creating else { return .failure(FlotsamError(.libDat002, "Keychain key missing")) }
        }
        creation.lock()
        defer { creation.unlock() }
        // Re-read under the lock: another seal may have created it while this one waited.
        switch store.readKey() {
        case .failure: return .failure(FlotsamError(.libDat002, "Keychain key unreadable"))
        case .success(let key?): return validated(key)
        case .success(nil): break
        }
        let fresh = SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) }
        switch store.storeKeyIfAbsent(fresh) {
        case .success(let stored): return validated(stored)
        case .failure: return .failure(FlotsamError(.libDat002, "Keychain key could not be stored"))
        }
    }

    private func validated(_ key: Data) -> FlotsamResult<Data> {
        key.count == Self.keyLength
            ? .success(key) : .failure(FlotsamError(.libDat002, "Keychain key has the wrong length"))
    }

    private static func derive(_ master: Data, info: Data) -> SymmetricKey {
        HKDF<SHA256>.deriveKey(
            inputKeyMaterial: SymmetricKey(data: master), info: info, outputByteCount: keyLength)
    }

    // MARK: Padding

    /// 4-byte big-endian length, the bytes, then zeros up to a multiple of `paddingBlock`.
    static func pad(_ bytes: Data) -> Data {
        var length = UInt32(truncatingIfNeeded: bytes.count).bigEndian
        var out = Data(bytes: &length, count: lengthPrefix)
        out.append(bytes)
        let remainder = out.count % paddingBlock
        if remainder != 0 { out.append(Data(count: paddingBlock - remainder)) }
        return out
    }

    static func unpad(_ padded: Data) -> String? {
        guard padded.count >= lengthPrefix else { return nil }
        let bytes = [UInt8](padded)
        let length = bytes.prefix(lengthPrefix).reduce(0) { ($0 << 8) | Int($1) }
        guard length <= bytes.count - lengthPrefix else { return nil }
        return String(data: Data(bytes[lengthPrefix..<(lengthPrefix + length)]), encoding: .utf8)
    }
}

private extension Data {
    var hexString: String { map { String(format: "%02x", $0) }.joined() }
}
