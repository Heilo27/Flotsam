import FlotsamBase
import Foundation

/// What the app reaches on the real machine, resolved once at launch (TASK-519): the data folder, the settings store
/// and the secure-item key store and authenticator. The composition root takes all four from here and never spells the
/// Application Support folder, the standard defaults domain, the Keychain or LocalAuthentication itself, so a Debug
/// launch with the isolation variables (docs/AGENT-LAUNCH.md) cannot reach the user's real data. Without the
/// variables, and always in a Release build, every value is the real one.
struct AppEnvironment {
    let dataFolder: URL
    let settingsStore: any KeyValueStore
    let secureKeys: any SecureKeyStore
    let authenticator: any UserAuthenticator

    /// Resolves this process's environment. An isolation variable that cannot be honoured stops the launch with the
    /// reason on stderr: falling back to the real data would defeat the isolation it asked for.
    static func launch() -> AppEnvironment {
        switch LaunchIsolation.fromProcess() {
        case .success(let isolation):
            switch make(isolation) {
            case .success(let environment): return environment
            case .failure(let error): refuse(error)
            }
        case .failure(let error):
            refuse(error)
        }
    }

    static func make(_ isolation: LaunchIsolation) -> FlotsamResult<AppEnvironment> {
        guard let store = isolation.settingsStore() else {
            return .failure(FlotsamError(.sysInt001, "the defaults suite is not usable"))
        }
        let secure = isolation.secureServices { (KeychainSecureKeyStore(), LocalAuthenticator()) }
        return .success(AppEnvironment(
            dataFolder: isolation.dataFolder, settingsStore: store, secureKeys: secure.keys, authenticator: secure.authenticator))
    }

    private static func refuse(_ error: FlotsamError) -> Never {
        FileHandle.standardError.write(Data("Flotsam: \(error.internalMessage); not launching.\n".utf8))
        exit(64)
    }
}
