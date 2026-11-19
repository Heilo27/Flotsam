import AppKit
import FlotsamBase
import SwiftUI

/// The shortcut-and-trigger editor window (FR-005-09). One window: opening it for another item replaces the one
/// showing, so two editors never race on the same registry. ⌘W and Escape close it.
@MainActor
final class ItemBindingsEditorWindowController: NSObject, NSWindowDelegate {
    private let services: ItemBindingsEditorServices
    private var window: NSWindow?
    private var front: WindowFrontAdapter?
    private var model: ItemBindingsEditorModel?

    init(services: ItemBindingsEditorServices) {
        self.services = services
    }

    func open(itemId: UUID) {
        if let model, model.itemId == itemId, let front {
            front.bringToFront()
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
        // Opened from the Library panel, which never activates the app: the window must bring Flotsam forward itself.
        let front = WindowFrontAdapter(window: window)
        self.front = front
        front.bringToFront()
    }

    func windowWillClose(_ notification: Notification) {
        // The recorder's hotkey suspension must end with the window, however it was closed.
        model?.stopRecording()
        model = nil
        window = nil
        front = nil
    }

    private func closeCurrent() {
        model?.stopRecording()
        let old = window
        model = nil
        window = nil
        front = nil
        old?.delegate = nil
        old?.close()
    }
}

/// Window subclass for the keys a menu would normally supply: this is a menu-bar app with no main menu. Shared by the
/// small editor windows (shortcut and trigger, Add Clip).
final class EditorWindow: NSWindow {
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
