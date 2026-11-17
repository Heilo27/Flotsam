import AppKit
import FlotsamBase
import FlotsamLibrary
import FlotsamPaste
import SwiftUI

/// The Library's `NSPanel` (FR-003-01, FR-003-02, FR-003-03). One instance, created once and kept hidden between uses.
/// It owns the view model, records the paste target, runs `captureNow`, places the panel on the pointer's screen, routes
/// key events into the key map, and hides on every trigger the FRD lists. Behaviour lives in `LibraryViewModel`.
@MainActor
final class LibraryPanelController: NSObject, PasteHost, NSWindowDelegate {
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

    let model: LibraryViewModel
    private let hostBox: HostBox
    private let panel: Panel
    private let frontmost: any FrontmostAppProvider
    private let preferences: any LibraryPreferences
    private let captureNow: @MainActor () async -> Void
    private var keyMonitor: Any?
    private var observers: [NSObjectProtocol] = []
    private var isOpening = false

    /// The model needs its host and the host needs the model, so the controller builds the model with itself as host.
    init(
        source: any LibraryDataSource, paster: any PastePerforming, preferences: any LibraryPreferences,
        effects: LibraryEffects, frontmost: any FrontmostAppProvider,
        captureNow: @escaping @MainActor () async -> Void
    ) {
        let hostBox = HostBox()
        model = LibraryViewModel(source: source, paster: paster, host: hostBox, preferences: preferences, effects: effects)
        self.hostBox = hostBox
        self.frontmost = frontmost
        self.preferences = preferences
        self.captureNow = captureNow
        let size = LibraryLayout.clamped(preferences.panelSize)
        panel = Panel(
            contentRect: NSRect(x: 0, y: 0, width: size.width, height: size.height),
            styleMask: [.nonactivatingPanel, .titled, .resizable, .fullSizeContentView],
            backing: .buffered, defer: true)
        super.init()
        hostBox.target = self
        configurePanel()
        observeHideTriggers()
    }

    // MARK: PasteHost

    var isPanelVisible: Bool { panel.isVisible }

    func hidePanel() {
        guard panel.isVisible else { return }
        removeKeyMonitor()
        panel.orderOut(nil)
        model.panelDidHide()
    }

    // MARK: Show and hide

    /// The hotkey and the menu item both call this: it toggles (FR-003-02).
    func toggle() {
        if panel.isVisible { hidePanel() } else { Task { await show() } }
    }

    /// Records the target app, runs `captureNow`, loads the open state, then shows (FR-003-02, FR-003-04).
    func show() async {
        guard !isOpening, !panel.isVisible else { return }
        isOpening = true
        defer { isOpening = false }
        let target = frontmost.frontmost()
        await captureNow()
        await model.open(target: target)
        panel.setFrame(Self.frame(for: preferences.panelSize), display: false)
        installKeyMonitor()
        panel.makeKeyAndOrderFront(nil)
    }

    private static func frame(for size: PanelSize) -> NSRect {
        let pointer = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(pointer) } ?? NSScreen.main ?? NSScreen.screens.first
        let visible = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        return LibraryLayout.frame(in: visible, size: size)
    }

    private func configurePanel() {
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.standardWindowButton(.closeButton)?.isHidden = true
        panel.standardWindowButton(.miniaturizeButton)?.isHidden = true
        panel.standardWindowButton(.zoomButton)?.isHidden = true
        panel.isMovableByWindowBackground = true
        panel.contentMinSize = NSSize(width: LibraryLayout.minimumSize.width, height: LibraryLayout.minimumSize.height)
        panel.setAccessibilityLabel(LibraryText.string(LibraryText.panelTitle))
        panel.delegate = self

        let effect = NSVisualEffectView()
        effect.material = .hudWindow
        effect.blendingMode = .behindWindow
        effect.state = .active
        let hosting = NSHostingView(rootView: LibraryView(model: model))
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
            MainActor.assumeIsolated { self?.hidePanel() }
        })
        observers.append(workspace.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] note in
            let activated = (note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.processIdentifier
            MainActor.assumeIsolated {
                // Flotsam's own activation (the menu bar item) is not "another app came forward".
                if activated != ProcessInfo.processInfo.processIdentifier { self?.hidePanel() }
            }
        })
    }

    func windowDidResignKey(_ notification: Notification) {
        if !isOpening { hidePanel() }
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
        return model.handle(stroke) ? nil : event
    }
}

/// Carries a non-Sendable `NSEvent` across `MainActor.assumeIsolated`; local monitors are always called on the main thread.
private struct Unchecked<Value>: @unchecked Sendable {
    let value: Value
    init(_ value: Value) { self.value = value }
}
