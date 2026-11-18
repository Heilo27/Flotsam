import AppKit
import FlotsamBase
import SwiftUI

/// The shortcut-and-trigger editor window (FR-005-09). One window: opening it for another item replaces the one
/// showing, so two editors never race on the same registry. ⌘W and Escape close it.
@MainActor
final class ItemBindingsEditorWindowController: NSObject, NSWindowDelegate {
    private let services: ItemBindingsEditorServices
    private var window: NSWindow?
    private var model: ItemBindingsEditorModel?

    init(services: ItemBindingsEditorServices) {
        self.services = services
    }

    func open(itemId: UUID) {
        if let model, model.itemId == itemId, let window {
            NSApp.activate()
            window.makeKeyAndOrderFront(nil)
            return
        }
        closeCurrent()
        let model = ItemBindingsEditorModel(itemId: itemId, services: services)
        let host = NSHostingController(rootView: ItemBindingsEditorView(model: model) { [weak self] in self?.closeCurrent() })
        host.sizingOptions = [.preferredContentSize]
        host.title = SettingsString.editorWindow.text
        let window = EditorWindow(contentViewController: host)
        window.title = SettingsString.editorWindow.text
        window.styleMask = [.titled, .closable]
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.center()
        self.model = model
        self.window = window
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        // The recorder's hotkey suspension must end with the window, however it was closed.
        model?.stopRecording()
        model = nil
        window = nil
    }

    private func closeCurrent() {
        model?.stopRecording()
        let old = window
        model = nil
        window = nil
        old?.delegate = nil
        old?.close()
    }
}

/// Window subclass for the keys a menu would normally supply: this is a menu-bar app with no main menu.
private final class EditorWindow: NSWindow {
    override func cancelOperation(_ sender: Any?) { performClose(sender) }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if flags == .command, event.charactersIgnoringModifiers == "w" {
            performClose(nil)
            return true
        }
        return super.performKeyEquivalent(with: event)
    }
}
