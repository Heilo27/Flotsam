import FlotsamBase
import FlotsamPaste
import Foundation

/// FR-003-25: the paste queue. Several items are lined up in the Library, then the paste-queue hotkey (FR-005-01)
/// pastes them one per press into the app in front at key-down. Each press is the Library's paste sequence
/// (FR-003-15 via `PasteService.paste`, the one home of the pasteboard write, `pasteCount` and ⌘V) with no panel.
///
/// The queue advances only when the item was handled: pasted, or copied because Accessibility is off (the user pastes
/// it by hand, so the copy is the most that can happen). A transient failure (`LIB-OS-001`, a cancelled owner check)
/// leaves the item at the head so the next press retries it; a permanent one (data gone, every file gone, secure key
/// gone) drops that item so the queue is never stuck behind it. State is in memory only and holds ids, never content.
/// Nothing here observes the keyboard or polls: the queue is inert between presses (S5).
@MainActor
public final class PasteQueue {
    private let paster: PasteService
    private let frontmost: any FrontmostAppProvider
    private let report: @MainActor (FlotsamError) -> Void
    private let hud: @MainActor (String) -> Void
    private var pending: [UUID] = []
    private var total = 0
    /// Bumped by `start` and `cancel`, so a paste that finishes after either does not touch the new state.
    private var generation = 0
    private var inFlight = false

    public init(
        paster: PasteService, frontmost: any FrontmostAppProvider, report: @escaping @MainActor (FlotsamError) -> Void,
        hud: @escaping @MainActor (String) -> Void
    ) {
        self.paster = paster
        self.frontmost = frontmost
        self.report = report
        self.hud = hud
    }

    public var isActive: Bool { !pending.isEmpty }
    public var remaining: Int { pending.count }

    /// Replaces any queue with `ids`, in order. Fewer than two items is not a queue: false, nothing changes.
    @discardableResult
    public func start(_ ids: [UUID]) -> Bool {
        guard ids.count >= 2 else { return false }
        generation += 1
        pending = ids
        total = ids.count
        hud(Self.text(.ready, ids.count))
        return true
    }

    /// Drops the queue (Esc in the Library). True when there was one.
    @discardableResult
    public func cancel() -> Bool {
        guard isActive else { return false }
        generation += 1
        pending = []
        total = 0
        hud(Self.text(.cancelled))
        return true
    }

    /// The paste-queue hotkey: pastes the item at the head. A press while one is running is ignored (two sequences would
    /// fight over the pasteboard and the ⌘V target); a press with no queue says so.
    public func pasteNext() async {
        guard !inFlight else { return }
        guard let itemId = pending.first else {
            hud(Self.text(.empty))
            return
        }
        inFlight = true
        defer { inFlight = false }
        let started = generation
        let result = await paster.paste(itemId: itemId, mode: .paste, target: frontmost.frontmost(), host: NoPanelHost())
        // Cancelled or replaced while pasting: the paste happened, but the queue it belonged to is gone.
        guard started == generation else { return }
        switch result {
        case .success(.pasted), .success(.copied):
            advance()
            hud(isActive ? Self.progress(done: total - pending.count, of: total) : Self.text(.finished))
        case .success(.copiedAccessibilityDenied):
            // Copy-only (FR-003-17): the item is on the pasteboard for the user's own ⌘V, so the queue moves on.
            advance()
            report(PasteGate.copyOnlyError(itemId: itemId))
        case .failure(let error):
            if Self.isPermanent(error) { advance() }
            report(error)
        }
    }

    /// Failures that no later press can cure: the item's data is gone (`LIB-IO-001`), every file is gone (`LIB-DAT-001`)
    /// or a secure item's key is gone (`LIB-DAT-002`). Everything else (`LIB-OS-001`, `LIB-OS-002`) can succeed on a retry.
    static func isPermanent(_ error: FlotsamError) -> Bool {
        switch error.code {
        case .libIo001, .libDat001, .libDat002: true
        default: false
        }
    }

    private func advance() {
        guard !pending.isEmpty else { return }
        pending.removeFirst()
        if pending.isEmpty { total = 0 }
    }

    // MARK: Text (FR-000-05: catalogue keys only)

    private enum Key: String {
        case ready = "ui.queue.ready"
        case progress = "ui.queue.progress"
        case finished = "ui.queue.finished"
        case cancelled = "ui.queue.cancelled"
        case empty = "ui.queue.empty"
        case noShortcut = "ui.queue.noShortcut"
    }

    private static func text(_ key: Key, _ arguments: CVarArg...) -> String {
        let value = arguments.isEmpty ? FlotsamStrings.text(forKey: key.rawValue) : FlotsamStrings.formatted(forKey: key.rawValue, arguments)
        return value ?? FlotsamStrings.message(for: .sysInt001)
    }

    private static func progress(done: Int, of total: Int) -> String { text(.progress, done, total) }

    /// The HUD for a queue that could not start because the paste-queue shortcut is not set (FR-003-25).
    public static var noShortcutMessage: String { text(.noShortcut) }
}
