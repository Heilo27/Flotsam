import FlotsamBase
import Foundation
@testable import FlotsamTriggers

/// A clock the test advances by hand.
final class ManualClock: WallClock, @unchecked Sendable {
    private let lock = NSLock()
    private var current = Date(timeIntervalSince1970: 1_800_000_000)
    private var _slept: [Duration] = []
    private var _onSleep: (@Sendable (Duration) -> Void)?

    /// Every duration passed to `sleep`, in order.
    var slept: [Duration] { lock.withLock { _slept } }
    /// Runs inside `sleep`, so a test can change the world during a wait (another app copies, the user switches app).
    var onSleep: (@Sendable (Duration) -> Void)? {
        get { lock.withLock { _onSleep } }
        set { lock.withLock { _onSleep = newValue } }
    }

    func now() -> Date { lock.withLock { current } }
    func advance(_ seconds: TimeInterval) { lock.withLock { current = current.addingTimeInterval(seconds) } }
    func sleep(for duration: Duration) async {
        let hook = lock.withLock { () -> (@Sendable (Duration) -> Void)? in
            _slept.append(duration)
            return _onSleep
        }
        advance(TimeInterval(duration.components.seconds))
        hook?(duration)
    }
}

/// Environment answers a test sets, with a count of how often the matcher asked.
final class FakeKeyboardEnvironment: KeyboardEnvironment, @unchecked Sendable {
    private let lock = NSLock()
    private var secure = false
    private var inputMethod = false
    private var app: FrontmostApp? = FrontmostApp(bundleId: "com.example.editor", processId: 100)
    private var asked = 0

    var secureInput: Bool { get { lock.withLock { secure } } set { lock.withLock { secure = newValue } } }
    var inputMethodActive: Bool { get { lock.withLock { inputMethod } } set { lock.withLock { inputMethod = newValue } } }
    var frontmost: FrontmostApp? { get { lock.withLock { app } } set { lock.withLock { app = newValue } } }
    var callCount: Int { lock.withLock { asked } }

    func isSecureEventInputEnabled() -> Bool { lock.withLock { asked += 1; return secure } }
    func isInputMethodActive() -> Bool { lock.withLock { asked += 1; return inputMethod } }
    func frontmostApp() -> FrontmostApp? { lock.withLock { asked += 1; return app } }
}

/// Drives a `TriggerMatcher` the way the tap adapter would, with every collaborator a fake.
final class MatcherHarness {
    static let ownBundleId = "com.example.flotsam"
    let store = TriggerSnapshotStore()
    let environment = FakeKeyboardEnvironment()
    let clock = ManualClock()
    let resetSignal = TriggerResetSignal()
    let matcher: TriggerMatcher

    init(triggers: [UUID: String] = [:], excluded: Set<String> = []) {
        matcher = TriggerMatcher(
            store: store, environment: environment, clock: clock, resetSignal: resetSignal,
            ownBundleId: Self.ownBundleId)
        install(triggers)
        store.setExcludedApps(excluded)
    }

    func install(_ triggers: [UUID: String]) {
        store.replace(TriggerSnapshot(bindings: ItemBindings(triggers: triggers)), token: store.beginRebuild())
    }

    /// Letters, digits and punctuation: key code 0 stands for "a key that is not special".
    @discardableResult
    func type(_ text: String, flags: KeyEventFlags = []) -> [MatcherResult] {
        text.map { ch in
            let down = matcher.process(KeyEvent(kind: .keyDown, keyCode: 0, flags: flags, characters: String(ch)))
            _ = matcher.process(KeyEvent(kind: .keyUp, keyCode: 0, flags: flags, characters: String(ch)))
            return down
        }
    }

    func down(_ keyCode: UInt16, _ characters: String = "", flags: KeyEventFlags = [], repeat isRepeat: Bool = false) -> MatcherResult {
        matcher.process(KeyEvent(kind: .keyDown, keyCode: keyCode, flags: flags, characters: characters, isAutoRepeat: isRepeat))
    }

    func up(_ keyCode: UInt16) -> MatcherResult {
        matcher.process(KeyEvent(kind: .keyUp, keyCode: keyCode))
    }

    func space(flags: KeyEventFlags = []) -> MatcherResult { down(TriggerKeys.space, " ", flags: flags) }
}

extension MatcherResult {
    var match: TriggerMatch? { if case .matched(let m) = self { m } else { nil } }
}
