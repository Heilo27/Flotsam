import CryptoKit
import Foundation
import Testing
import FlotsamBase
@testable import FlotsamPayload

// TASK-498 step 2, FRD-001 FR-001-25 (AC-001-25: the text is kept encrypted and nothing guessable is stored; AC-001-27:
// a key that is missing or unreadable is reported and never silently replaced). The vault is the real SecureClipVault;
// only the Keychain behind it is a fake. Expected values are literals; each test names the line it guards so a
// mutation (break it, see red, restore) has a target; the proofs are recorded on the ticket.

/// An in-memory Keychain. `storeCalls` and `key` let a test see whether the vault wrote.
private final class FakeKeyStore: SecureKeyStore, @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Data?
    private var unreadable: Bool
    private var calls = 0

    init(key: Data? = nil, unreadable: Bool = false) {
        stored = key
        self.unreadable = unreadable
    }

    var key: Data? { lock.withLock { stored } }
    var storeCalls: Int { lock.withLock { calls } }

    func readKey() -> FlotsamResult<Data?> {
        lock.withLock { unreadable ? .failure(FlotsamError(.libDat002, "keychain locked")) : .success(stored) }
    }

    func storeKeyIfAbsent(_ key: Data) -> FlotsamResult<Data> {
        lock.withLock {
            calls += 1
            if stored == nil { stored = key }
            return .success(stored!)
        }
    }
}

private let thirtyTwoBytes = Data((0..<32).map { UInt8($0) })
private let otherThirtyTwoBytes = Data((0..<32).map { UInt8(255 - $0) })

private func seal(_ vault: SecureClipVault, _ text: String) throws -> SealedSecret { try vault.seal(text).get() }

private func code<T>(_ result: FlotsamResult<T>) -> ErrorCode? {
    if case .failure(let error) = result { return error.code }
    return nil
}

/// AES-GCM combined form is a 12-byte nonce, the padded text, and a 16-byte tag.
private func combinedLength(paddedBytes: Int) -> Int { 12 + paddedBytes + 16 }

@Suite struct SecureClipVaultCipherTests {
    /// Guards `seal` and `open` being inverses, including text that is not ASCII.
    @Test("AC-001-25: sealed text opens to the same text, for ASCII, multi-byte and long input")
    func roundTrip() throws {
        let vault = SecureClipVault(store: FakeKeyStore())
        let texts = ["correct horse battery staple", "p\u{E4}ssw\u{F6}rd \u{1F511} \u{65E5}\u{672C}", "x", String(repeating: "ab", count: 5_000)]

        for text in texts {
            let sealed = try seal(vault, text)
            #expect(try vault.open(sealed.ciphertext).get() == text)
        }
    }

    /// Guards the stored bytes carrying no readable copy of the text (a plain-text "encryption" would pass the round trip).
    @Test("AC-001-25: the ciphertext does not contain the text, and the fingerprint does not either")
    func ciphertextHidesTheText() throws {
        let vault = SecureClipVault(store: FakeKeyStore())
        let text = "SECRET-MARKER-498-hunter2"

        let sealed = try seal(vault, text)

        #expect(sealed.ciphertext.range(of: Data(text.utf8)) == nil)
        #expect(sealed.ciphertext.range(of: Data("hunter2".utf8)) == nil)
        #expect(sealed.fingerprint.contains("hunter2") == false)
    }

    /// Guards the fresh random nonce per seal (the same password must not produce the same bytes twice) and the
    /// deterministic fingerprint (the same password must bump one row, FR-001-15).
    @Test("AC-001-25: the same text seals to different bytes but the same fingerprint; different text, a different one")
    func nonceAndFingerprint() throws {
        let vault = SecureClipVault(store: FakeKeyStore())

        let first = try seal(vault, "hunter2")
        let second = try seal(vault, "hunter2")
        let other = try seal(vault, "hunter3")

        #expect(first.ciphertext != second.ciphertext)
        #expect(first.fingerprint == second.fingerprint)
        #expect(first.fingerprint != other.fingerprint)
        #expect(first.fingerprint.count == 64)
        #expect(first.fingerprint.allSatisfy { "0123456789abcdef".contains($0) })
    }

    /// Guards the fingerprint being keyed: a bare SHA-256 of the text is guessable offline from the database alone.
    @Test("AC-001-25: the fingerprint is not the plain SHA-256 of the text, and differs under another key")
    func fingerprintIsKeyed() throws {
        let text = "hunter2"
        let plainHash = SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()

        let underA = try seal(SecureClipVault(store: FakeKeyStore(key: thirtyTwoBytes)), text).fingerprint
        let underB = try seal(SecureClipVault(store: FakeKeyStore(key: otherThirtyTwoBytes)), text).fingerprint

        #expect(plainHash == "f52fbd32b2b3b86ff88ef6c490628285f482af15ddcb29541f94bcf526a3f6c7")
        #expect(underA != plainHash)
        #expect(underA != underB)
    }
}

@Suite struct SecureClipVaultPaddingTests {
    /// Guards the padding bucket: the stored length shows a 64-byte bucket, never the length of the password.
    /// 4 bytes of length prefix plus the text rounds up to the next multiple of 64.
    @Test("AC-001-25: texts of 1 to 60 bytes seal to the same length; 61 bytes moves to the next bucket")
    func paddingBuckets() throws {
        let vault = SecureClipVault(store: FakeKeyStore())
        func length(_ count: Int) throws -> Int { try seal(vault, String(repeating: "a", count: count)).ciphertext.count }

        #expect(try length(1) == combinedLength(paddedBytes: 64))
        #expect(try length(8) == 92)
        #expect(try length(60) == 92)
        #expect(try length(61) == 156)
        #expect(try length(124) == 156)
        #expect(try length(125) == 220)
    }

    /// Guards the layout of `pad`: a 4-byte big-endian length, the bytes, zeros to a multiple of 64.
    @Test("AC-001-25: pad writes a big-endian length, the bytes, then zeros to a multiple of 64")
    func padLayout() {
        let padded = SecureClipVault.pad(Data("abc".utf8))

        #expect(padded.count == 64)
        #expect(Array(padded.prefix(7)) == [0, 0, 0, 3, 0x61, 0x62, 0x63])
        #expect(padded.dropFirst(7).allSatisfy { $0 == 0 })
        #expect(SecureClipVault.pad(Data()).count == 64)
        #expect(Array(SecureClipVault.pad(Data(repeating: 0x41, count: 300)).prefix(4)) == [0, 0, 1, 44])
        #expect(SecureClipVault.pad(Data(repeating: 0x41, count: 300)).count == 320)
    }

    /// Guards `unpad` refusing a length prefix that runs past the data, and data too short to hold a prefix.
    @Test("AC-001-25: unpad returns nil for a length that overruns the data or for data shorter than the prefix")
    func unpadRejectsMalformed() {
        #expect(SecureClipVault.unpad(Data([0, 0, 0, 200, 1, 2, 3])) == nil)
        #expect(SecureClipVault.unpad(Data([0, 0, 1])) == nil)
        #expect(SecureClipVault.unpad(Data([0, 0, 0, 2, 0x68, 0x69, 0, 0])) == "hi")
        #expect(SecureClipVault.unpad(Data([0, 0, 0, 0])) == "")
    }
}

@Suite struct SecureClipVaultFailureTests {
    private func flipped(_ data: Data, at index: Int) -> Data {
        var copy = data
        copy[copy.startIndex + index] ^= 0x01
        return copy
    }

    /// Guards the authentication tag: a ciphertext altered anywhere is refused, never decrypted to something else.
    @Test("AC-001-25: a ciphertext altered in the nonce, the body or the tag does not open (LIB-DAT-002)")
    func tamperedCiphertextIsRefused() throws {
        let vault = SecureClipVault(store: FakeKeyStore())
        let sealed = try seal(vault, "hunter2").ciphertext

        #expect(code(vault.open(flipped(sealed, at: 0))) == .libDat002)
        #expect(code(vault.open(flipped(sealed, at: 20))) == .libDat002)
        #expect(code(vault.open(flipped(sealed, at: sealed.count - 1))) == .libDat002)
        #expect(code(vault.open(sealed.dropLast())) == .libDat002)
        #expect(code(vault.open(Data())) == .libDat002)
        #expect(try vault.open(sealed).get() == "hunter2")
    }

    /// Guards the associated data. The key is derived here the way the vault documents it (HKDF-SHA256 of the master key,
    /// info "flotsam.secure-clip.encryption.v1"); the control seal proves that derivation is right, so the refusal of
    /// the other seal is down to the associated data alone.
    @Test("AC-001-25: a ciphertext sealed under the right key but another associated data does not open")
    func associatedDataIsBound() throws {
        let vault = SecureClipVault(store: FakeKeyStore(key: thirtyTwoBytes))
        let derived = HKDF<SHA256>.deriveKey(
            inputKeyMaterial: SymmetricKey(data: thirtyTwoBytes), info: Data("flotsam.secure-clip.encryption.v1".utf8),
            outputByteCount: 32)
        let padded = SecureClipVault.pad(Data("hunter2".utf8))

        let control = try AES.GCM.seal(padded, using: derived, authenticating: Data("flotsam.secure-clip.v1".utf8)).combined!
        let foreign = try AES.GCM.seal(padded, using: derived, authenticating: Data("another.feature.v1".utf8)).combined!
        let none = try AES.GCM.seal(padded, using: derived).combined!

        #expect(try vault.open(control).get() == "hunter2")
        #expect(code(vault.open(foreign)) == .libDat002)
        #expect(code(vault.open(none)) == .libDat002)
    }

    /// Guards the key actually being used: a ciphertext sealed under one key does not open under another.
    @Test("AC-001-25: a ciphertext does not open under a different key (LIB-DAT-002)")
    func wrongKeyIsRefused() throws {
        let sealed = try seal(SecureClipVault(store: FakeKeyStore(key: thirtyTwoBytes)), "hunter2").ciphertext
        let other = SecureClipVault(store: FakeKeyStore(key: otherThirtyTwoBytes))

        #expect(code(other.open(sealed)) == .libDat002)
        #expect(try SecureClipVault(store: FakeKeyStore(key: thirtyTwoBytes)).open(sealed).get() == "hunter2")
    }

    /// Guards `obtainKey(creating: false)`: opening never makes a key. A fresh key could not open anything stored
    /// under the old one and would hide that the old one is gone.
    @Test("AC-001-27: opening with no key fails with LIB-DAT-002 and does not create one")
    func openNeverCreatesAKey() throws {
        let sealed = try seal(SecureClipVault(store: FakeKeyStore()), "hunter2").ciphertext
        let empty = FakeKeyStore()
        let vault = SecureClipVault(store: empty)

        #expect(code(vault.open(sealed)) == .libDat002)
        #expect(empty.key == nil)
        #expect(empty.storeCalls == 0)
        #expect(vault.isKeyAvailable == false)
    }

    /// Guards first-use creation: the first seal creates the key (32 bytes), later seals reuse it.
    @Test("AC-001-25: the first seal creates a 32-byte key once; later seals reuse it")
    func firstSealCreatesTheKey() throws {
        let store = FakeKeyStore()
        let vault = SecureClipVault(store: store)
        #expect(vault.isKeyAvailable == false)

        _ = try seal(vault, "one")
        _ = try seal(vault, "two")

        #expect(store.key?.count == 32)
        #expect(store.storeCalls == 1)
        #expect(vault.isKeyAvailable)
    }

    /// Guards "a key that exists but cannot be read is never replaced": replacing it would orphan every stored secure item.
    @Test("AC-001-27: a Keychain that cannot be read fails the seal and the open, and nothing is written")
    func unreadableKeyIsNeverReplaced() throws {
        let store = FakeKeyStore(key: thirtyTwoBytes, unreadable: true)
        let vault = SecureClipVault(store: store)

        #expect(code(vault.seal("hunter2")) == .libDat002)
        #expect(code(vault.open(Data(repeating: 0, count: 60))) == .libDat002)
        #expect(vault.isKeyAvailable == false)
        #expect(store.storeCalls == 0)
        #expect(store.key == thirtyTwoBytes)
    }

    /// Guards the key length check: a stored value of the wrong size is not a key.
    @Test("AC-001-27: a stored key of the wrong length is unavailable, and sealing with it fails")
    func wrongLengthKeyIsNotAKey() {
        let store = FakeKeyStore(key: Data(repeating: 7, count: 16))
        let vault = SecureClipVault(store: store)

        #expect(vault.isKeyAvailable == false)
        #expect(code(vault.seal("hunter2")) == .libDat002)
        #expect(store.storeCalls == 0)
    }
}
