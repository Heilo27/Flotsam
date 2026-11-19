import Foundation
import Testing
import FlotsamBase
@testable import FlotsamPayload

// TASK-498 blind QA (Worf), FR-001-25 / AC-001-27: a key that exists but cannot be read is never replaced. The builder's
// fake Keychain fails persistently, which cannot tell "fail closed on the first read" from "fall through to the second
// read, which fails too". These stores fail on ONE scripted read and then answer normally, the shape of a Keychain that
// is briefly locked, so each of the vault's two reads has to fail closed on its own.

/// A Keychain whose reads follow a script (one outcome per call, the last outcome repeats). `storeCalls` counts writes.
private final class ScriptedKeyStore: SecureKeyStore, @unchecked Sendable {
    enum Read { case missing, locked, present(Data) }

    private let lock = NSLock()
    private let script: [Read]
    private var reads = 0
    private var calls = 0
    private var stored: Data?

    init(_ script: [Read]) { self.script = script }

    var storeCalls: Int { lock.withLock { calls } }
    var readCalls: Int { lock.withLock { reads } }

    func readKey() -> FlotsamResult<Data?> {
        lock.withLock {
            let step = script[min(reads, script.count - 1)]
            reads += 1
            switch step {
            case .missing: return .success(nil)
            case .locked: return .failure(FlotsamError(.libDat002, "keychain locked"))
            case .present(let key): return .success(key)
            }
        }
    }

    func storeKeyIfAbsent(_ key: Data) -> FlotsamResult<Data> {
        lock.withLock {
            calls += 1
            if stored == nil { stored = key }
            return .success(stored!)
        }
    }
}

private func code<T>(_ result: FlotsamResult<T>) -> ErrorCode? {
    if case .failure(let error) = result { return error.code }
    return nil
}

@Suite struct Worf498VaultKeyRaceTests {
    /// Red if the first `readKey` failure in `obtainKey` falls through to key creation (a locked Keychain would then get a
    /// brand new key written over the real one, orphaning every secure item).
    @Test("AC-001-27 W498-V1: a first read that fails (locked) makes seal fail with LIB-DAT-002 and writes no key")
    func firstReadFailureFailsClosed() {
        let store = ScriptedKeyStore([.locked, .missing])
        let vault = SecureClipVault(store: store)

        let result = vault.seal("hunter2")

        #expect(code(result) == .libDat002)
        #expect(store.storeCalls == 0)
        #expect(store.readCalls == 1)
    }

    /// Red if the re-read under the creation lock turns a failure into "absent" and creates a key.
    @Test("AC-001-27 W498-V2: a key that is absent, then unreadable on the re-read, makes seal fail and writes no key")
    func secondReadFailureFailsClosed() {
        let store = ScriptedKeyStore([.missing, .locked])
        let vault = SecureClipVault(store: store)

        let result = vault.seal("hunter2")

        #expect(code(result) == .libDat002)
        #expect(store.storeCalls == 0)
        #expect(store.readCalls == 2)
    }

    /// Positive control: with the same script shape but nothing failing, the vault does create exactly one key, so the two
    /// tests above are not green only because creation is impossible.
    @Test("AC-001-25 W498-V3: an absent key that stays absent is created once and the text seals")
    func absentKeyIsCreatedOnce() throws {
        let store = ScriptedKeyStore([.missing])
        let vault = SecureClipVault(store: store)

        let sealed = try vault.seal("hunter2").get()

        #expect(store.storeCalls == 1)
        #expect(sealed.fingerprint.count == 64)
        #expect(sealed.ciphertext.count == 12 + 64 + 16)
    }

    /// Red if another seal's key (appearing between the first read and the lock) is ignored and a second key is stored.
    @Test("AC-001-27 W498-V4: a key that appears between the two reads is used, and none is written")
    func keyCreatedByAnotherSealIsReused() throws {
        let existing = Data((0..<32).map { UInt8($0) })
        let store = ScriptedKeyStore([.missing, .present(existing)])
        let vault = SecureClipVault(store: store)

        _ = try vault.seal("hunter2").get()

        #expect(store.storeCalls == 0)
    }

    /// Red if open() ever creates a key: with the key absent, open fails and writes nothing.
    @Test("AC-001-27 W498-V5: opening with no key fails with LIB-DAT-002 and creates no key")
    func openNeverCreates() {
        let store = ScriptedKeyStore([.missing])
        let vault = SecureClipVault(store: store)

        let result = vault.open(Data(repeating: 7, count: 60))

        #expect(code(result) == .libDat002)
        #expect(store.storeCalls == 0)
    }
}
