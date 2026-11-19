import FlotsamBase
import Foundation

/// One line of a row's context menu (FR-003-22).
public enum LibraryMenuEntry: Sendable, Equatable {
    case item(titleKey: String, command: LibraryCommand, isDestructive: Bool)
    case separator
}

/// The right-click menu as data (FR-003-22): the one definition of its order and separators, so the view only draws it.
public enum LibraryContextMenu {
    /// Paste, Paste as Plain Text, Copy, Preview, separator, Pin or Unpin, Tags..., Note..., Edit... (text only),
    /// Shortcut and Trigger..., Ungroup (bundle), separator, Reveal in Finder (file kinds) with its own separator after
    /// it, Delete. A separator never leads, trails or doubles, so a kind without Reveal in Finder has one separator
    /// between the organize group and Delete. Note, Edit, Shortcut and Trigger and Ungroup act on one item, so they appear only
    /// when the menu's target is a single item (`singleTarget`). A secure item (`isSecure`) is offered neither Edit nor
    /// Shortcut and Trigger: its text is never shown, and it can carry no hotkey or trigger (FR-005-09; the Shortcut and
    /// Trigger row reads `ShortcutEditorRule`, the same rule ⌘K reads, so with several items selected the row is absent,
    /// as ⌘K does nothing).
    public static func entries(kind: ItemKind, pinUnpins: Bool, singleTarget: Bool, isSecure: Bool = false) -> [LibraryMenuEntry] {
        var entries: [LibraryMenuEntry] = [
            plain(LibraryText.menuPaste, .paste(.paste)),
            plain(LibraryText.menuPastePlain, .paste(.plainText)),
            plain(LibraryText.menuCopy, .paste(.copyOnly)),
            plain(LibraryText.menuPreview, .togglePreview),
            .separator,
            plain(pinUnpins ? LibraryText.menuUnpin : LibraryText.menuPin, .external(.pin)),
            plain(LibraryText.menuTags, .external(.tags)),
        ]
        if singleTarget {
            entries.append(plain(LibraryText.menuNote, .external(.note)))
            if kind.isTextEditable, !isSecure { entries.append(plain(LibraryText.menuEdit, .external(.edit))) }
        }
        if ShortcutEditorRule.allows(isSingleItem: singleTarget, isSecure: isSecure) { entries.append(plain(LibraryText.menuShortcutAndTrigger, .external(.shortcutAndTrigger))) }
        if singleTarget, kind == .bundle {
            entries.append(plain(LibraryText.menuRename, .external(.renameBundle)))
            entries.append(plain(LibraryText.menuUngroup, .external(.ungroup)))
        }
        if !singleTarget, kind.referencesFiles { entries.append(plain(LibraryText.menuGroup, .external(.group))) }
        entries.append(.separator)
        if kind.referencesFiles {
            entries.append(plain(LibraryText.menuReveal, .revealInFinder))
            entries.append(.separator)
        }
        entries.append(.item(titleKey: LibraryText.menuDelete, command: .external(.delete), isDestructive: true))
        return entries
    }

    private static func plain(_ titleKey: String, _ command: LibraryCommand) -> LibraryMenuEntry {
        .item(titleKey: titleKey, command: command, isDestructive: false)
    }
}
