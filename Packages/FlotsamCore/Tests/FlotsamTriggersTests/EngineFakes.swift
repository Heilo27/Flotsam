import FlotsamBase
import Foundation
@testable import FlotsamTriggers

// Fakes for `TriggerEngine` and `TapHealth`: the tap, the settings store, the item bindings and a clock the test
// releases a tick at a time. No live event tap and no real keystroke is ever involved.

/// A `KeyEventSource` with no CGEventTap behind it. It records installs and removals, and lets a test play the tap
/// thread: `send` calls the installed handler, `simulateDisable` calls `onDisabled` the way
/// `tapDisabledByTimeout` would.
final class FakeKeyEventSource: KeyEventSource, @unchecked Sendable {
    private struct State {
        var startCount = 0
        var stopCount = 0
        var reenableCount = 0
        var handler: (@Sendable (KeyEvent) -> KeyDecision)?
        var onDisabled: (@Sendable (TapDisableReason) -> Void)?
        var isInstalled = false
        var isDisabled = false
        var startFailure: FlotsamError?
        var reenableSucceeds = true
    }

    private let state = LockedValue(State())

    var startCount: Int { state.value.startCount }
    var stopCount: Int { state.value.stopCount }
    var reenableCount: Int { state.value.reenableCount }
    var isInstalled: Bool { state.value.isInstalled }
    /// When set, `start` fails with this error and installs nothing.
    var startFailure: FlotsamError? {
        get { state.value.startFailure }
        set { state.withLock { $0.startFailure = newValue } }
    }
    /// When false, `reenable()` fails and the tap stays disabled.
    var reenableSucceeds: Bool {
        get { state.value.reenableSucceeds }
        set { state.withLock { $0.reenableSucceeds = newValue } }
    }

    func start(
        handler: @escaping @Sendable (KeyEvent) -> KeyDecision,
        onDisabled: @escaping @Sendable (TapDisableReason) -> Void
    ) -> FlotsamResult<Void> {
        state.withLock { state in
            state.startCount += 1
            if let failure = state.startFailure { return .failure(failure) }
            state.handler = handler
            state.onDisabled = onDisabled
            state.isInstalled = true
            state.isDisabled = false
            return .success(())
        }
    }

    func stop() {
        state.withLock { state in
            state.stopCount += 1
            state.handler = nil
            state.onDisabled = nil
            state.isInstalled = false
            state.isDisabled = false
        }
    }

    var isHealthy: Bool { state.withLock { $0.isInstalled && !$0.isDisabled } }

    func reenable() -> Bool {
        state.withLock { state in
            state.reenableCount += 1
            guard state.reenableSucceeds, state.isInstalled else { return false }
            state.isDisabled = false
            return true
        }
    }

    // MARK: Playing the tap thread

    /// Delivers one event to the installed handler. `.pass` when no tap is installed, as with no tap at all.
    @discardableResult
    func send(_ event: KeyEvent) -> KeyDecision {
        let handler = state.withLock { $0.handler }
        return handler?(event) ?? .pass
    }

    /// Key down then key up for each character; key code 0 stands for "a key that is not special". Returns the
    /// decision for each key down.
    @discardableResult
    func type(_ text: String) -> [KeyDecision] {
        text.map { ch in
            let down = send(KeyEvent(kind: .keyDown, keyCode: 0, characters: String(ch)))
            send(KeyEvent(kind: .keyUp, keyCode: 0, characters: String(ch)))
            return down
        }
    }

    /// A key down for `keyCode` (Space, Return, ...), then its key up.
    @discardableResult
    func press(_ keyCode: UInt16, _ characters: String = "") -> KeyDecision {
        let down = send(KeyEvent(kind: .keyDown, keyCode: keyCode, characters: characters))
        send(KeyEvent(kind: .keyUp, keyCode: keyCode))
        return down
    }

    /// macOS disabled the tap and told us: the adapter's `tapDisabledByTimeout` path.
    func simulateDisable(_ reason: TapDisableReason = .timeout) {
        let onDisabled = state.withLock { state -> (@Sendable (TapDisableReason) -> Void)? in
            guard state.isInstalled else { return nil }
            state.isDisabled = true
            return state.onDisabled
        }
        onDisabled?(reason)
    }

    /// macOS disabled the tap and did not tell us: only the watchdog's `isHealthy` check can notice.
    func disableSilently() {
        state.withLock { if $0.isInstalled { $0.isDisabled = true } }
    }
}

/// A `KeyValueStore` in memory, so a `SettingsStore` needs no UserDefaults.
final class InMemoryKeyValueStore: KeyValueStore, @unchecked Sendable {
    private let values = LockedValue<[String: String]>([:])
    func string(forKey key: String) -> String? { values.value[key] }
    func setString(_ value: String, forKey key: String) { values.withLock { $0[key] = value } }
    func removeValue(forKey key: String) { values.withLock { $0[key] = nil } }
}

/// `ItemBindingSource` with a settable answer and a count of how often the engine asked.
final class FakeItemBindingSource: ItemBindingSource, @unchecked Sendable {
    private struct State {
        var result: FlotsamResult<ItemBindings>
        var callCount = 0
    }

    private let state: LockedValue<State>

    init(triggers: [UUID: String] = [:]) {
        state = LockedValue(State(result: .success(ItemBindings(triggers: triggers))))
    }

    var callCount: Int { state.value.callCount }
    var result: FlotsamResult<ItemBindings> {
        get { state.value.result }
        set { state.withLock { $0.result = newValue } }
    }
    func setTriggers(_ triggers: [UUID: String]) { result = .success(ItemBindings(triggers: triggers)) }

    func itemBindings() async -> FlotsamResult<ItemBindings> {
        state.withLock { state in
            state.callCount += 1
            return state.result
        }
    }
}

/// A clock whose `sleep` suspends until the test calls `release`. The watchdog loop sleeps on it, so a test runs one
/// watchdog pass per `release` and the loop never spins on its own. `release` also advances `now` by the slept
/// duration, so `TapHealth`'s 60-second window sees real elapsed time.
final class GatedClock: WallClock, @unchecked Sendable {
    private struct State {
        var current = Date(timeIntervalSince1970: 1_800_000_000)
        var waiters: [UUID: (continuation: CheckedContinuation<Void, Never>, duration: Duration)] = [:]
        /// Cancelled before `sleep` had registered its continuation.
        var cancelledEarly: Set<UUID> = []
    }

    private let state = LockedValue(State())

    /// How many sleeps are waiting to be released.
    var waiting: Int { state.value.waiters.count }

    func now() -> Date { state.value.current }
    func advance(_ seconds: TimeInterval) { state.withLock { $0.current = $0.current.addingTimeInterval(seconds) } }

    func sleep(for duration: Duration) async {
        let id = UUID()
        await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                let resumeNow = state.withLock { state -> Bool in
                    if state.cancelledEarly.remove(id) != nil { return true }
                    state.waiters[id] = (continuation, duration)
                    return false
                }
                if resumeNow { continuation.resume() }
            }
        } onCancel: {
            // The port contract: cancellation returns early.
            let waiter = state.withLock { state -> CheckedContinuation<Void, Never>? in
                if let waiter = state.waiters.removeValue(forKey: id) { return waiter.continuation }
                state.cancelledEarly.insert(id)
                return nil
            }
            waiter?.resume()
        }
    }

    /// Lets every waiting sleep finish, with `now` moved on by the longest of them.
    func release() {
        let released = state.withLock { state -> [(continuation: CheckedContinuation<Void, Never>, duration: Duration)] in
            let all = Array(state.waiters.values)
            state.waiters = [:]
            let longest = all.map { $0.duration.seconds }.max() ?? 0
            state.current = state.current.addingTimeInterval(longest)
            return all
        }
        for waiter in released { waiter.continuation.resume() }
    }
}

/// Polls `condition` every few milliseconds until it holds or `timeout` passes. For state a loop on another task
/// reaches on its own; it replaces a fixed sleep, which is either too slow or too short.
@MainActor
func eventually(timeout: Duration = .seconds(5), _ condition: @MainActor () -> Bool) async -> Bool {
    let deadline = ContinuousClock.now + timeout
    while !condition() {
        if ContinuousClock.now >= deadline { return false }
        try? await Task.sleep(for: .milliseconds(5))
    }
    return true
}

/// A `TriggerEngine` over fakes on every port, sharing the expander harness's snapshot, environment, permissions and
/// reporter, so what the engine decides and what the expander does are observed in one place. Defaults: triggers on,
/// both permissions granted, the user in an ordinary editor. Call `engine.stop()` when the test ends.
@MainActor
final class EngineHarness {
    let base: ExpanderHarness
    let source = FakeKeyEventSource()
    let bindings: FakeItemBindingSource
    let settings = SettingsStore(store: InMemoryKeyValueStore())
    let bus = ItemEventBus()
    let clock = GatedClock()
    let resetSignal = TriggerResetSignal()
    let pollTick = PollTick()
    let engine: TriggerEngine

    init(triggers: [UUID: String] = [:], triggersEnabled: Bool = true, base: ExpanderHarness = ExpanderHarness()) {
        self.base = base
        bindings = FakeItemBindingSource(triggers: triggers)
        settings.set(triggersEnabled, for: SettingKeys.triggersEnabled)
        engine = TriggerEngine(
            source: source, snapshot: base.snapshot, bindings: bindings, settings: settings, bus: bus,
            expander: base.expander, keyboard: base.environment, permissions: base.permissions,
            reporter: base.reporter, clock: clock, resetSignal: resetSignal, ownBundleId: "com.example.flotsam",
            pollTick: pollTick)
    }

    /// Notice codes shown to the user, newest first.
    var noticeCodes: [ErrorCode] { base.presenter.notices.map(\.code) }

    /// Runs the poll ticks that make one watchdog period (FR-005-19); the pass itself runs in a task.
    func runWatchdogPass() {
        let ticks = Int(TriggerKeys.watchdogInterval / PollTick.interval)
        for _ in 0..<ticks { pollTick.fire() }
    }
}
