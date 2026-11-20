#if DEBUG
import AppKit
import FlotsamBase
import FlotsamLibrary
import FlotsamStorage
import Foundation

/// Screenshot staging (bin/shots.sh, docs/SCREENSHOTS.md). Debug builds only: the whole file is behind `#if DEBUG`, so a
/// Release binary contains none of it.
///
/// One launch stages one surface in one appearance. The script passes three environment variables:
/// `FLOTSAM_SHOTS_STAGE` (a `Screen` name), `FLOTSAM_SHOTS_APPEARANCE` (`light` or `dark`) and `FLOTSAM_SHOTS_CTL` (an
/// existing folder). When the surface is up and still, this writes the id of the window to capture into
/// `<ctl>/ready`; on any trouble it writes the reason into `<ctl>/failed`. The script captures the window with
/// `screencapture -l` and then ends this process. Nothing here changes product behaviour: it sets ordinary settings
/// before the database opens, seeds ordinary items, and opens the same windows the user's actions open.
@MainActor
final class ShotsStaging {
    enum Screen: String {
        case library, libraryCompact = "library-compact", libraryCompactList = "library-compact-list", libraryEmpty = "library-empty"
        case shelf, menu, menuStaged = "menu-staged", menuPaused = "menu-paused", menuPausedStaged = "menu-paused-staged"
        case settings, settingsLibrary = "settings-library", onboarding, shortcut, shortcutEmpty = "shortcut-empty"

        /// Surfaces that need the fixture items.
        var needsItems: Bool {
            switch self {
            case .library, .libraryCompact, .libraryCompactList, .libraryEmpty, .shelf, .shortcut, .shortcutEmpty: true
            case .menu, .menuStaged, .menuPaused, .menuPausedStaged, .settings, .settingsLibrary, .onboarding: false
            }
        }

        /// The Compact layout (the preview replaces the list while it is open).
        var isCompact: Bool { self == .libraryCompact || self == .libraryCompactList }

        /// The menu-bar menu surfaces: the real NSMenu, or its staged copy.
        var isMenu: Bool { self == .menu || self == .menuStaged || self == .menuPaused || self == .menuPausedStaged }

        /// Surfaces that capture while paused with a timed pause, so the menu shows its "Paused until …" line.
        var staysPaused: Bool { self == .menuPaused || self == .menuPausedStaged }
    }

    private let screen: Screen
    private let dark: Bool
    private let ctl: URL
    private let container: AppContainer
    private var backdrop: NSWindow?

    /// True when this launch was started by the screenshot script.
    static var isActive: Bool { ProcessInfo.processInfo.environment["FLOTSAM_SHOTS_STAGE"] != nil }

    static func fromEnvironment(container: AppContainer) -> ShotsStaging? {
        let env = ProcessInfo.processInfo.environment
        guard let stage = env["FLOTSAM_SHOTS_STAGE"], let screen = Screen(rawValue: stage),
              let ctl = env["FLOTSAM_SHOTS_CTL"], ctl.hasPrefix("/")
        else { return nil }
        let dark = env["FLOTSAM_SHOTS_APPEARANCE"] == "dark"
        return ShotsStaging(
            screen: screen, dark: dark, ctl: URL(fileURLWithPath: ctl, isDirectory: true), container: container)
    }

    private init(screen: Screen, dark: Bool, ctl: URL, container: AppContainer) {
        self.screen = screen
        self.dark = dark
        self.ctl = ctl
        self.container = container
    }

    /// The capture ports for a staged launch: nothing is ever copied from the real pasteboard, and capture stays on so the
    /// menu rows are enabled.
    static func capturePorts() -> (pasteboard: any PasteboardPort, access: any PasteboardAccessPort) {
        (EmptyPasteboard(), AllowedAccess())
    }

    // MARK: Before the windows exist

    /// Runs right after the container is built, before the database opens and before the first window: the Library reads
    /// its layout and preview preset once, when it is built.
    func prepare() {
        // Before any Flotsam window exists. The onboarding window opens during launch, before `run`; a backdrop installed
        // after it would be ordered above it at the same level and hide it (the round-2 empty 07-onboarding frames).
        installBackdrop()
        NSApp.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        let settings = container.settings
        // Keep the screenshot folder and the typed-trigger tap out of the run (docs/AGENT-LAUNCH.md).
        settings.set(false, for: SettingKeys.screenshotsEnabled)
        settings.set(false, for: SettingKeys.triggersEnabled)
        settings.set(screen.isCompact ? LibraryLayoutMode.compact : .standard, for: SettingKeys.libraryLayout)
        // The Library pane's "Preview pane" row reads this setting, so 06b stages it as 01 shows the Library: Shown. Staging
        // it Closed made 06b say "Hidden" next to a preview-open 01 (hill-climb r6).
        let previewShown = screen == .library || screen == .settingsLibrary
        settings.set(previewShown ? LibraryPreviewPreset.open : .closed, for: SettingKeys.libraryPreviewPreset)
        settings.set(LibraryBackground.system, for: SettingKeys.libraryBackground)
        settings.set(screen == .settingsLibrary ? SettingsPane.library : .general, for: SettingKeys.settingsLastPane)
        if screen == .onboarding {
            settings.set(false, for: SettingKeys.onboardingCompleted)
            container.onboardingProgress.save(.clipboard)
        } else {
            settings.set(true, for: SettingKeys.onboardingCompleted)
        }
    }

    // MARK: Staging

    func run(statusItem: StatusItemController) {
        Task { @MainActor in await stage(statusItem: statusItem) }
    }

    private func stage(statusItem: StatusItemController) async {
        if screen.needsItems || screen.isMenu || screen == .settings || screen == .settingsLibrary {
            guard await waitFor({ self.container.library != nil && self.container.shelf != nil && self.container.database != nil }) else {
                return fail("the database or the panels did not come up")
            }
        }
        var seeded = ShotsFixtures.Seeded()
        if screen.needsItems, let database = container.database {
            seeded = await ShotsFixtures.seed(
                database: database, settings: container.settings, filesFolder: ctl.appendingPathComponent("files", isDirectory: true),
                now: Date())
        }
        centerPointerOnMainDisplay()
        installBackdrop()  // already done in prepare(); a no-op here
        let before = visibleWindowNumbers()
        switch screen {
        case .library, .libraryCompact, .libraryCompactList, .libraryEmpty: await stageLibrary(seeded: seeded, before: before)
        case .shelf:
            container.shelf?.toggle()
            await settle(seconds: 1.2)
            await finish(window: newWindow(excluding: before))
        case .settings, .settingsLibrary:
            container.actions.openSettings?()
            await settle(seconds: 1.0)
            await finish(window: newWindow(excluding: before))
        case .onboarding:
            await settle(seconds: 1.0)
            await finish(window: newWindow(excluding: before) ?? largestVisibleWindow())
        case .shortcut:
            guard let id = seeded.ids["shortcut"] else { return fail("the shortcut item was not seeded") }
            container.actions.editShortcutAndTrigger?([id])
            await settle(seconds: 1.0)
            await finish(window: newWindow(excluding: before))
        case .shortcutEmpty:
            // An item with no shortcut and no trigger, and the recorder armed, so the shot shows the empty field's
            // placeholder and the focus ring (the recording state draws the active ring).
            guard let id = seeded.ids["text3"] else { return fail("the unbound text item was not seeded") }
            container.actions.editShortcutAndTrigger?([id])
            await settle(seconds: 1.0)
            guard let window = newWindow(excluding: before) else { return fail("the shortcut editor did not open") }
            guard Self.pressElement(labeled: SettingsString.shortcutRecord.text, in: window) else {
                return fail("the shortcut recorder control was not found in the editor")
            }
            await settle(seconds: 0.6)
            await finish(window: window)
        case .menu, .menuPaused:
            if screen.staysPaused { container.timedPause.pause(for: .oneHour) }
            stageMenu(statusItem: statusItem)
        case .menuStaged, .menuPausedStaged:
            if screen.staysPaused { container.timedPause.pause(for: .oneHour) }
            stageMenuCopy(statusItem: statusItem)
        }
    }

    private func stageLibrary(seeded: ShotsFixtures.Seeded, before: Set<Int>) async {
        guard let library = container.library else { return fail("no library") }
        await library.show()
        await library.model.settled()
        switch screen {
        case .library:
            guard let id = seeded.ids["code"] else { return fail("the code item was not seeded") }
            library.model.select(id: id)
            await library.model.awaitPreview()
        case .libraryCompactList:
            // Compact's default state (FR-003-06): the results list, one row selected, the preview closed. 02 stages the
            // same layout with the preview replacing the list.
            guard let id = seeded.ids["code"] else { return fail("the code item was not seeded") }
            library.model.select(id: id)
            if library.model.isPreviewOpen { return fail("the preview is open in the Compact list shot") }
        case .libraryCompact:
            // FR-003-06 and FR-003-14: in Compact the preview replaces the results column, so the shot must open it. The staging
            // never did, which is why the earlier Compact shot showed only the hover card of the pointer resting on row 2.
            guard let id = seeded.ids["code"] else { return fail("the code item was not seeded") }
            library.model.select(id: id)
            library.model.perform(.togglePreview)
            await library.model.awaitPreview()
            if !library.model.isPreviewOpen { return fail("the preview did not open in the Compact layout") }
        case .libraryEmpty:
            library.model.setSearchText("zzqx no such clip")
            await library.model.settled()
            if !library.model.isNoResults { return fail("the search did not reach the no-results state") }
        default: break
        }
        await settle(seconds: 1.0)
        await finish(window: newWindow(excluding: before))
    }

    // MARK: Pressing a control

    /// Presses the accessibility element whose label is `label`, searching the window's accessibility tree. The staged
    /// editor has no model handle here, so the recorder is armed the way VoiceOver would press it. False when absent.
    private static func pressElement(labeled label: String, in window: NSWindow) -> Bool {
        func search(_ node: Any, depth: Int) -> Bool {
            guard depth < 40, let element = node as? NSAccessibilityProtocol else { return false }
            if element.accessibilityLabel() == label, element.accessibilityPerformPress() { return true }
            for child in element.accessibilityChildren() ?? [] where search(child, depth: depth + 1) { return true }
            return false
        }
        guard let root = window.contentView else { return false }
        return search(root, depth: 0)
    }

    // MARK: The menu

    /// The real menu: the status item's own NSMenu, opened by a click on its button. Tracking blocks inside `performClick`,
    /// so the window is looked for from a timer that runs in the tracking run-loop mode.
    private func stageMenu(statusItem: StatusItemController) {
        let timer = Timer(timeInterval: 0.6, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                guard let number = Self.ownMenuWindowNumber() else { return self.fail("no menu window appeared") }
                let frame = Self.ownMenuWindowFrame()
                self.ready(number, frame: frame, expectedLevel: nil, title: "", padding: 24)
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        // Opened at a fixed spot (top right, a gap below the system menu bar), not under the status item: the item's own
        // position depends on the host's menu bar (overflow, notch, other apps' items) and can land at x = 0.
        let area = (NSScreen.screens.first ?? NSScreen.main)?.visibleFrame ?? .zero
        statusItem.shotsPopUpMenu(at: CGPoint(x: area.maxX - 40 - 400, y: area.maxY - 30))
    }

    /// The fallback when a real menu cannot be captured: the same rows, drawn in a plain window with the menu material.
    /// The script says so in its report; it is not what the menu looks like to the pixel.
    private func stageMenuCopy(statusItem: StatusItemController) {
        let titles = statusItem.shotsMenuTitles()
        let rows = titles.map { title -> NSView in
            let label = NSTextField(labelWithString: title.isEmpty ? " " : title)
            label.font = NSFont.menuFont(ofSize: 0)
            return label
        }
        let stack = NSStackView(views: rows)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        stack.edgeInsets = NSEdgeInsets(top: 10, left: 14, bottom: 10, right: 14)
        let glass = NSVisualEffectView()
        glass.material = .menu
        glass.state = .active
        glass.addSubview(stack)
        stack.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: glass.topAnchor), stack.bottomAnchor.constraint(equalTo: glass.bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: glass.leadingAnchor), stack.trailingAnchor.constraint(equalTo: glass.trailingAnchor),
        ])
        let window = NSWindow(contentRect: .zero, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = glass
        window.isReleasedWhenClosed = false
        window.setContentSize(glass.fittingSize)
        Task { @MainActor in
            await finish(window: window, show: true)
        }
    }

    private nonisolated static func ownMenuWindowInfo() -> [String: Any]? {
        let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
        let mine = list.filter { ($0[kCGWindowOwnerPID as String] as? Int32) == ProcessInfo.processInfo.processIdentifier }
        // Pop-up menus sit at level 101; the status item itself is at 25.
        let menus = mine.filter { (($0[kCGWindowLayer as String] as? Int) ?? 0) >= 101 }
        return menus.max { area($0) < area($1) }
    }

    private nonisolated static func area(_ info: [String: Any]) -> Double {
        let bounds = info[kCGWindowBounds as String] as? [String: Double] ?? [:]
        return (bounds["Width"] ?? 0) * (bounds["Height"] ?? 0)
    }

    private nonisolated static func ownMenuWindowNumber() -> Int? { ownMenuWindowInfo()?[kCGWindowNumber as String] as? Int }

    private nonisolated static func ownMenuWindowFrame() -> CGRect {
        let bounds = ownMenuWindowInfo()?[kCGWindowBounds as String] as? [String: Double] ?? [:]
        // CoreGraphics bounds are top-left based; convert to AppKit's bottom-left space on the main display.
        let height = NSScreen.screens.first?.frame.height ?? 0
        let rect = CGRect(x: bounds["X"] ?? 0, y: bounds["Y"] ?? 0, width: bounds["Width"] ?? 0, height: bounds["Height"] ?? 0)
        return CGRect(x: rect.minX, y: height - rect.maxY, width: rect.width, height: rect.height)
    }

    // MARK: Helpers

    private func finish(window: NSWindow?, show: Bool = false) async {
        guard let window else { return fail("no window appeared") }
        let area = (NSScreen.screens.first ?? NSScreen.main)?.visibleFrame ?? window.frame
        if screen != .shelf {
            let origin = CGPoint(x: area.midX - window.frame.width / 2, y: area.midY - window.frame.height / 2)
            window.setFrameOrigin(origin)
        }
        // Always above the backdrop, whatever order the windows were created in.
        window.orderFrontRegardless()
        window.makeFirstResponder(nil)
        await settle(seconds: 0.6)
        ready(window.windowNumber, frame: window.frame, expectedLevel: window.level.rawValue, title: window.title)
    }

    /// A full-screen, generated, deterministic backdrop on the capture display, installed before any Flotsam window opens
    /// so every panel is ordered above it. It is opaque and covers the whole display (other apps, the terminal, the
    /// desktop), so the Library, Shelf and menu materials always blur the same pixels. Window level `.normal`: Flotsam's
    /// floating panels (3) and the pop-up menu (101) sit above it. The system menu bar (24) and Dock (20) stay above it
    /// by design; a frame that reaches them shows them. It never becomes key or main, so it takes no focus from the staged panel.
    private func installBackdrop() {
        guard backdrop == nil, let screen = NSScreen.screens.first else { return }
        let panel = ShotsBackdropWindow(contentRect: screen.frame, dark: dark)
        panel.orderFrontRegardless()
        backdrop = panel
    }

    private func visibleWindowNumbers() -> Set<Int> {
        Set(NSApp.windows.filter { $0.isVisible }.map(\.windowNumber))
    }

    private func candidates() -> [NSWindow] {
        NSApp.windows.filter {
            $0.isVisible && $0 !== backdrop && $0.frame.width >= 200 && $0.frame.height >= 100
                && !String(describing: type(of: $0)).contains("StatusBar")
        }
    }

    private func largestVisibleWindow() -> NSWindow? {
        candidates().max { $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height }
    }

    private func newWindow(excluding before: Set<Int>) -> NSWindow? {
        candidates().filter { !before.contains($0.windowNumber) }
            .max { $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height }
    }

    /// Panels and the Shelf slide in; wait it out rather than disabling animations (no code path here can).
    private func settle(seconds: Double) async {
        try? await Task.sleep(for: .seconds(seconds))
    }

    private func waitFor(_ condition: @MainActor () -> Bool) async -> Bool {
        for _ in 0..<200 {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(100))
        }
        return false
    }

    /// The Library and the Shelf open on the screen under the pointer, so put the pointer on the main display first.
    private func centerPointerOnMainDisplay() {
        let bounds = CGDisplayBounds(CGMainDisplayID())
        CGWarpMouseCursorPosition(CGPoint(x: bounds.midX, y: bounds.midY))
    }

    /// `<window number> <x> <y> <width> <height> <main display width> <screen recording 1|0>`: the frame in global top-left screen points, for
    /// `screencapture -R` (or a crop of a full-display capture, which needs the display width to find the pixel scale).
    /// A region capture records what is really on screen (materials over the fixed backdrop); a `-l` window capture
    /// renders the window alone, so its blur has nothing to sample.
    private func ready(_ windowNumber: Int, frame: CGRect, expectedLevel: Int?, title: String, padding: CGFloat = 0) {
        // An asleep or locked display captures as bare wallpaper (and -R is refused): say so instead of shooting it.
        let session = CGSessionCopyCurrentDictionary() as? [String: Any] ?? [:]
        if CGDisplayIsAsleep(CGMainDisplayID()) != 0 || (session["CGSSessionScreenIsLocked"] as? Bool) == true {
            return fail("the main display is asleep or the screen is locked; wake and unlock it")
        }
        if let problem = verifyOnScreen(windowNumber, expectedLevel: expectedLevel, title: title) { return fail(problem) }
        let display = NSScreen.screens.first?.frame ?? .zero
        // Top-left screen points. The menu is cropped with padding on every side, the top never reaching the system menu bar.
        var rect = CGRect(x: frame.minX, y: display.height - frame.maxY, width: frame.width, height: frame.height)
        if padding > 0 {
            let menuBarBottom = display.maxY - ((NSScreen.screens.first?.visibleFrame.maxY) ?? display.maxY)
            let padded = rect.insetBy(dx: -padding, dy: -padding)
            let top = max(padded.minY, menuBarBottom)
            rect = CGRect(x: padded.minX, y: top, width: padded.width, height: padded.maxY - top).intersection(CGRect(x: 0, y: 0, width: display.width, height: display.height))
        }
        // Round outward to whole points: rounding each number on its own can shave a point off one edge and let a
        // neighbouring pixel (a corner of a rounded panel, the shadow's edge) into the capture.
        rect = rect.integral
        let line = "\(windowNumber) \(Int(rect.minX)) \(Int(rect.minY)) \(Int(rect.width)) \(Int(rect.height)) \(Int(display.width.rounded())) \(CGPreflightScreenCaptureAccess() ? 1 : 0)\n"
        try? Data(line.utf8).write(to: ctl.appendingPathComponent("ready"))
    }

    /// Fails a pass that would shoot an empty frame: the target must be in the on-screen window list, owned by this
    /// process, at the expected level, with the expected title, on the display, and ordered above the backdrop.
    /// Returns the problem, or nil when the target is really there.
    private func verifyOnScreen(_ number: Int, expectedLevel: Int?, title: String) -> String? {
        let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []  // front to back
        let pid = ProcessInfo.processInfo.processIdentifier
        func index(of n: Int) -> Int? { list.firstIndex { ($0[kCGWindowNumber as String] as? Int) == n } }
        guard let at = index(of: number), let info = Optional(list[at]) else {
            return "the target window (\(number)) is not on screen: it is missing from the window list"
        }
        if (info[kCGWindowOwnerPID as String] as? Int32) != pid { return "the target window is not owned by the staged process" }
        let layer = info[kCGWindowLayer as String] as? Int ?? 0
        if let expectedLevel, layer != expectedLevel { return "the target window is at level \(layer), expected \(expectedLevel)" }
        if expectedLevel == nil, layer < 101 { return "the menu window is at level \(layer), expected a pop-up menu (101 or above)" }
        if !title.isEmpty, let name = info[kCGWindowName as String] as? String, name != title {
            return "the target window is titled \"\(name)\", expected \"\(title)\""
        }
        let bounds = info[kCGWindowBounds as String] as? [String: Double] ?? [:]
        let box = CGRect(x: bounds["X"] ?? 0, y: bounds["Y"] ?? 0, width: bounds["Width"] ?? 0, height: bounds["Height"] ?? 0)
        let displayBox = CGRect(x: 0, y: 0, width: NSScreen.screens.first?.frame.width ?? 0, height: NSScreen.screens.first?.frame.height ?? 0)
        if box.width < 1 || box.height < 1 || !displayBox.contains(CGPoint(x: box.midX, y: box.midY)) {
            return "the target window is not on the main display (bounds \(box))"
        }
        if let backdrop, let back = index(of: backdrop.windowNumber), back < at {
            return "the target window is hidden behind the backdrop"
        }
        return nil
    }

    private func fail(_ reason: String) {
        try? Data((reason + "\n").utf8).write(to: ctl.appendingPathComponent("failed"))
    }

    // MARK: Fakes

    /// A pasteboard that never has anything on it and never changes: no real clip reaches the fixture database.
    private struct EmptyPasteboard: PasteboardPort {
        var changeCount: Int { 0 }
        func currentTypeIdentifiers() -> [String] { [] }
        func readSnapshot(types: [String]) -> FlotsamResult<PasteboardSnapshot> {
            .success(PasteboardSnapshot(changeCount: 0, typeIdentifiers: [], representations: []))
        }
        func write(_ representations: [PasteboardRepresentation]) -> FlotsamResult<Int> { .success(0) }
    }

    private struct AllowedAccess: PasteboardAccessPort {
        var isReadAllowed: Bool { true }
    }
}
/// The shots backdrop: a borderless, click-through window that can never become key or main.
private final class ShotsBackdropWindow: NSWindow {
    init(contentRect: CGRect, dark: Bool) {
        super.init(contentRect: contentRect, styleMask: .borderless, backing: .buffered, defer: false)
        isReleasedWhenClosed = false
        isOpaque = true
        hasShadow = false
        ignoresMouseEvents = true
        level = .normal
        collectionBehavior = [.stationary, .ignoresCycle, .fullScreenNone]
        backgroundColor = ShotsBackdropView.baseColor(dark: dark)
        contentView = ShotsBackdropView(frame: CGRect(origin: .zero, size: contentRect.size), dark: dark)
        setFrame(contentRect, display: false)
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// A soft, wallpaper-like gradient drawn in code from fixed sRGB numbers: nothing is read from the host (no wallpaper,
/// no images), so the output is the same on every Mac. Different for light and dark.
private final class ShotsBackdropView: NSView {
    private let dark: Bool

    init(frame: CGRect, dark: Bool) {
        self.dark = dark
        super.init(frame: frame)
    }

    required init?(coder: NSCoder) { return nil }

    override var isFlipped: Bool { false }

    static func baseColor(dark: Bool) -> NSColor {
        dark ? NSColor(srgbRed: 0.09, green: 0.10, blue: 0.20, alpha: 1) : NSColor(srgbRed: 0.80, green: 0.86, blue: 0.96, alpha: 1)
    }

    private func color(_ r: Double, _ g: Double, _ b: Double, _ a: Double = 1) -> CGColor {
        NSColor(srgbRed: r, green: g, blue: b, alpha: a).cgColor
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext, let space = CGColorSpace(name: CGColorSpace.sRGB) else { return }
        let w = bounds.width, h = bounds.height
        // Base: a diagonal linear gradient.
        let stops: [CGColor] = dark
            ? [color(0.05, 0.07, 0.16), color(0.16, 0.12, 0.30), color(0.10, 0.20, 0.33)]
            : [color(0.74, 0.84, 0.97), color(0.90, 0.84, 0.96), color(0.98, 0.88, 0.84)]
        if let base = CGGradient(colorsSpace: space, colors: stops as CFArray, locations: [0, 0.55, 1]) {
            ctx.drawLinearGradient(base, start: CGPoint(x: 0, y: h), end: CGPoint(x: w, y: 0), options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
        }
        // Soft colour blooms, fixed positions as fractions of the screen.
        let blooms: [(x: Double, y: Double, r: Double, c: CGColor)] = dark
            ? [(0.22, 0.70, 0.45, color(0.35, 0.28, 0.62, 0.55)), (0.78, 0.25, 0.50, color(0.12, 0.45, 0.58, 0.50)), (0.55, 0.85, 0.30, color(0.50, 0.25, 0.45, 0.30))]
            : [(0.20, 0.75, 0.45, color(1.00, 0.92, 0.82, 0.75)), (0.80, 0.30, 0.50, color(0.70, 0.88, 1.00, 0.70)), (0.55, 0.88, 0.30, color(0.92, 0.80, 0.98, 0.55))]
        for bloom in blooms {
            let center = CGPoint(x: bloom.x * w, y: bloom.y * h)
            let clear = bloom.c.copy(alpha: 0) ?? bloom.c
            if let g = CGGradient(colorsSpace: space, colors: [bloom.c, clear] as CFArray, locations: [0, 1]) {
                ctx.drawRadialGradient(g, startCenter: center, startRadius: 0, endCenter: center, endRadius: bloom.r * max(w, h), options: [])
            }
        }
    }
}
#endif
