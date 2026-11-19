import AppKit
import FlotsamBase
import FlotsamLibrary
import FlotsamPaste
import SwiftUI

/// The Library's `NSPanel` (FR-003-01, FR-003-02, FR-003-03). One instance, created once and kept hidden between uses.
/// It owns the view model and the window. What to do on each hotkey press and system event (toggle, record the paste
/// target, run `captureNow`, pick the pointer's screen, hide on every trigger the FRD lists) is `LibraryPanelDriver`'s,
/// in FlotsamLibrary, where it is tested; this class adapts the screens and the `NSPanel` to the driver's ports and
/// routes key events into the key map. Behaviour of the list lives in `LibraryViewModel`.
@MainActor
final class LibraryPanelController: NSObject, PasteHost, NSWindowDelegate, LibraryPanelPresenter {
    /// A key-capable panel that never activates the app (FR-003-01): the previous app stays frontmost.
    private final class Panel: NSPanel {
        override var canBecomeKey: Bool { true }
        override var canBecomeMain: Bool { false }
    }

    /// Forwards `PasteHost` to the controller once it exists (it cannot be passed to the model before `super.init`).
    @MainActor
    private final class HostBox: PasteHost {
        weak var target: LibraryPanelController?
        var isPanelVisible: Bool { target?.isPanelVisible ?? false }
        func hidePanel() { target?.hidePanel() }
    }

    /// `NSEvent.mouseLocation` and `NSScreen`, as the driver's `LibraryScreenProvider`.
    private struct SystemScreens: LibraryScreenProvider {
        var pointerLocation: CGPoint { NSEvent.mouseLocation }
        var screens: [LibraryScreen] { NSScreen.screens.map(Self.snapshot) }
        var mainScreen: LibraryScreen? { (NSScreen.main ?? NSScreen.screens.first).map(Self.snapshot) }
        private static func snapshot(_ screen: NSScreen) -> LibraryScreen {
            LibraryScreen(frame: screen.frame, visibleFrame: screen.visibleFrame)
        }
    }

    let model: LibraryViewModel
    private let driver: LibraryPanelDriver
    private let organize: OrganizeCoordinator
    private let hostBox: HostBox
    private let panel: Panel
    private let preferences: any LibraryPreferences
    private var keyMonitor: Any?
    private var observers: [NSObjectProtocol] = []

    /// The model needs its host and the host needs the model, so the controller builds the model with itself as host.
    init(
        source: any LibraryDataSource, paster: any PastePerforming, preferences: any LibraryPreferences,
        effects: LibraryEffects, organizer: LibraryOrganizer, organize: OrganizeCoordinator,
        frontmost: any FrontmostAppProvider, events: ItemEventBus, captureNow: @escaping @MainActor () async -> Void
    ) {
        let hostBox = HostBox()
        model = LibraryViewModel(
            source: source, paster: paster, host: hostBox, preferences: preferences, effects: effects, organizer: organizer,
            events: events)
        organize.model = model
        self.organize = organize
        self.hostBox = hostBox
        self.preferences = preferences
        driver = LibraryPanelDriver(
            model: model, frontmost: frontmost, screens: SystemScreens(), preferences: preferences, captureNow: captureNow)
        let size = LibraryLayout.clamped(preferences.panelSize)
        panel = Panel(
            contentRect: NSRect(x: 0, y: 0, width: size.width, height: size.height),
            styleMask: LibraryPanelDriver.windowSpec.styleMask(adding: [.titled, .fullSizeContentView]),
            backing: .buffered, defer: true)
        super.init()
        driver.presenter = self
        hostBox.target = self
        configurePanel()
        observeHideTriggers()
    }

    // MARK: PasteHost

    var isPanelVisible: Bool { driver.isPanelVisible }

    func hidePanel() { driver.hidePanel() }

    // MARK: Show and hide

    /// The hotkey and the menu item both call this: it toggles (FR-003-02).
    func toggle() { driver.toggle() }

    func show() async { await driver.show() }

    // MARK: LibraryPanelPresenter

    var isVisible: Bool { panel.isVisible }

    func show(at frame: CGRect) {
        panel.setFrame(frame, display: false)
        installKeyMonitor()
        panel.makeKeyAndOrderFront(nil)
    }

    func hide() {
        removeKeyMonitor()
        organize.close()
        panel.orderOut(nil)
    }

    private func configurePanel() {
        LibraryPanelDriver.windowSpec.apply(to: panel)
        panel.isReleasedWhenClosed = false
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.standardWindowButton(.closeButton)?.isHidden = true
        panel.standardWindowButton(.miniaturizeButton)?.isHidden = true
        panel.standardWindowButton(.zoomButton)?.isHidden = true
        panel.contentMinSize = NSSize(width: LibraryLayout.minimumSize.width, height: LibraryLayout.minimumSize.height)
        panel.setAccessibilityLabel(LibraryText.string(LibraryText.panelTitle))
        panel.delegate = self

        let effect = NSVisualEffectView()
        effect.material = .hudWindow
        effect.blendingMode = .behindWindow
        effect.state = .active
        let hosting = NSHostingView(rootView: LibraryView(model: model, organize: organize))
        hosting.translatesAutoresizingMaskIntoConstraints = false
        effect.addSubview(hosting)
        NSLayoutConstraint.activate([
            hosting.leadingAnchor.constraint(equalTo: effect.leadingAnchor),
            hosting.trailingAnchor.constraint(equalTo: effect.trailingAnchor),
            hosting.topAnchor.constraint(equalTo: effect.topAnchor),
            hosting.bottomAnchor.constraint(equalTo: effect.bottomAnchor),
        ])
        panel.contentView = effect
    }

    // MARK: Hide triggers

    /// Click outside (the panel resigns key), a Space change, or another app becoming frontmost (FR-003-02).
    private func observeHideTriggers() {
        let workspace = NSWorkspace.shared.notificationCenter
        observers.append(workspace.addObserver(forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.driver.activeSpaceChanged() }
        })
        observers.append(workspace.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] note in
            let activated = (note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.processIdentifier
            MainActor.assumeIsolated {
                self?.driver.applicationActivated(processId: activated, ownProcessId: ProcessInfo.processInfo.processIdentifier)
            }
        })
    }

    func windowDidResignKey(_ notification: Notification) {
        driver.panelResignedKey()
    }

    /// The size is remembered when a live resize ends (FR-003-03).
    func windowDidEndLiveResize(_ notification: Notification) {
        let size = panel.frame.size
        preferences.panelSize = PanelSize(width: size.width, height: size.height)
    }

    // MARK: Keys

    /// A local monitor sees keys before the search field, so a key the map owns never reaches it and everything else
    /// falls through to the field (FR-003-08).
    private func installKeyMonitor() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            // Local monitors run on the main thread; NSEvent is not Sendable, so it crosses the isolation hop in a box.
            let incoming = Unchecked(event)
            // nil means the Library consumed the key; a released controller lets the event through.
            return MainActor.assumeIsolated {
                guard let self else { return Unchecked<NSEvent?>(incoming.value) }
                return Unchecked(self.handle(incoming.value))
            }.value
        }
    }

    private func removeKeyMonitor() {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
    }

    /// Returns nil when the Library consumed the key.
    private func handle(_ event: NSEvent) -> NSEvent? {
        guard event.window === panel else { return event }
        // An input method composing text owns every key until it commits.
        if let editor = panel.firstResponder as? NSTextView, editor.hasMarkedText() { return event }
        guard let stroke = LibraryKeyTranslator.stroke(for: event) else { return event }
        // The routing order lives in FlotsamLibrary (tested there): overlay first, then the key map, then the field.
        // ⌘C copies the field's own selected text, not the row, when there is one (FR-003-08).
        let selectionLength = (panel.firstResponder as? NSTextView)?.selectedRange().length ?? 0
        switch LibraryKeyRouting.route(
            stroke, overlayIsOpen: organize.isOverlayOpen, context: model.keyContext(searchHasSelection: selectionLength > 0))
        {
        case .overlay: return organize.handle(stroke) ? nil : event
        case .library(let command):
            model.perform(command)
            return nil
        case .passToField: return event
        }
    }
}

/// Carries a non-Sendable `NSEvent` across `MainActor.assumeIsolated`; local monitors are always called on the main thread.
/// Shared with the Shelf's key monitor.
struct Unchecked<Value>: @unchecked Sendable {
    let value: Value
    init(_ value: Value) { self.value = value }
}
