import FlotsamBase
import FlotsamPaste
import Foundation

// The Library panel's show and hide decisions (FRD-003 FR-003-01, FR-003-02, FR-003-03), with no AppKit. The App's
// `LibraryPanelController` is the glue: it owns the `NSPanel` and its key monitor, adapts the three ports below, and
// forwards every system event (hotkey, Space change, app activation, resign key) to this driver.

/// Where the pointer and the displays are right now. The App adapts `NSEvent.mouseLocation` and `NSScreen`.
@MainActor
public protocol LibraryScreenProvider {
    var pointerLocation: CGPoint { get }
    var screens: [LibraryScreen] { get }
    /// The main screen, else the first; nil when the system reports none.
    var mainScreen: LibraryScreen? { get }
    /// The centre of the topmost window of process `processId`, in AppKit coordinates; nil when it has none on screen.
    /// Used when the Library opens with the focused window's display (`library.display`).
    func focusedWindowCenter(ofProcess processId: Int32) -> CGPoint?
}

extension LibraryScreenProvider {
    public func focusedWindowCenter(ofProcess processId: Int32) -> CGPoint? { nil }
}

/// The window the driver shows and hides. There is deliberately no "activate the app" member: the Library never makes
/// Flotsam the active application (FR-003-01), so the previously active app stays frontmost.
@MainActor
public protocol LibraryPanelPresenter: AnyObject {
    var isVisible: Bool { get }
    /// Places the panel at `frame` (not animated) with `minimumSize` as its smallest resize, starts watching keys, and
    /// makes it key and front.
    func show(at frame: CGRect, minimumSize: PanelSize)
    /// Stops watching keys, closes any organize overlay, and orders the panel out.
    func hide()
}

@MainActor
public final class LibraryPanelDriver: PasteHost {
    /// The Library window (FR-003-01): non-activating, floating, all Spaces, over full-screen apps; resizable and
    /// movable by its background (FR-003-03).
    public static let windowSpec = PanelWindowSpec(
        isNonActivating: true, isFloating: true, joinsAllSpaces: true, isFullScreenAuxiliary: true,
        ignoresWindowCycling: false, hidesOnDeactivate: false, isResizable: true, isMovableByBackground: true)

    private let model: LibraryViewModel
    private let frontmost: any FrontmostAppProvider
    private let screens: any LibraryScreenProvider
    private let preferences: any LibraryPreferences
    private let captureNow: @MainActor () async -> Void
    private var isOpening = false

    /// The latest show started by `toggle()`, kept so tests can await it.
    public private(set) var showTask: Task<Void, Never>?

    /// Set once by the owner after it is built (the owner is the window, which also hosts this driver).
    public weak var presenter: (any LibraryPanelPresenter)?

    public init(
        model: LibraryViewModel, frontmost: any FrontmostAppProvider, screens: any LibraryScreenProvider,
        preferences: any LibraryPreferences, captureNow: @escaping @MainActor () async -> Void
    ) {
        self.model = model
        self.frontmost = frontmost
        self.screens = screens
        self.preferences = preferences
        self.captureNow = captureNow
    }

    // MARK: PasteHost

    public var isPanelVisible: Bool { presenter?.isVisible ?? false }

    public func hidePanel() {
        guard isPanelVisible else { return }
        presenter?.hide()
        model.panelDidHide()
    }

    // MARK: Show and hide

    /// The hotkey and the menu item both call this: it toggles (FR-003-02).
    public func toggle() {
        if isPanelVisible { hidePanel() } else { showTask = Task { await show() } }
    }

    /// Records the target app, runs `captureNow`, loads the open state, then shows (FR-003-02, FR-003-04). The target is
    /// read before `captureNow`, so it is the app that was frontmost when the hotkey was pressed; the screen is read
    /// after the open state loads, so it is the pointer's screen at the moment the panel appears (FR-003-03).
    public func show() async {
        guard !isOpening, !isPanelVisible else { return }
        isOpening = true
        defer { isOpening = false }
        let target = frontmost.frontmost()
        await captureNow()
        await model.open(target: target)
        // The layout the model just loaded, so the frame, the minimum and the columns drawn cannot disagree (FR-003-06).
        let layout = model.layout
        let size = preferences.previewPreset.openingSize(from: preferences.panelSize(for: layout), in: layout)
        presenter?.show(
            at: frame(for: size, layout: layout, target: target), minimumSize: LibraryLayout.minimumSize(for: layout))
    }

    /// The panel's frame on the screen it opens on (FR-003-03): the pointer's, or with `library.display` set to focus,
    /// the one holding the target app's focused window, falling back to the pointer's when that app has none.
    public func frame(for size: PanelSize, layout: LibraryLayoutMode = .standard, target: FrontmostApp? = nil) -> CGRect {
        var anchor = screens.pointerLocation
        if preferences.display == .focus, let target, let center = screens.focusedWindowCenter(ofProcess: target.processId) {
            anchor = center
        }
        let screen = LibraryLayout.screen(containing: anchor, in: screens.screens, main: screens.mainScreen)
        return LibraryLayout.frame(in: screen?.visibleFrame ?? LibraryLayout.fallbackVisibleFrame, size: size, layout: layout)
    }

    // MARK: Hide triggers (FR-003-02)

    /// The active Space changed.
    public func activeSpaceChanged() { hidePanel() }

    /// Another application became frontmost. Flotsam's own activation (the menu bar item) is not "another app came
    /// forward"; an activation with no readable process id counts as another app.
    public func applicationActivated(processId: Int32?, ownProcessId: Int32) {
        if processId != ownProcessId { hidePanel() }
    }

    /// The panel resigned key (a click outside). Ignored while the panel is still opening, when key moves as it appears.
    public func panelResignedKey() {
        if !isOpening { hidePanel() }
    }
}
