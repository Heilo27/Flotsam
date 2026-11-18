import AppKit
import FlotsamBase

/// The app's main menu (FR-008-19). Flotsam is an accessory (menu-bar) app, so this menu is never on screen; it exists
/// because AppKit resolves ⌘A, ⌘C, ⌘V, ⌘X, ⌘Z and ⇧⌘Z in a text field through the main menu's key equivalents, and an app
/// with no main menu gets none of them. Every Edit item targets the first responder (nil target), so the shortcut acts on
/// whichever field is focused: Library search, the Organize overlays, the editor and Settings.
///
/// Why only these keys: the Library, Shelf and recorder key monitors run before the menu and consume their own keys, and
/// FR-005-02 reserves ⌘C ⌘V ⌘X ⌘Z ⌘A ⌘Q, so no in-app or global shortcut can collide with an item here.
@MainActor
enum MainMenuBuilder {
    /// Catalogue keys (FR-000-05) for each item title.
    enum TitleKey {
        static let quit = "ui.menu.quit"
        static let edit = "ui.mainMenu.edit"
        static let undo = "ui.mainMenu.undo"
        static let redo = "ui.mainMenu.redo"
        static let cut = "ui.mainMenu.cut"
        static let copy = "ui.mainMenu.copy"
        static let paste = "ui.mainMenu.paste"
        static let selectAll = "ui.mainMenu.selectAll"
    }

    /// AppKit has no public `undo:` / `redo:` selectors on the responder chain; these are the names NSTextView and
    /// NSWindow answer to, the same ones a stock Edit menu uses.
    static let undoAction = Selector(("undo:"))
    static let redoAction = Selector(("redo:"))

    static func make() -> NSMenu {
        let main = NSMenu()
        main.addItem(appItem())
        main.addItem(editItem())
        return main
    }

    private static func appItem() -> NSMenuItem {
        let item = NSMenuItem()
        let menu = NSMenu()
        menu.addItem(entry(TitleKey.quit, #selector(NSApplication.terminate(_:)), "q"))
        item.submenu = menu
        return item
    }

    private static func editItem() -> NSMenuItem {
        let item = NSMenuItem()
        let menu = NSMenu(title: text(TitleKey.edit))
        menu.addItem(entry(TitleKey.undo, undoAction, "z"))
        menu.addItem(entry(TitleKey.redo, redoAction, "z", extra: .shift))
        menu.addItem(.separator())
        menu.addItem(entry(TitleKey.cut, #selector(NSText.cut(_:)), "x"))
        menu.addItem(entry(TitleKey.copy, #selector(NSText.copy(_:)), "c"))
        menu.addItem(entry(TitleKey.paste, #selector(NSText.paste(_:)), "v"))
        menu.addItem(.separator())
        menu.addItem(entry(TitleKey.selectAll, #selector(NSText.selectAll(_:)), "a"))
        item.title = menu.title
        item.submenu = menu
        return item
    }

    private static func entry(
        _ titleKey: String, _ action: Selector, _ key: String, extra: NSEvent.ModifierFlags = []
    ) -> NSMenuItem {
        let item = NSMenuItem(title: text(titleKey), action: action, keyEquivalent: key)
        item.keyEquivalentModifierMask = NSEvent.ModifierFlags.command.union(extra)
        item.target = nil
        return item
    }

    private static func text(_ key: String) -> String { FlotsamStrings.text(forKey: key) ?? key }
}
