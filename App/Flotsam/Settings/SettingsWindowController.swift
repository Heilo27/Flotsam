import AppKit
import FlotsamBase
import SwiftUI

/// The Settings window (FR-008-03): one window, a toolbar of panes in `SettingsPane` order, reopening on the last pane.
/// Every control applies at once, so closing discards nothing; ⌘W and Escape close it.
@MainActor
final class SettingsWindowController {
    private let model: SettingsModel
    private var window: NSWindow?

    init(env: SettingsEnvironment) {
        model = SettingsModel(env: env)
    }

    /// Opens the window, or focuses it when it is already open, on the pane last used. Every "Open Settings" caller
    /// (the menu-bar item, a Notice or alert action, ⌘, from the Library) calls this one method.
    func openSettings() {
        let window = window ?? makeWindow()
        self.window = window
        if let tabs = window.contentViewController as? SettingsTabViewController {
            tabs.select(SettingsPane.lastOpened(in: model.env.settings))
        }
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
    }

    private func makeWindow() -> NSWindow {
        let tabs = SettingsTabViewController(model: model)
        let window = SettingsWindow(contentViewController: tabs)
        window.styleMask = [.titled, .closable, .miniaturizable]
        window.isReleasedWhenClosed = false
        window.setFrameAutosaveName("")
        window.center()
        return window
    }
}

/// A toolbar-style tab controller with one hosting controller per pane. A pane's size is its SwiftUI content's size,
/// so the window resizes as the user switches panes.
@MainActor
private final class SettingsTabViewController: NSTabViewController {
    private let model: SettingsModel

    init(model: SettingsModel) {
        self.model = model
        super.init(nibName: nil, bundle: nil)
        tabStyle = .toolbar
        for pane in SettingsPane.allCases { addTabViewItem(item(for: pane)) }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("SettingsTabViewController is not decoded from a nib") } // fatal-ok: AppKit-required initialiser; the controller is built in code, never decoded

    func select(_ pane: SettingsPane) {
        guard let index = SettingsPane.allCases.firstIndex(of: pane) else { return }
        selectedTabViewItemIndex = index
    }

    override func tabView(_ tabView: NSTabView, didSelect tabViewItem: NSTabViewItem?) {
        super.tabView(tabView, didSelect: tabViewItem)
        guard let tabViewItem, let index = tabView.tabViewItems.firstIndex(of: tabViewItem),
            SettingsPane.allCases.indices.contains(index)
        else { return }
        SettingsPane.allCases[index].remember(in: model.env.settings)
    }

    private func item(for pane: SettingsPane) -> NSTabViewItem {
        let host = NSHostingController(rootView: PaneView(pane: pane, model: model))
        host.sizingOptions = [.preferredContentSize]
        let item = NSTabViewItem(viewController: host)
        item.label = pane.title.text
        item.image = NSImage(systemSymbolName: pane.symbolName, accessibilityDescription: pane.title.text)
        item.identifier = pane.rawValue
        return item
    }
}

/// Window subclass for the keys a menu would normally supply: this is a menu-bar app with no main menu.
private final class SettingsWindow: NSWindow {
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

private struct PaneView: View {
    let pane: SettingsPane
    let model: SettingsModel

    var body: some View {
        switch pane {
        case .general: GeneralPane(model: model)
        case .shortcuts: ShortcutsPane(model: model)
        case .triggers: TriggersPane(model: model)
        case .privacy: PrivacyPane(model: model)
        case .storage: StoragePane(model: model)
        case .about: AboutPane(model: model)
        }
    }
}
