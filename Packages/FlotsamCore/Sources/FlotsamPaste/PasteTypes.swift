import FlotsamBase
import FlotsamStorage
import Foundation

/// What a paste action does with the item (ADR-0005).
public enum PasteMode: Sendable, Equatable {
    /// Return, double-click, item hotkey: every stored representation, then ⌘V.
    case paste
    /// ⌥Return: plain text only for text-bearing kinds, then ⌘V.
    case plainText
    /// ⇧Return: onto the pasteboard only (FR-003-15 steps 1 to 5).
    case copyOnly
}

public enum PasteOutcome: Sendable, Equatable {
    /// ⌘V was posted to the target.
    case pasted
    /// On the pasteboard, no ⌘V by request (⇧Return).
    case copied
    /// On the pasteboard, no ⌘V because Accessibility is off; the caller shows `SET-PRM-001` (FR-003-17).
    case copiedAccessibilityDenied
}

/// The panel, as the paste sequence needs it (FR-003-15 steps 5 and 6).
@MainActor
public protocol PasteHost {
    var isPanelVisible: Bool { get }
    func hidePanel()
}

/// The host for a paste that opens no panel (the paste queue, FR-003-25): nothing is visible and hiding does nothing, so
/// FR-003-15 steps 5 and 6 reduce to the settle delay and the ⌘V.
@MainActor
public struct NoPanelHost: PasteHost {
    public init() {}
    public var isPanelVisible: Bool { false }
    public func hidePanel() {}
}

/// The slice of Storage the paste sequence uses. `FlotsamDatabase` conforms below; tests use a fake, so Paste tests need
/// no database.
public protocol PasteItemStore: Sendable {
    func content(of itemId: UUID) async -> FlotsamResult<ItemContent>
    func recordPaste(of itemId: UUID) async -> FlotsamResult<Void>
    func delete(ids: [UUID]) async -> FlotsamResult<[UUID]>
}

extension FlotsamDatabase: PasteItemStore {}
