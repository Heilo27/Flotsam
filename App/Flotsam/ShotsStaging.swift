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
        case library, libraryCompact = "library-compact", libraryEmpty = "library-empty", shelf
        case menu, menuStaged = "menu-staged", settings, onboarding, shortcut

        /// Surfaces that need the fixture items.
        var needsItems: Bool {
            switch self {
            case .library, .libraryCompact, .libraryEmpty, .shelf, .shortcut: true
            case .menu, .menuStaged, .settings, .onboarding: false
            }
        }
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
        NSApp.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        let settings = container.settings
        // Keep the screenshot folder and the typed-trigger tap out of the run (docs/AGENT-LAUNCH.md).
        settings.set(false, for: SettingKeys.screenshotsEnabled)
        settings.set(false, for: SettingKeys.triggersEnabled)
        settings.set(screen == .libraryCompact ? LibraryLayoutMode.compact : .standard, for: SettingKeys.libraryLayout)
        settings.set(screen == .library ? LibraryPreviewPreset.open : .closed, for: SettingKeys.libraryPreviewPreset)
        settings.set(LibraryBackground.system, for: SettingKeys.libraryBackground)
        settings.set(SettingsPane.general, for: SettingKeys.settingsLastPane)
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
        if screen.needsItems || screen == .menu || screen == .menuStaged || screen == .settings {
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
        let before = visibleWindowNumbers()
        switch screen {
        case .library, .libraryCompact, .libraryEmpty: await stageLibrary(seeded: seeded, before: before)
        case .shelf:
            container.shelf?.toggle()
            await settle(seconds: 1.2)
            await finish(window: newWindow(excluding: before))
        case .settings:
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
        case .menu: stageMenu(statusItem: statusItem)
        case .menuStaged: stageMenuCopy(statusItem: statusItem)
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
        case .libraryEmpty:
            library.model.setSearchText("zzqx no such clip")
            await library.model.settled()
            if !library.model.isNoResults { return fail("the search did not reach the no-results state") }
        default: break
        }
        await settle(seconds: 1.0)
        await finish(window: newWindow(excluding: before))
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
                self.placeBackdrop(under: frame)
                self.ready(number, frame: frame)
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        statusItem.shotsOpenMenu()
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
        if show { window.orderFrontRegardless() }
        placeBackdrop(under: window.frame)
        window.makeFirstResponder(nil)
        await settle(seconds: 0.6)
        ready(window.windowNumber, frame: window.frame)
    }

    /// A solid, fixed-colour window just behind the staged one, so every material samples the same backdrop on every host.
    private func placeBackdrop(under frame: CGRect) {
        let panel = NSWindow(contentRect: frame.insetBy(dx: -60, dy: -60), styleMask: .borderless, backing: .buffered, defer: false)
        panel.backgroundColor = dark
            ? NSColor(srgbRed: 0.10, green: 0.12, blue: 0.17, alpha: 1) : NSColor(srgbRed: 0.86, green: 0.88, blue: 0.92, alpha: 1)
        panel.isOpaque = true
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.isReleasedWhenClosed = false
        panel.level = .normal
        panel.orderFront(nil)
        panel.orderBack(nil)
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

    /// `<window number> <x> <y> <width> <height>`: the frame in global top-left screen points, for `screencapture -R`.
    /// A region capture records what is really on screen (materials over the fixed backdrop); a `-l` window capture
    /// renders the window alone, so its blur has nothing to sample.
    private func ready(_ windowNumber: Int, frame: CGRect) {
        let top = (NSScreen.screens.first?.frame.height ?? 0) - frame.maxY
        let line = "\(windowNumber) \(Int(frame.minX.rounded())) \(Int(top.rounded())) \(Int(frame.width.rounded())) \(Int(frame.height.rounded()))\n"
        try? Data(line.utf8).write(to: ctl.appendingPathComponent("ready"))
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
#endif
