import Foundation

/// The one home for test-only `UserDefaults` suites (TASK-520). A named suite writes `~/Library/Preferences/<name>.plist`,
/// and `removePersistentDomain` empties the domain but leaves that file behind, so ~17,000 of them piled up. Every test
/// that needs a real defaults domain makes it here, never with `UserDefaults(suiteName:)` (`TestDefaultsGuardTests` fails
/// the build on a second call site). Shared into other test targets by symlink, like `SignpostProbe.swift`.
///
/// Use `withTestDefaults("label") { suite in ... }`, or hold a `TestDefaultsSuite` in a rig and call `remove()` (also run
/// by `deinit`, so a test that forgets still cleans up).
///
/// Why there is an exit sweep: `cfprefsd` writes a domain's plist about 0.8 s after the last change, so a file deleted
/// inside the test comes back after it. Measured: 25 of 100 suites re-created their plist after an immediate delete. The
/// process-exit sweep waits for those late writes to land and deletes the files a second time.
final class TestDefaultsSuite: @unchecked Sendable {
    /// Every suite name starts with this, so a leftover plist is recognisably a test artefact.
    static let namePrefix = "flotsam.test."

    let name: String
    private let lock = NSLock()
    private var removed = false

    init(_ label: String) {
        name = "\(Self.namePrefix)\(label).\(UUID().uuidString)"
        TestDefaultsExitSweep.shared.track(name)
    }

    /// A handle on the suite. Each call is a fresh `UserDefaults` over the same domain, which is what a relaunch sees.
    var defaults: UserDefaults {
        guard let made = UserDefaults(suiteName: name) else { preconditionFailure("UserDefaults refused suite \(name)") }
        return made
    }

    /// The preferences file the suite writes.
    var plistURL: URL { Self.plistURL(forSuite: name) }

    /// Empties the domain and deletes its plist. Safe to call again.
    func remove() {
        let first = lock.withLock { () -> Bool in
            defer { removed = true }
            return !removed
        }
        guard first else { return }
        UserDefaults(suiteName: name)?.removePersistentDomain(forName: name)
        // A plain delete: the file may already be gone, which is the goal.
        try? FileManager.default.removeItem(at: plistURL)
        TestDefaultsExitSweep.shared.touch()
    }

    deinit { remove() }

    static func plistURL(forSuite name: String) -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Preferences/\(name).plist")
    }
}

/// Runs `body` over a unique suite and removes the suite (domain and plist) afterwards, thrown error or not.
func withTestDefaults<T>(_ label: String, _ body: (TestDefaultsSuite) throws -> T) rethrows -> T {
    let suite = TestDefaultsSuite(label)
    defer { suite.remove() }
    return try body(suite)
}

/// Async form of `withTestDefaults`.
func withTestDefaults<T>(_ label: String, _ body: (TestDefaultsSuite) async throws -> T) async rethrows -> T {
    let suite = TestDefaultsSuite(label)
    defer { suite.remove() }
    return try await body(suite)
}

/// Deletes, at process exit, the plist of every suite this process made, after `cfprefsd`'s late writes have landed.
final class TestDefaultsExitSweep: @unchecked Sendable {
    static let shared = TestDefaultsExitSweep()

    /// Longer than the observed ~0.95 s write delay, with margin for a loaded machine. Tests pass a shorter one.
    private let settleSeconds: Double

    init(settleSeconds: Double = 2.0) { self.settleSeconds = settleSeconds }

    private let lock = NSLock()
    private var names: [String] = []
    private var lastActivity = Date.distantPast
    private var installed = false

    func track(_ name: String) {
        let install = lock.withLock { () -> Bool in
            names.append(name)
            lastActivity = Date()
            defer { installed = true }
            return !installed
        }
        // Only the shared sweep owns the process-exit hook; a test's own instance is swept by calling `sweep()`.
        if install && self === Self.shared { atexit { TestDefaultsExitSweep.shared.sweep() } }
    }

    func touch() { lock.withLock { lastActivity = Date() } }

    /// Waits out the settle window since the last activity, then deletes the plist of every name tracked here, and only those.
    func sweep() {
        let (pending, last) = lock.withLock { (names, lastActivity) }
        guard !pending.isEmpty else { return }
        let remaining = settleSeconds - Date().timeIntervalSince(last)
        if remaining > 0 { Thread.sleep(forTimeInterval: remaining) }
        for name in pending { try? FileManager.default.removeItem(at: TestDefaultsSuite.plistURL(forSuite: name)) }
    }
}
