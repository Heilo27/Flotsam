#if DEBUG
import Foundation
import os

/// `SecureKeyStore` that keeps the key in memory, so an isolated launch makes no Keychain call (TASK-519). Debug
/// builds only; the key is gone when the process exits, so secure items sealed in a run cannot be opened by the next.
public final class InMemorySecureKeyStore: SecureKeyStore {
    private let stored = OSAllocatedUnfairLock<Data?>(initialState: nil)

    public init() {}

    public func readKey() -> FlotsamResult<Data?> { .success(stored.withLock { $0 }) }

    public func storeKeyIfAbsent(_ key: Data) -> FlotsamResult<Data> {
        .success(stored.withLock { current in
            if let winner = current { return winner }
            current = key
            return key
        })
    }
}

/// `UserAuthenticator` that answers from a script instead of asking the owner (TASK-519): `allow` confirms every
/// time, `deny` is `LIB-OS-002` every time. Debug builds only.
public struct ScriptedAuthenticator: UserAuthenticator {
    public let script: LaunchIsolation.AuthScript

    public init(script: LaunchIsolation.AuthScript) { self.script = script }

    public func authenticate(reason: String) async -> FlotsamResult<Void> {
        switch script {
        case .allow: return .success(())
        case .deny: return .failure(FlotsamError(.libOs002, "The scripted authenticator denied a secure item"))
        }
    }
}
#endif
