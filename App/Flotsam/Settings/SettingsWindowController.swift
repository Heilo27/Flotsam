import AppKit
import FlotsamBase
import SwiftUI

/// The Settings window (FR-008-03): one window, a toolbar of panes in `SettingsPane` order, reopening on the last pane.
/// Every control applies at once, so closing discards nothing; ⌘W and Escape close it. The decisions (one window, pane
/// order, reopen on the last pane, front on every open) are `SettingsWindowDriver`'s; this builds the `NSWindow` for it.
@MainActor
final class SettingsWindowController: SettingsWindowPresenter {
    private let model: SettingsModel
    private let driver: SettingsWindowDriver

    init(env: SettingsEnvironment) {
        model = SettingsModel(env: env)
        driver = SettingsWindowDriver(settings: env.settings)
        driver.presenter = self
    }

    /// Opens the window, or focuses it when it is already open, on the pane last used. Every "Open Settings" caller
    /// (the menu-bar item, a Notice or alert action, ⌘, from the Library) calls this one method.
    func openSettings() { driver.open() }

    func makeWindow(items: [SettingsPaneItem], didSelect: @escaping @MainActor (SettingsPane) -> Void) -> any SettingsWindowHandle {
        let tabs = SettingsTabViewController(model: model, items: items, didSelect: didSelect)
        // A window titled from its content controller shows "Untitled" while that controller has no title, so both carry it.
        tabs.title = SettingsString.window.text
        let window = SettingsWindow(contentViewController: tabs)
        window.title = SettingsString.window.text
        window.styleMask = [.titled, .closable, .miniaturizable]
        window.isReleasedWhenClosed = false
        window.setFrameAutosaveName("")
        window.center()
        return SettingsWindowHandleAppKit(window: window, tabs: tabs)
    }
}

/// The driver's view of the `NSWindow`.
@MainActor
private final class SettingsWindowHandleAppKit: SettingsWindowHandle {
    private let window: NSWindow
    private let tabs: SettingsTabViewController

    init(window: NSWindow, tabs: SettingsTabViewController) {
        self.window = window
        self.tabs = tabs
    }

    func select(_ pane: SettingsPane) { tabs.select(pane) }

    func bringToFront() {
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
    }
}

/// A toolbar-style tab controller with one hosting controller per pane. A pane's size is its SwiftUI content's size,
/// so the window resizes as the user switches panes.
@MainActor
private final class SettingsTabViewController: NSTabViewController {
    private let model: SettingsModel
    private let items: [SettingsPaneItem]
    private let didSelect: @MainActor (SettingsPane) -> Void

    init(model: SettingsModel, items: [SettingsPaneItem], didSelect: @escaping @MainActor (SettingsPane) -> Void) {
        self.model = model
        self.items = items
        self.didSelect = didSelect
        super.init(nibName: nil, bundle: nil)
        tabStyle = .toolbar
        for item in items { addTabViewItem(tabItem(for: item)) }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("SettingsTabViewController is not decoded from a nib") } // fatal-ok: AppKit-required initialiser; the controller is built in code, never decoded

    func select(_ pane: SettingsPane) {
        guard let index = items.firstIndex(where: { $0.pane == pane }) else { return }
        selectedTabViewItemIndex = index
    }

    override func tabView(_ tabView: NSTabView, didSelect tabViewItem: NSTabViewItem?) {
        super.tabView(tabView, didSelect: tabViewItem)
        guard let tabViewItem, let index = tabView.tabViewItems.firstIndex(of: tabViewItem), items.indices.contains(index)
        else { return }
        didSelect(items[index].pane)
    }

    private func tabItem(for item: SettingsPaneItem) -> NSTabViewItem {
        let host = NSHostingController(rootView: PaneView(pane: item.pane, model: model))
        host.sizingOptions = [.preferredContentSize]
        let tab = NSTabViewItem(viewController: host)
        tab.label = item.label
        tab.image = NSImage(systemSymbolName: item.symbolName, accessibilityDescription: item.label)
        tab.identifier = item.pane.rawValue
        return tab
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
