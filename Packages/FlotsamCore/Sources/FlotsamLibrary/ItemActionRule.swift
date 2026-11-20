import FlotsamBase
import Foundation

/// Which organize actions an item or a selection allows (FR-003-22, FR-004-06, FR-004-07, FR-004-11, FR-004-15). One home
/// per rule, read by the context menu (`LibraryContextMenu`, which has a kind and a target count for the single-item
/// rules, and the target's rows for Group) and by `LibraryOrganizer` (which has the selected rows), so the menu offering
/// a row and the coordinator acting on it cannot disagree. The shortcut-and-trigger editor's rule is `ShortcutEditorRule` (FR-005-09).
public enum ItemActionRule {
    /// Note: exactly one item (FR-004-06).
    public static func note(isSingleItem: Bool) -> Bool { isSingleItem }

    /// Edit text: exactly one item, of a text-like kind, and not a secure one (its text is never shown, FR-004-07).
    public static func edit(kind: ItemKind, isSingleItem: Bool, isSecure: Bool) -> Bool {
        isSingleItem && kind.isTextEditable && !isSecure
    }

    /// Ungroup and Rename (FR-004-11, FR-004-15): exactly one item, a bundle.
    public static func ungroup(kind: ItemKind, isSingleItem: Bool) -> Bool { isSingleItem && kind == .bundle }

    /// Group (FR-004-15): two or more items that all reference files (file, folder, bundle), at most `BundleLimits.maxMembers`
    /// members between them (a bundle counts its members, any other item one). `rows` is what the action would act on:
    /// the selection, or for a menu opened on an unselected row, that row.
    public static func group(_ rows: [ItemRow]) -> Bool {
        rows.count >= 2 && rows.allSatisfy { $0.kind.referencesFiles }
            && rows.reduce(0) { $0 + max($1.memberCount, 1) } <= BundleLimits.maxMembers
    }
}
