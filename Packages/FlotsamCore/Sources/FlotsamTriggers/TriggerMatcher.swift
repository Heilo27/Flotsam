import FlotsamBase
import Foundation

/// A word matched exactly one trigger and no suppression applies (FR-005-12). Carried to the expander, in memory only:
/// `typedText` is what the user typed (FR-005-15 re-types it on failure) and must never be logged (FR-005-20).
public struct TriggerMatch: Sendable, Equatable {
    public let itemId: UUID
    public let typedText: String
    /// Backspaces to post (FR-005-14 step 5): the trigger length in characters.
    public let triggerLength: Int
    /// The swallowed boundary key, so a failed expansion can re-post it (FR-005-15).
    public let boundaryKeyCode: UInt16
    /// The application the user was typing into when the boundary key arrived (FR-005-14 step 2 compares against it).
    public let app: FrontmostApp
}

/// Why a matched word did not expand (FR-005-13). `TRG-POL-001` and `TRG-POL-002` are logged; the rest are silent.
public enum TriggerSuppression: Sendable, Equatable {
    case secureInput
    case excludedApp
    case inputMethod
    /// No frontmost application, or one without a bundle identifier: the exclusion list cannot be checked, so the
    /// engine does not expand (fail closed, so a terminal is never typed into by mistake).
    case unknownApp
}

public enum MatcherResult: Sendable, Equatable {
    case pass
    /// Swallow the event: the key-up or auto-repeat of a boundary key that just matched.
    case consume
    case matched(TriggerMatch)
    case suppressed(TriggerSuppression)

    public var decision: KeyDecision {
        switch self {
        case .pass, .suppressed: .pass
        case .consume, .matched: .consume
        }
    }
}

/// The typed-word buffer and match decision (FR-005-11, FR-005-12, FR-005-13).
///
/// Deliberately not `Sendable`: it is confined to the tap thread (ADR-0007) and holds mutable state with no lock. It
/// does no I/O and no logging, so the callback stays inside its 1 ms budget (FR-005-21); it returns a value and the
/// engine acts on it off the tap thread. The only calls out are the three `KeyboardEnvironment` reads, and only when a
/// word has already matched a trigger.
public final class TriggerMatcher {
    private let store: TriggerSnapshotStore
    private let environment: any KeyboardEnvironment
    private let clock: any WallClock
    private let resetSignal: TriggerResetSignal
    /// Flotsam's own windows are always excluded and not editable (FR-005-13).
    private let ownBundleId: String

    private var buffer = ""
    private var bufferCount = 0
    /// A word that can no longer match until the next boundary or reset (FR-005-11). Its buffer is always empty.
    private var isDead = false
    private var lastEventAt: Date?
    /// Boundary keys whose key-down was swallowed and whose key-up has not arrived yet.
    private var heldBoundaryKeys: Set<UInt16> = []

    public init(
        store: TriggerSnapshotStore, environment: any KeyboardEnvironment, clock: any WallClock,
        resetSignal: TriggerResetSignal, ownBundleId: String
    ) {
        self.store = store
        self.environment = environment
        self.clock = clock
        self.resetSignal = resetSignal
        self.ownBundleId = ownBundleId
    }

    public func process(_ event: KeyEvent) -> MatcherResult {
        // FR-005-13 d: Flotsam's own events never build or match a word; FR-005-11: they also clear it.
        if event.isFlotsamEvent { clearWord(); return .pass }

        let now = clock.now()
        if resetSignal.consume() { clearWord() }
        if let last = lastEventAt, now.timeIntervalSince(last) > TriggerKeys.wordIdleTimeout.seconds { clearWord() }
        lastEventAt = now

        switch event.kind {
        case .mouseDown:
            clearWord()
            return .pass
        case .keyUp:
            // The key-up of a swallowed boundary key is swallowed too, so the app never sees half a key press.
            return heldBoundaryKeys.remove(event.keyCode) != nil ? .consume : .pass
        case .keyDown:
            return keyDown(event)
        }
    }

    /// Clears the word, for a change the matcher cannot see itself. Call from the tap thread only; other threads use
    /// `TriggerResetSignal.request()`.
    public func reset() { clearWord() }

    private func keyDown(_ event: KeyEvent) -> MatcherResult {
        if heldBoundaryKeys.contains(event.keyCode) {
            // Holding the boundary key after a match repeats it; the repeats are consumed with the original.
            if event.isAutoRepeat { return .consume }
            heldBoundaryKeys.remove(event.keyCode)  // a new press: the earlier key-up was lost
        }
        if event.flags.hasCommandModifier { clearWord(); return .pass }

        if TriggerKeys.boundaryKeyCodes.contains(event.keyCode) {
            // Shift+boundary is not a boundary key (FR-005-12): it ends the word without a match.
            if event.flags.contains(.shift) { clearWord(); return .pass }
            return boundary(event)
        }
        if event.keyCode == TriggerKeys.backspace { backspace(); return .pass }
        if TriggerKeys.resetKeyCodes.contains(event.keyCode) || !TriggerKeys.isPrintable(event.characters) {
            clearWord()
            return .pass
        }
        append(event.characters)
        return .pass
    }

    private func append(_ characters: String) {
        guard !isDead else { return }
        let added = characters.count
        guard bufferCount + added <= TriggerGrammar.maximumLength else {
            clearWord()
            isDead = true
            return
        }
        buffer += characters
        bufferCount += added
    }

    private func backspace() {
        if bufferCount == 0 {
            isDead = true
        } else {
            buffer.removeLast()
            bufferCount -= 1
        }
    }

    private func boundary(_ event: KeyEvent) -> MatcherResult {
        let typed = buffer
        let wasDead = isDead
        clearWord()
        guard !wasDead, typed.count >= TriggerGrammar.minimumLength else { return .pass }

        let policy = store.policy
        guard let itemId = policy.triggers.itemId(forKey: TriggerGrammar.canonicalKey(typed)) else { return .pass }

        if environment.isSecureEventInputEnabled() { return .suppressed(.secureInput) }
        guard let app = environment.frontmostApp(), let bundleId = app.bundleId else { return .suppressed(.unknownApp) }
        if policy.excludes(bundleId: bundleId, ownBundleId: ownBundleId) { return .suppressed(.excludedApp) }
        if environment.isInputMethodActive() { return .suppressed(.inputMethod) }

        heldBoundaryKeys.insert(event.keyCode)
        return .matched(TriggerMatch(
            itemId: itemId, typedText: typed, triggerLength: typed.count, boundaryKeyCode: event.keyCode, app: app))
    }

    private func clearWord() {
        buffer = ""
        bufferCount = 0
        isDead = false
    }
}

extension Duration {
    /// Whole and fractional seconds, for comparing against `Date` intervals.
    fileprivate var seconds: TimeInterval {
        let parts = components
        return TimeInterval(parts.seconds) + TimeInterval(parts.attoseconds) / 1e18
    }
}
