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
/// engine acts on it off the tap thread. The only calls out are the `KeyboardEnvironment` reads: three when a word has already matched a trigger, and
/// `frontmostApp()` once at the start of each word.
public final class TriggerMatcher {
    private let store: TriggerSnapshotStore
    private let environment: any KeyboardEnvironment
    private let clock: any WallClock
    private let resetSignal: TriggerResetSignal
    /// Flotsam's own windows are always excluded and not editable (FR-005-13).
    private let ownBundleId: String

    /// The word typed so far. Its length is always `buffer.count` (graphemes): there is no second counter to drift from
    /// it. A combining mark that arrives as its own key event joins the previous character and adds none.
    private var buffer = ""
    /// A word that can no longer match until the next boundary or reset (FR-005-11): it grew past 24 characters, it had
    /// a Backspace on an empty buffer, or it took a non-ASCII character (which stays fatal even after Backspace).
    /// Its buffer is always empty.
    private var isDead = false
    private var lastEventAt: Date?
    /// The frontmost application when the current word got its first character (FR-005-11: a change of frontmost
    /// application clears the word). Compared at the boundary key; the engine's `frontmostApplicationDidChange()`
    /// signal clears the word sooner. Set once per word, so it survives Backspace to an empty buffer.
    private var wordApp: FrontmostApp??
    /// True when the current word began in an excluded application (FR-005-13 b), decided once with `wordApp`. Such a
    /// word is kept only while it is still the start of some trigger (FR-005-20, security F-04): the buffer exists
    /// there only so a whole trigger can be logged as `TRG-POL-002`, so ordinary typing holds nothing.
    private var keepsOnlyTriggerPrefixes = false
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
        // FR-005-11: a non-ASCII character (a Thai mark, an accent, any letter outside ASCII) kills the word until the
        // next boundary or reset, and Backspacing it away does not bring the word back. A text field may delete one
        // scalar where the buffer would delete a whole grapheme cluster, so after such input the buffer cannot know
        // what the field holds; a trigger is ASCII (FR-005-08), so the word could never match anyway.
        guard characters.utf8.allSatisfy({ $0 < 0x80 }) else {
            clearWord()
            isDead = true
            return
        }
        if wordApp == nil {
            let app = environment.frontmostApp()
            wordApp = .some(app)
            if let bundleId = app?.bundleId {
                keepsOnlyTriggerPrefixes = store.policy.excludes(bundleId: bundleId, ownBundleId: ownBundleId)
            }
        }
        var grown = buffer
        grown += characters
        // Past 24 characters, or (in an excluded application) no longer the start of any trigger: the word cannot
        // match, so nothing of it is kept. It is dead until the next boundary, like any other word that cannot match.
        guard grown.count <= TriggerGrammar.maximumLength,
            !keepsOnlyTriggerPrefixes
                || store.policy.triggers.isPrefixOfSomeKey(TriggerGrammar.canonicalKey(grown))
        else {
            clearWord()
            isDead = true
            return
        }
        buffer = grown
    }

    private func backspace() {
        if buffer.isEmpty {
            isDead = true
        } else {
            buffer.removeLast()
        }
    }

    /// True when no typed character is held. The matcher's own state, read by tests for the F-04 guarantee: the word
    /// buffer is empty after every boundary key (whatever its outcome) and after every reset.
    var holdsNoCharacters: Bool { buffer.isEmpty }

    private func boundary(_ event: KeyEvent) -> MatcherResult {
        // Security F-04: the word is moved into `typed` and the buffer is cleared first, so every exit below (no match,
        // each suppression, a match) leaves the buffer empty. `typed` is a local; it outlives this call only inside a
        // `TriggerMatch`, which the expander needs to re-type the word on failure (FR-005-15).
        let typed = buffer
        let wasDead = isDead
        let startedIn = wordApp
        clearWord()
        guard !wasDead, typed.count >= TriggerGrammar.minimumLength else { return .pass }

        let policy = store.policy
        guard let itemId = policy.triggers.itemId(forKey: TriggerGrammar.canonicalKey(typed)) else { return .pass }

        // The word began in another application: nothing was typed here, so it is not a match and not logged.
        let frontmost = environment.frontmostApp()
        guard startedIn == .some(frontmost) else { return .pass }

        if environment.isSecureEventInputEnabled() { return .suppressed(.secureInput) }
        guard let app = frontmost, let bundleId = app.bundleId else { return .suppressed(.unknownApp) }
        if policy.excludes(bundleId: bundleId, ownBundleId: ownBundleId) { return .suppressed(.excludedApp) }
        if environment.isInputMethodActive() { return .suppressed(.inputMethod) }

        heldBoundaryKeys.insert(event.keyCode)
        return .matched(TriggerMatch(
            itemId: itemId, typedText: typed, triggerLength: typed.count, boundaryKeyCode: event.keyCode, app: app))
    }

    private func clearWord() {
        buffer = ""
        isDead = false
        wordApp = nil
        keepsOnlyTriggerPrefixes = false
    }
}

extension Duration {
    /// Whole and fractional seconds, for comparing against `Date` intervals.
    var seconds: TimeInterval {
        let parts = components
        return TimeInterval(parts.seconds) + TimeInterval(parts.attoseconds) / 1e18
    }
}
