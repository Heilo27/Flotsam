import FlotsamBase
import FlotsamPaste
import Foundation

/// FR-005-05: what pressing an item's hotkey does. It runs the paste-back sequence of FR-003-15 on the item with no
/// panel, into the app that is frontmost at key-down. The paste itself is `PasteService.pasteExpanded`, which expands
/// variables (FR-005-17) and restores the previous clipboard (FR-005-16) with the same `PasteExpansion` the typed
/// triggers use (one sequence, Rule 9).
@MainActor
public final class ItemHotkeyAction {
    private let paster: PasteService
    private let expansion: PasteExpansion
    private let frontmost: any FrontmostAppProvider
    private let report: @MainActor (FlotsamError) -> Void
    private var inFlight = false

    public init(
        paster: PasteService, expansion: PasteExpansion, frontmost: any FrontmostAppProvider,
        report: @escaping @MainActor (FlotsamError) -> Void
    ) {
        self.paster = paster
        self.expansion = expansion
        self.frontmost = frontmost
        self.report = report
    }

    /// Runs the paste for `itemId`. A second press while one is running is ignored: two sequences would fight over the
    /// pasteboard and the ⌘V target.
    public func run(itemId: UUID) async {
        guard !inFlight else { return }
        inFlight = true
        defer { inFlight = false }
        let target = frontmost.frontmost()
        let result = await paster.pasteExpanded(itemId: itemId, target: target, expansion: expansion)
        if let error = Self.error(for: result, itemId: itemId) { report(error) }
    }

    /// The error to show for a paste result, if any. Copy-only because Accessibility is off is `SET-PRM-001`
    /// (FR-003-17); every other failure keeps its own code.
    static func error(for result: FlotsamResult<PasteOutcome>, itemId: UUID) -> FlotsamError? {
        switch result {
        case .success(.pasted), .success(.copied): nil
        case .success(.copiedAccessibilityDenied):
            FlotsamError(.setPrm001, "item hotkey copied only: Accessibility not granted", context: [.itemId: .id(itemId)])
        case .failure(let error): error
        }
    }
}
