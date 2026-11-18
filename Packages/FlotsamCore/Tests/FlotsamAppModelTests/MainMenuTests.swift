import AppKit
import Testing

// TASK-453 regression (FR-008-19). Bug report: in the Library edit card (⌘E) a real ⌘A then typing appended to the text
// instead of replacing it, because the app installed no main menu and an NSTextView only gets ⌘A ⌘C ⌘V ⌘X ⌘Z ⇧⌘Z from
// the main menu's key equivalents. These tests send a real key event through the menu the way NSApplication does and
// check what the text view did, so they are red when the menu is absent.

@MainActor
@Suite(.serialized)
struct MainMenuTests {
    /// What AppKit does for a key press: find the main-menu item whose key equivalent matches, and send its action
    /// to the first responder. (A `swift test` process is never the active app, so NSApp has no key window and
    /// `NSMenu.performKeyEquivalent` cannot route; the window-server routing itself is exercised by the real-CGEvent
    /// harness bin/repro/TASK-453-select-all.swift.) Returns false when no item matches, which is the bug.
    private func press(_ key: String, _ flags: NSEvent.ModifierFlags = .command, on view: NSTextView) -> Bool {
        guard let menu = NSApp.mainMenu else { return false }
        for top in menu.items {
            for item in top.submenu?.items ?? [] where item.keyEquivalent == key && item.keyEquivalentModifierMask == flags {
                guard let action = item.action else { return false }
                return NSApp.sendAction(action, to: view, from: item)
            }
        }
        return false
    }

    private func makeEditor(_ text: String) -> NSTextView {
        _ = NSApplication.shared
        let view = NSTextView(frame: NSRect(x: 0, y: 0, width: 300, height: 120))
        view.isEditable = true
        view.isRichText = false
        view.allowsUndo = true
        view.string = text
        view.setSelectedRange(NSRange(location: view.string.count, length: 0))
        return view
    }

    @Test func installedMenuHasStandardEditKeyEquivalents() throws {
        let menu = MainMenuBuilder.make()
        let edit = try #require(menu.items.compactMap(\.submenu).first { $0.items.contains { $0.keyEquivalent == "a" } })
        var found: [String: Selector] = [:]
        for item in edit.items where !item.isSeparatorItem {
            let shift = item.keyEquivalentModifierMask.contains(.shift) ? "⇧" : ""
            #expect(item.keyEquivalentModifierMask.contains(.command), "\(item.title) needs ⌘")
            #expect(item.target == nil, "\(item.title) must target the first responder")
            if let action = item.action { found[shift + item.keyEquivalent] = action }
        }
        #expect(found["z"] == MainMenuBuilder.undoAction)
        #expect(found["⇧z"] == MainMenuBuilder.redoAction)
        #expect(found["x"] == #selector(NSText.cut(_:)))
        #expect(found["c"] == #selector(NSText.copy(_:)))
        #expect(found["v"] == #selector(NSText.paste(_:)))
        #expect(found["a"] == #selector(NSText.selectAll(_:)))
        #expect(edit.items.allSatisfy { $0.isSeparatorItem || !$0.title.isEmpty && !$0.title.hasPrefix("ui.") })
    }

    @Test func commandASelectsEverythingSoTypingReplaces() {
        let view = makeEditor("hello world")
        defer { NSApp.mainMenu = nil }
        NSApp.mainMenu = MainMenuBuilder.make()
        #expect(press("a", on: view))
        #expect(view.selectedRange() == NSRange(location: 0, length: 11))
        view.insertText("x", replacementRange: view.selectedRange())
        #expect(view.string == "x")
    }

    @Test func withoutAMainMenuCommandAHasNoEffect() {
        // The pre-fix state; also guards `press` from passing vacuously.
        let view = makeEditor("hello world")
        NSApp.mainMenu = nil
        #expect(!press("a", on: view))
        #expect(view.selectedRange().length == 0)
    }
}
