import AppKit
import FlotsamBase
import FlotsamPayload
import FlotsamShelf
import SwiftUI

/// The Shelf's `NSPanel` (FR-006-01, FR-006-03c, FR-006-04, FR-006-05, FR-006-08). One instance, created once and kept
/// hidden between uses. Every show and hide decision is `ShelfRevealMachine`'s: this reports what it sees (the menu
/// item, a Space change, a display change, the Library opening, a paste, a settings change) and acts on the commands
/// that come back. Behaviour of the cards lives in `ShelfModel`.
///
/// Timers (FR-006-17): none while idle. `ShelfRevealDriver` arms one one-shot task for the machine's `nextDeadline` only
/// while it is non-nil; `ShelfHighlightTimer` clears the drop highlight. Both run on the injected `ShelfClock`.
///
/// Drops (FR-006-12 to FR-006-15) arrive through `ShelfDropView`; the controller decides acceptance and hands the
/// pasteboard to `ShelfDropService`.
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
    /// The reveal machine and its one deadline timer, on the injected clock (FR-006-17).
    private let driver: ShelfRevealDriver
    private let highlightTimer: ShelfHighlightTimer
    private var machine: ShelfRevealMachine { driver.machine }
    private var placement: ShelfPlacement
    private var showTask: Task<Void, Never>?
    private var keyMonitor: Any?
    /// Pointer, button and drag monitors (FR-006-03, FR-006-04); `hoverMonitor` only while edge hover is on.
    private var pointerMonitors: [Any] = []
    private var hoverMonitor: Any?
    private var lastRegion: ShelfRevealMachine.Pointer?
    /// The panel's final frame (or where it is sliding to) and the frame of its screen. `panel.frame` is mid-animation or
    /// off-screen right after a reveal, so the pointer is tested against this (`ShelfPointerClassifier`).
    private var shown: (panel: NSRect, screen: NSRect)?
    /// The drag pasteboard's change count at the last mouse-down: a drag is a gesture that changes it (FR-006-03).
    private var dragCountAtMouseDown: Int?
    private var dragDetected = false
    /// An own drag-out session is running (FR-006-03: the Shelf must not hide under it).
    private var ownDragActive = false
    // Touched only in `init` and `deinit`; `NotificationCenter` removal is thread-safe, which is what lets `deinit` (not
    // main-actor isolated) release them.
    private nonisolated(unsafe) var observers: [NSObjectProtocol] = []
    private var unsubscribeSettings: (@Sendable () -> Void)?
    /// Called each time the Shelf is shown, so the app can hide the Library: only one Flotsam panel is open at a time
    /// (FR-006-04). The app owns the rule; the Shelf only announces the reveal.
    var onReveal: (@MainActor () -> Void)?
    /// Carries an accepted drop to storage (FR-006-13). Set by the app once the database is open; nil until then, and
    /// a drop with none set is not taken.
    var dropService: ShelfDropService?
    /// The menu-bar item's frame in screen coordinates: where the `.menuBar` placement is anchored and where a drag
    /// hover reveals it (FR-006-05c, FR-006-03d). Set by the app; nil when there is no item.
    var menuBarIconFrame: (@MainActor () -> CGRect?)?
    /// Drag-out from the cards (FR-006-10). The app supplies its ports once the database is open.
    let dragOut = ShelfDragOut()

    /// The model needs its host and the host needs the model, so the controller builds the model with its box as host.
    /// `makeModel` receives the box and returns the model wired to it.
    init(
        settings: SettingsStore, frontmost: any FrontmostAppProvider,
        thumbnail: @escaping @Sendable (UUID) async -> Data?, clock: any ShelfClock = SystemShelfClock(),
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
            styleMask: ShelfWindowPolicy.windowSpec.styleMask(adding: [.borderless]), backing: .buffered, defer: true)
        hosting = NSHostingView(
            rootView: ShelfView(model: model, placement: placement, thumbnail: thumbnail, dragOut: dragOut, close: {}))
        driver = ShelfRevealDriver(clock: clock)
        highlightTimer = ShelfHighlightTimer(model: model, clock: clock)
        super.init()
        driver.perform = { [weak self] commands in self?.perform(commands) }
        hostBox.target = self
        dragOut.model = model
        // The machine must not hide a Shelf under its own drag (FR-006-03), and an accepted drop hides a transient one
        // (FR-006-11).
        dragOut.onSession = { [weak self] dragging in self?.ownDragSession(dragging) }
        dragOut.onAccepted = { [weak self] in self?.send(.dragOutAccepted) }
        hosting.rootView = makeView()
        configurePanel()
        observeFeeds()
        subscribeToSettings()
        updateMonitors()
        send(.configure(enabled: enabled, placement: placement, revealOnEdgeHover: settings.value(SettingKeys.shelfRevealOnEdgeHover)))
    }

    deinit {
        unsubscribeSettings?()
        // Monitors are removed on the main actor by `updateMonitors` whenever the Shelf is disabled; at teardown the
        // owner (`AppContainer`) lives for the whole process, so there is nothing left to release here.

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

    /// A drop was stored: a transient Shelf stays open for the hold (FR-006-15).
    func dropCompleted() { send(.dropCompleted) }

    private func send(_ event: ShelfRevealMachine.Event) { driver.send(event) }

    private func perform(_ commands: [ShelfRevealMachine.Command]) {
        for command in commands {
            switch command {
            case let .show(trigger, screen): present(trigger: trigger, screen: screen)
            case .hide: dismiss()
            }
        }
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
        // Hides the Library (FR-006-04) and writes the one Info line per reveal (FR-006-18).
        ShelfRevealAnnouncement.announce(trigger, hideLibrary: onReveal)
        let visible = Self.visibleFrame(ofScreenAt: screen)
        let frame = ShelfLayout.frame(
            for: placement, in: visible, contentExtent: contentExtent(), menuBarIcon: menuBarIconFrame?())
        let transition = ShelfLayout.transition(reduceMotion: NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)
        let ordering = ShelfWindowPolicy.ordering(for: trigger.mode)
        panel.allowsKey = ordering == .keyAndFront
        hosting.rootView = makeView()
        shown = (frame, Self.screenFrame(ofScreenAt: screen))
        switch transition.style {
        case .fade:
            panel.setFrame(frame, display: false)
            panel.alphaValue = 0
        case .slide:
            panel.setFrame(ShelfLayout.offscreenFrame(frame, placement: placement, in: visible), display: false)
            panel.alphaValue = 1
        }
        switch ordering {
        case .keyAndFront:
            installKeyMonitor()
            panel.makeKeyAndOrderFront(nil)
        case .frontWithoutKey:
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
        // The machine last heard `.edgeZone` (or the icon) from the dwell that revealed the Shelf. A pointer that has not
        // moved since sits on the panel now, and no further event would say so: tell the machine, or it hides the Shelf
        // 600 ms after it appeared (FR-006-04).
        lastRegion = nil
        reportPointer()
    }

    private func dismiss() {
        showTask?.cancel()
        showTask = nil
        shown = nil
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
                panel.animator().setFrame(ShelfLayout.offscreenFrame(panel.frame, placement: placement, in: visible), display: true)
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
        return ShelfLayout.contentHeight(
            pinnedCount: count(.pinned), recentCount: count(.recent),
            headerHeight: model.showsSearch ? ShelfLayout.searchHeaderHeight(for: placement) : 0)
    }

    // MARK: Screens

    private func pointerScreenIndex() -> Int {
        let pointer = NSEvent.mouseLocation
        return ShelfLayout.screenIndex(containing: pointer, in: NSScreen.screens.map(\.frame)) ?? 0
    }

    private static func visibleFrame(ofScreenAt index: Int) -> NSRect {
        let screens = NSScreen.screens
        let screen = screens.indices.contains(index) ? screens[index] : (NSScreen.main ?? screens.first)
        return screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
    }

    private static func screenFrame(ofScreenAt index: Int) -> NSRect {
        let screens = NSScreen.screens
        let screen = screens.indices.contains(index) ? screens[index] : (NSScreen.main ?? screens.first)
        return screen?.frame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
    }

    private static func visibleFrame(of panel: NSPanel) -> NSRect {
        (panel.screen ?? NSScreen.main)?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
    }

    // MARK: Panel

    private func makeView() -> ShelfView {
        ShelfView(
            model: model, placement: placement, thumbnail: thumbnail, dragOut: dragOut,
            close: { [weak self] in self?.send(.closeButton) })
    }

    private func configurePanel() {
        ShelfWindowPolicy.windowSpec.apply(to: panel)
        panel.isReleasedWhenClosed = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true

        let effect = ShelfDropView()
        effect.delegate = self
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

    // MARK: Drops (FR-006-12 to FR-006-15)

    /// Type identifiers only (FR-006-12, BR-4): no bytes are read until the drop is accepted.
    private func acceptance(of info: any NSDraggingInfo) -> ShelfDropAcceptance {
        ShelfDropPlanner.acceptance(
            types: SystemPasteboard(pasteboard: info.draggingPasteboard).currentTypeIdentifiers(),
            originatesInShelf: originatesInShelf(info))
    }

    /// A drag that began in this Shelf's own cards is refused, silently (FR-006-12).
    private func originatesInShelf(_ info: any NSDraggingInfo) -> Bool {
        info.draggingSource is ShelfDragOut
    }

    /// The card a drop stored or bumped is highlighted for 600 ms and scrolled to the top of Recent (FR-006-15).
    private func highlight(_ itemId: UUID) { highlightTimer.highlight(itemId) }

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
            MainActor.assumeIsolated {
                self?.lastRegion = nil
                self?.send(.screensChanged)
            }
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
        lastRegion = nil
        updateMonitors()
        send(.configure(enabled: enabled, placement: placement, revealOnEdgeHover: settings.value(SettingKeys.shelfRevealOnEdgeHover)))
        // Turning hover off changes the pointer area of a visible top-centre row (the menu-bar strip stops counting), and
        // nothing else would report the pointer that already sits there.
        if machine.isVisible { reportPointer() }
    }

    // MARK: Pointer, button and drag monitors (FR-006-03, FR-006-04)

    /// Monitors exist only while the Shelf is enabled, and the mouse-moved monitor only while edge hover is on
    /// (FR-006-17). They read positions and button state only: no key, no content.
    private func updateMonitors() {
        let wantsHover = enabled && settings.value(SettingKeys.shelfRevealOnEdgeHover)
        if enabled, pointerMonitors.isEmpty { installPointerMonitors() }
        if !enabled { removePointerMonitors() }
        if wantsHover, hoverMonitor == nil {
            hoverMonitor = NSEvent.addGlobalMonitorForEvents(matching: .mouseMoved) { [weak self] _ in
                MainActor.assumeIsolated { self?.reportPointer() }
            }
        } else if !wantsHover, let monitor = hoverMonitor {
            NSEvent.removeMonitor(monitor)
            hoverMonitor = nil
        }
    }

    private func installPointerMonitors() {
        // Nothing was watched while the Shelf was off, so what was last seen is stale; the machine resets its own side
        // on `.configure` (FR-006-03).
        dragCountAtMouseDown = nil
        dragDetected = false
        lastRegion = nil
        let down = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDown) { [weak self] _ in
            MainActor.assumeIsolated { self?.mouseDown(outside: true) }
        }
        let up = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseUp) { [weak self] _ in
            MainActor.assumeIsolated { self?.mouseUp() }
        }
        let dragged = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDragged) { [weak self] _ in
            MainActor.assumeIsolated { self?.mouseDragged() }
        }
        // Global monitors never see events aimed at this app's own windows, so a click in the Library or the Settings
        // window is seen here. A click on the panel or on a menu is not outside.
        let local = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .leftMouseUp]) { [weak self] event in
            let incoming = Unchecked(event)
            MainActor.assumeIsolated {
                guard let self else { return }
                if incoming.value.type == .leftMouseUp { self.mouseUp(); return }
                let window = incoming.value.window
                self.mouseDown(outside: Self.isOutsideClick(in: window, panel: self.panel))
            }
            return event
        }
        pointerMonitors = [down, up, dragged, local].compactMap { $0 }
    }

    private func removePointerMonitors() {
        for monitor in pointerMonitors { NSEvent.removeMonitor(monitor) }
        pointerMonitors = []
        if let hoverMonitor { NSEvent.removeMonitor(hoverMonitor) }
        hoverMonitor = nil
    }

    /// A click is outside when it lands in an ordinary window of this app (Library, Settings) other than the panel.
    /// App-owned auxiliary windows are not: the status item (status-bar level), alerts and their sheets (modal level
    /// and above), menus and the error HUD. Clicking "Toggle Shelf" in the menu-bar item or answering the delete
    /// confirmation must not hide the Shelf (FR-006-04).
    private static func isOutsideClick(in window: NSWindow?, panel: NSWindow) -> Bool {
        guard let window else { return true }
        if window === panel || window.isSheet || window.sheetParent != nil { return false }
        return window.level < .modalPanel
    }

    private func mouseDown(outside: Bool) {
        dragCountAtMouseDown = SystemPasteboard(pasteboard: NSPasteboard(name: .drag)).changeCount
        dragDetected = false
        send(.buttonDown(true))
        if outside, machine.isVisible { send(.clickOutside) }
    }

    private func mouseUp() { gestureEnded() }

    /// The button is up and any drag it began is over, however the end reached us: the global mouse-up monitor, a drop
    /// on the panel, or the destination's `draggingEnded` (a drag from another app that was refused, cancelled with Esc
    /// or dropped elsewhere, whose mouse-up the monitors never see). One place, so the machine's `isDragging` and
    /// `isButtonDown` cannot be left set by whichever path misses.
    private func gestureEnded() {
        dragCountAtMouseDown = nil
        dragGestureEnded()
        send(.buttonDown(false))
        reportPointer()
    }

    /// A drag gesture is over, possibly without a mouse-up having reached the global monitor (a drop on the Shelf, or a
    /// drag from another app that ended elsewhere). The machine must not keep hearing "dragging", or a transient Shelf
    /// never hides. An own drag-out is not ended here: the panel is a drop destination too, and the session ends through
    /// `ownDragSession`.
    private func dragGestureEnded() {
        guard !ownDragActive else { return }
        dragDetected = false
        send(.dragging(false))
    }

    /// An own drag-out began or ended. The session swallows its mouse-up, so the end also releases the button the
    /// machine still holds as down, which would otherwise block hover reveal (FR-006-03b).
    private func ownDragSession(_ dragging: Bool) {
        ownDragActive = dragging
        if dragging {
            send(.dragging(true))
            return
        }
        gestureEnded()
    }

    /// A drag is a pressed button plus a change to the drag pasteboard since the press; plain window drags and text
    /// selections never change it.
    private func mouseDragged() {
        if !dragDetected, let start = dragCountAtMouseDown,
            SystemPasteboard(pasteboard: NSPasteboard(name: .drag)).changeCount != start
        {
            dragDetected = true
            send(.dragging(true))
        }
        reportPointer()
    }

    /// Reports where the pointer is, only when that changed: the machine and its timer see one event per region.
    private func reportPointer() {
        let region = currentRegion()
        guard region != lastRegion else { return }
        lastRegion = region
        send(.pointer(region))
    }

    private func currentRegion() -> ShelfRevealMachine.Pointer {
        ShelfPointerClassifier.region(
            at: NSEvent.mouseLocation, placement: placement, isVisible: machine.isVisible,
            panelFrame: shown?.panel ?? panel.frame, screenFrame: shown?.screen, hoverMonitored: hoverMonitor != nil,
            screens: NSScreen.screens.map(\.frame), menuBarIcon: menuBarIconFrame?())
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
        // An input method composing text owns every key until it commits.
        if let editor = panel.firstResponder as? NSTextView, editor.hasMarkedText() { return event }
        guard let stroke = LibraryKeyTranslator.stroke(for: event) else { return event }
        // Esc first clears the search, then the type filter; with neither it hides the Shelf (FR-006-04, FR-006-22).
        // The machine owns the hide decision.
        if stroke == KeyStroke(.escape) {
            if !model.clearSearchState() { send(.escape) }
            return nil
        }
        // ⌘C copies the field's own selected text, not the card, when there is one (FR-006-22).
        let selectionLength = (panel.firstResponder as? NSTextView)?.selectedRange().length ?? 0
        return model.handle(stroke, searchHasSelection: selectionLength > 0) ? nil : event
    }
}

extension ShelfPanelController: ShelfDropDelegate {
    func shelfDragUpdated(_ info: any NSDraggingInfo) -> NSDragOperation {
        reportPointer()
        let accepted = acceptance(of: info) == .accepted
        model.setDropTargeted(accepted)
        return accepted ? .copy : []
    }

    /// The drag left the panel but is still going, so it is not ended here: sending `.dragging(false)` would start the
    /// 600 ms hide clock under a drag the person is still holding. A drag that ends outside the panel ends through
    /// `shelfDragEnded` (or the mouse-up monitor).
    func shelfDragExited() {
        model.setDropTargeted(false)
        reportPointer()
    }

    func shelfDragEnded() {
        model.setDropTargeted(false)
        gestureEnded()
    }

    /// Reads the bytes now (they are only valid during the drag) and stores them asynchronously. The result is not the
    /// operation's: AppKit is told the drop was taken, and a failure reaches the user as the HUD the service reports.
    func shelfPerformDrop(_ info: any NSDraggingInfo) -> Bool {
        model.setDropTargeted(false)
        // The drop ends the gesture, and the mouse-up that follows may never reach the global monitor.
        gestureEnded()
        guard let dropService else { return false }
        let pasteboard = SystemPasteboard(pasteboard: info.draggingPasteboard)
        let types = pasteboard.currentTypeIdentifiers()
        let inShelf = originatesInShelf(info)
        var representations: [PasteboardRepresentation] = []
        if !inShelf, case .success(let snapshot) = pasteboard.readSnapshot(types: PasteboardTypes.typesToRead(from: types)) {
            representations = snapshot.representations
        }
        // FR-006-13: the source is the frontmost app at drop time. Capture mode and the ignored-apps list do not apply
        // (an explicit drop is an explicit save); the capture classifier's never-store gates still do.
        let source = SystemSourceApps().frontmostApp()
        Task { [weak self] in
            let result = await dropService.drop(
                types: types, representations: representations, source: source, originatesInShelf: inShelf,
                occurredAt: Date())
            if case .stored(let itemId, _) = result { self?.highlight(itemId) }
        }
        return true
    }

    func shelfPointerMoved() { reportPointer() }
}
