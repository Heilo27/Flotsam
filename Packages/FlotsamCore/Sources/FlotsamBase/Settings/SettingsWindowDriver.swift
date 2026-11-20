import Foundation

// The Settings window's decisions (FRD-008 FR-008-03), with no AppKit: there is one window, its panes are in
// `SettingsPane` order, reopening focuses that window on the pane last used, and the window is asked to come to the
// front on every open. The App's `SettingsWindowController` is the glue: it builds the `NSWindow` behind the two ports
// below and forwards each pane the user picks to `paneSelected(_:)`.

/// One toolbar button of the Settings window. `label` is the visible title and also what VoiceOver reads for the
/// button and its icon (FR-008-17), so there is no second string to drift.
public struct SettingsPaneItem: Equatable, Sendable {
    public let pane: SettingsPane
    public let label: String
    public let symbolName: String
}

/// A window the driver has asked for. The App implements it over its `NSWindow`.
@MainActor
public protocol SettingsWindowHandle: AnyObject {
    /// Shows `pane`'s content and marks its toolbar button selected.
    func select(_ pane: SettingsPane)
    /// Makes Flotsam active and the window key and front. Settings is an ordinary window, unlike the Library panel.
    func bringToFront()
}

/// Builds the one window. Called at most once per driver.
@MainActor
public protocol SettingsWindowPresenter: AnyObject {
    /// `didSelect` must be called each time the user (or the window itself) selects a pane.
    func makeWindow(items: [SettingsPaneItem], didSelect: @escaping @MainActor (SettingsPane) -> Void) -> any SettingsWindowHandle
}

@MainActor
public final class SettingsWindowDriver {
    /// The panes in the order the toolbar shows them (FR-008-03): General, Shortcuts, Triggers, Privacy, Storage, About.
    public static let items: [SettingsPaneItem] = SettingsPane.allCases.map {
        SettingsPaneItem(pane: $0, label: $0.title.text, symbolName: $0.symbolName)
    }

    private let settings: SettingsStore
    private var window: (any SettingsWindowHandle)?

    /// Set once by the owner after it is built (the owner is the glue that also builds the window).
    public weak var presenter: (any SettingsWindowPresenter)?

    public init(settings: SettingsStore) {
        self.settings = settings
    }

    /// Every "Open Settings" caller (⌘, from the Library, the menu-bar row; FR-008-03) ends here. The first call
    /// builds the window; every later call reuses it, selects the pane last used and brings it to the front.
    public func open() {
        // Read before the window exists: a window that reports its own initial selection while it is built must not
        // replace the stored pane before it is read.
        let pane = SettingsPane.lastOpened(in: settings)
        guard let handle = window ?? makeWindow() else { return }
        window = handle
        handle.select(pane)
        handle.bringToFront()
    }

    /// The window showed `pane` (a click on its toolbar button, or `select`): reopen there next time (FR-008-03).
    public func paneSelected(_ pane: SettingsPane) {
        pane.remember(in: settings)
    }

    private func makeWindow() -> (any SettingsWindowHandle)? {
        presenter?.makeWindow(items: Self.items) { [weak self] pane in self?.paneSelected(pane) }
    }
}
