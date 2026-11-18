import AppKit
import FlotsamBase
import FlotsamShelf
import SwiftUI

/// The Shelf's `NSPanel` (FR-006-01, FR-006-03c, FR-006-04, FR-006-05, FR-006-08). One instance, created once and kept
/// hidden between uses. Every show and hide decision is `ShelfRevealMachine`'s: this reports what it sees (the menu
/// item, a Space change, a display change, the Library opening, a paste, a settings change) and acts on the commands
/// that come back. Behaviour of the cards lives in `ShelfModel`.
///
/// Timers (FR-006-17): none while idle. The machine exposes `nextDeadline`; one one-shot task is armed for it only
/// while it is non-nil and cancelled and re-armed after every event.
///
/// Not wired yet: the global drag and pointer monitors (drag and hover reveal, click outside a transient Shelf) and
/// drop-in and drag-out (FRD-006 section 9, item 8).
@MainActor
final class ShelfPanelController: NSObject, ShelfPasteHost {
    /// A panel that never activates the app (FR-006-08) and takes key only while the Shelf is sticky.
    private final class Panel: NSPanel {
        var allowsKey = false
        override var canBecomeKey: Bool { allowsKey }
        override var canBecomeMain: Bool { false }
    }

    /// Forwards `ShelfPasteHost` to the controller once it exists (the model is built before `super.init`).
    @MainActor
    final class HostBox: ShelfPasteHost {
        weak var target: ShelfPanelController?
        var isPanelVisible: Bool { target?.isPanelVisible ?? false }
        func hidePanel() { target?.hidePanel() }
    }

    let model: ShelfModel
    private let hostBox: HostBox
    private let panel: Panel
    private let hosting: NSHostingView<ShelfView>
    private let frontmost: any FrontmostAppProvider
    private let settings: SettingsStore
    private let thumbnail: @Sendable (UUID) async -> Data?
    private var machine = ShelfRevealMachine()
    private var placement: ShelfPlacement
    private var deadlineTask: Task<Void, Never>?
    private var showTask: Task<Void, Never>?
    private var keyMonitor: Any?
    // Touched only in `init` and `deinit`; `NotificationCenter` removal is thread-safe, which is what lets `deinit` (not
    // main-actor isolated on the macOS 14 target) release them.
    private nonisolated(unsafe) var observers: [NSObjectProtocol] = []
    private var unsubscribeSettings: (@Sendable () -> Void)?
    /// Called each time the Shelf is shown, so the app can hide the Library: only one Flotsam panel is open at a time
    /// (FR-006-04). The app owns the rule; the Shelf only announces the reveal.
    var onReveal: (@MainActor () -> Void)?

    /// The model needs its host and the host needs the model, so the controller builds the model with its box as host.
    /// `makeModel` receives the box and returns the model wired to it.
    init(
        settings: SettingsStore, frontmost: any FrontmostAppProvider,
        thumbnail: @escaping @Sendable (UUID) async -> Data?,
        makeModel: (HostBox) -> ShelfModel
    ) {
        let hostBox = HostBox()
        let model = makeModel(hostBox)
        self.model = model
        self.hostBox = hostBox
        self.settings = settings
        self.frontmost = frontmost
        self.thumbnail = thumbnail
        let placement = settings.value(SettingKeys.shelfPlacement)
        self.placement = placement
        panel = Panel(
            contentRect: NSRect(x: 0, y: 0, width: ShelfLayout.panelWidth, height: ShelfLayout.minimumHeight),
            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        hosting = NSHostingView(
            rootView: ShelfView(model: model, placement: placement, thumbnail: thumbnail, close: {}))
        super.init()
        hostBox.target = self
        hosting.rootView = makeView()
        configurePanel()
        observeFeeds()
        subscribeToSettings()
        send(.configure(enabled: enabled, placement: placement, revealOnEdgeHover: settings.value(SettingKeys.shelfRevealOnEdgeHover)))
    }

    deinit {
        unsubscribeSettings?()
        let workspace = NSWorkspace.shared.notificationCenter
        for observer in observers {
            workspace.removeObserver(observer)
            NotificationCenter.default.removeObserver(observer)
        }
    }

    // MARK: ShelfPasteHost

    var isPanelVisible: Bool { panel.isVisible }

    /// The model's Esc and every finished paste hide the panel through here. The machine owns the visible state, so the
    /// hide is reported to it and the panel follows the command it returns.
    func hidePanel() { send(.pasted) }

    // MARK: Events in

    /// The menu item and the hotkey call this: it toggles (FR-006-03c, FR-006-04).
    func toggle(_ trigger: ShelfTrigger = .menuItem) {
        send(.toggle(trigger, screen: pointerScreenIndex()))
    }

    /// The Library opened: only one Flotsam panel is open at a time (FR-006-04).
    func libraryOpened() { send(.libraryOpened) }

    private func send(_ event: ShelfRevealMachine.Event) {
        let commands = machine.send(event, at: Date())
        perform(commands)
        armDeadline()
    }

    private func perform(_ commands: [ShelfRevealMachine.Command]) {
        for command in commands {
            switch command {
            case let .show(trigger, screen): present(trigger: trigger, screen: screen)
            case .hide: dismiss()
            }
        }
    }

    /// One one-shot task for the machine's next deadline, and none when it is idle (FR-006-17).
    private func armDeadline() {
        deadlineTask?.cancel()
        deadlineTask = nil
        guard let deadline = machine.nextDeadline else { return }
        let delay = max(deadline.timeIntervalSinceNow, 0)
        deadlineTask = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(delay)) } catch { return }
            self?.deadlineReached()
        }
    }

    private func deadlineReached() {
        deadlineTask = nil
        perform(machine.advance(to: Date()))
        armDeadline()
    }

    // MARK: Show and hide

    private func present(trigger: ShelfTrigger, screen: Int) {
        showTask?.cancel()
        let target = frontmost.frontmost()
        let sticky = trigger.mode == .sticky
        // From the trigger to the panel fully visible with content (FR-006-17).
        let span = Signposts.begin(.shelfReveal)
        showTask = Task { [weak self] in
            guard let self else { span.end(); return }
            await model.open(target: target, sticky: sticky)
            // A hide that arrived while the sections loaded wins.
            guard !Task.isCancelled, machine.isVisible else { span.end(); return }
            reveal(trigger: trigger, screen: screen, sticky: sticky, span: span)
        }
    }

    private func reveal(trigger: ShelfTrigger, screen: Int, sticky: Bool, span: PerfSpan) {
        onReveal?()
        // One Info line per reveal: the trigger type only, never a clip, file or app name (FR-006-18).
        FlotsamLog.log(.shelf(.reveal, outcome: .revealed, detail: .trigger(trigger)))
        let visible = Self.visibleFrame(ofScreenAt: screen)
        let frame = ShelfLayout.frame(for: placement, in: visible, contentExtent: contentExtent())
        let transition = ShelfLayout.transition(reduceMotion: NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)
        panel.allowsKey = sticky
        hosting.rootView = makeView()
        switch transition.style {
        case .fade:
            panel.setFrame(frame, display: false)
            panel.alphaValue = 0
        case .slide:
            panel.setFrame(Self.offscreen(frame, placement: placement, in: visible), display: false)
            panel.alphaValue = 1
        }
        if sticky {
            installKeyMonitor()
            panel.makeKeyAndOrderFront(nil)
        } else {
            panel.orderFrontRegardless()
        }
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = transition.showDuration
            switch transition.style {
            case .fade: panel.animator().alphaValue = 1
            case .slide: panel.animator().setFrame(frame, display: true)
            }
        }, completionHandler: {
            span.end()
        })
    }

    private func dismiss() {
        showTask?.cancel()
        showTask = nil
        removeKeyMonitor()
        model.didHide()
        guard panel.isVisible else { return }
        let transition = ShelfLayout.transition(reduceMotion: NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = transition.hideDuration
            switch transition.style {
            case .fade: panel.animator().alphaValue = 0
            case .slide:
                let visible = Self.visibleFrame(of: panel)
                panel.animator().setFrame(Self.offscreen(panel.frame, placement: placement, in: visible), display: true)
            }
        }, completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                // A show that began during the animation owns the panel now.
                guard let self, !self.machine.isVisible else { return }
                self.panel.orderOut(nil)
                self.panel.alphaValue = 1
            }
        })
    }

    private func contentExtent() -> CGFloat {
        let sections = model.sections()
        if ShelfLayout.isHorizontal(placement) {
            return ShelfLayout.contentWidth(itemCount: sections.reduce(0) { $0 + $1.cards.count })
        }
        func count(_ kind: ShelfSection.Kind) -> Int { sections.first { $0.kind == kind }?.cards.count ?? 0 }
        return ShelfLayout.contentHeight(pinnedCount: count(.pinned), recentCount: count(.recent))
    }

    /// `frame` moved out past its own edge, where a slide starts and ends.
    private static func offscreen(_ frame: NSRect, placement: ShelfPlacement, in visible: NSRect) -> NSRect {
        var moved = frame
        switch placement {
        case .rightEdge: moved.origin.x = visible.maxX
        case .leftEdge: moved.origin.x = visible.minX - frame.width
        case .bottomEdge: moved.origin.y = visible.minY - frame.height
        case .menuBar: moved.origin.y = visible.maxY
        }
        return moved
    }

    // MARK: Screens

    private func pointerScreenIndex() -> Int {
        let pointer = NSEvent.mouseLocation
        return NSScreen.screens.firstIndex { $0.frame.contains(pointer) } ?? 0
    }

    private static func visibleFrame(ofScreenAt index: Int) -> NSRect {
        let screens = NSScreen.screens
        let screen = screens.indices.contains(index) ? screens[index] : (NSScreen.main ?? screens.first)
        return screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
    }

    private static func visibleFrame(of panel: NSPanel) -> NSRect {
        (panel.screen ?? NSScreen.main)?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
    }

    // MARK: Panel

    private func makeView() -> ShelfView {
        ShelfView(model: model, placement: placement, thumbnail: thumbnail, close: { [weak self] in self?.send(.closeButton) })
    }

    private func configurePanel() {
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true

        let effect = NSVisualEffectView()
        effect.material = .hudWindow
        effect.blendingMode = .behindWindow
        effect.state = .active
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

    // MARK: Feeds

    /// A Space change and a display change hide the Shelf (FR-006-04, FR-006-20).
    private func observeFeeds() {
        let workspace = NSWorkspace.shared.notificationCenter
        observers.append(workspace.addObserver(forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.send(.spaceChanged) }
        })
        observers.append(NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.send(.screensChanged) }
        })
    }

    private var enabled: Bool { settings.value(SettingKeys.shelfEnabled) }

    /// Turning the Shelf off or changing its placement hides it (FR-006-01, FR-006-04); the machine does that on
    /// `.configure`. Settings notify on any thread, so the change hops to the main actor.
    private func subscribeToSettings() {
        let watched: Set<String> = [
            SettingKeys.shelfEnabled.name, SettingKeys.shelfPlacement.name, SettingKeys.shelfRevealOnEdgeHover.name,
        ]
        unsubscribeSettings = settings.subscribe { [weak self] change in
            guard watched.contains(change.name) else { return }
            Task { @MainActor in self?.applySettings() }
        }
    }

    private func applySettings() {
        placement = settings.value(SettingKeys.shelfPlacement)
        hosting.rootView = makeView()
        send(.configure(enabled: enabled, placement: placement, revealOnEdgeHover: settings.value(SettingKeys.shelfRevealOnEdgeHover)))
    }

    // MARK: Keys (sticky only, FR-006-08)

    /// Installed only while a sticky Shelf is visible, and only keys aimed at the panel are looked at; a transient
    /// Shelf and a hidden one never see a key (FR-006-03: no key events are monitored otherwise).
    private func installKeyMonitor() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let incoming = Unchecked(event)
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

    /// Returns nil when the Shelf consumed the key.
    private func handle(_ event: NSEvent) -> NSEvent? {
        guard event.window === panel, machine.canBecomeKey else { return event }
        guard let stroke = LibraryKeyTranslator.stroke(for: event) else { return event }
        return model.handle(stroke) ? nil : event
    }
}
