import Foundation

/// One button in a row's hover strip (FR-003-38).
public struct LibraryHoverAction: Sendable, Equatable, Identifiable {
    public let titleKey: String
    public let symbol: String
    public let command: LibraryCommand
    public let isDestructive: Bool
    public var id: String { titleKey }
}

/// The mouse-only hover affordances (FR-003-38, FR-003-39): the strip of row actions and the delay before a hover preview.
/// The one definition, so the view only draws it. A button is the context menu's entry with the same command and title
/// (FR-003-22), so the two paths cannot drift.
public enum LibraryHover {
    /// How long the pointer rests on a row before its preview opens (FR-003-39).
    public static let previewDelay: Duration = .milliseconds(500)

    /// Copy, Pin or Unpin, Delete, in that order. `pinUnpins` is `LibraryViewModel.pinActionUnpins`, the rule the context
    /// menu's Pin or Unpin entry reads.
    public static func actions(pinUnpins: Bool) -> [LibraryHoverAction] {
        [
            LibraryHoverAction(titleKey: LibraryText.menuCopy, symbol: "doc.on.doc", command: .paste(.copyOnly), isDestructive: false),
            LibraryHoverAction(
                titleKey: pinUnpins ? LibraryText.menuUnpin : LibraryText.menuPin, symbol: pinUnpins ? "pin.slash" : "pin",
                command: .external(.pin), isDestructive: false),
            LibraryHoverAction(titleKey: LibraryText.menuDelete, symbol: "trash", command: .external(.delete), isDestructive: true),
        ]
    }
}
