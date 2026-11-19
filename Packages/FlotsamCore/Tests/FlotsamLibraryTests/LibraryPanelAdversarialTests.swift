import CoreGraphics
import FlotsamBase
import FlotsamPaste
import Foundation
import Testing
@testable import FlotsamLibrary

// Worf adversarial tests for TASK-160/162/264, written from FRD-003 (FR-003-01/02/03, AC-003-01/02) and the oracle
// (OC-3002, OC-3004, OC-3006), not from the builder's tests. Expected values are literals.

private let advTextEdit = FrontmostApp(bundleId: "com.apple.TextEdit", processId: 411)

@MainActor
private final class AdvPresenter: LibraryPanelPresenter {
    var visible = false
    var frames: [CGRect] = []
    var hides = 0
    /// What the model said at the instant the panel was shown (the list must already be loaded).
    var modelShownAtShow: Bool?
    var model: LibraryViewModel?
    /// A real NSPanel resigns key while it is ordered out; the notification reaches the driver mid-hide.
    var resignKeyDuringHide: (() -> Void)?
    var isVisible: Bool { visible }
    func show(at frame: CGRect, minimumSize: PanelSize) {
        modelShownAtShow = model?.isShown
        frames.append(frame)
        visible = true
    }
    func hide() {
        hides += 1
        visible = false
        resignKeyDuringHide?()
    }
}

@MainActor
private final class AdvFront: FrontmostAppProvider {
    var app: FrontmostApp?
    init(_ app: FrontmostApp?) { self.app = app }
    func frontmost() -> FrontmostApp? { app }
}

@MainActor
private final class AdvScreens: LibraryScreenProvider {
    var pointerLocation = CGPoint.zero
    var screens: [LibraryScreen] = []
    var mainScreen: LibraryScreen?
}

/// The model's host, forwarding to the driver as the App's HostBox forwards to the controller.
@MainActor
private final class AdvHostBox: PasteHost {
    weak var driver: LibraryPanelDriver?
    var isPanelVisible: Bool { driver?.isPanelVisible ?? false }
    func hidePanel() { driver?.hidePanel() }
}

@MainActor
private struct AdvRig {
    let source = FakeSource(rows: Harness.rows(3))
    let paster = FakePaster()
    let prefs = FakePreferences()
    let presenter = AdvPresenter()
    let front: AdvFront
    let screens = AdvScreens()
    let model: LibraryViewModel
    let driver: LibraryPanelDriver

    init(frontmost: FrontmostApp? = advTextEdit, captureNow: @escaping @MainActor () async -> Void = {}) {
        front = AdvFront(frontmost)
        let box = AdvHostBox()
        model = LibraryViewModel(
            source: source, paster: paster, host: box, preferences: prefs,
            effects: LibraryEffects(
                report: { _ in }, reveal: { _ in }, openSettings: {}, external: { _, _ in }, isAccessibilityTrusted: { true }))
        driver = LibraryPanelDriver(model: model, frontmost: front, screens: screens, preferences: prefs, captureNow: captureNow)
        driver.presenter = presenter
        presenter.model = model
        box.driver = driver
        let main = LibraryScreen(frame: CGRect(x: 0, y: 0, width: 1440, height: 900), visibleFrame: CGRect(x: 0, y: 0, width: 1440, height: 870))
        screens.screens = [main]
        screens.mainScreen = main
        screens.pointerLocation = CGPoint(x: 100, y: 100)
    }
}

@Suite(.timeLimit(.minutes(1))) @MainActor
struct LibraryPanelAdversarialTests {
    private static let left = LibraryScreen(
        frame: CGRect(x: 0, y: 0, width: 1440, height: 900), visibleFrame: CGRect(x: 0, y: 0, width: 1440, height: 870))
    private static let right = LibraryScreen(
        frame: CGRect(x: 1440, y: 0, width: 1920, height: 1080), visibleFrame: CGRect(x: 1440, y: 0, width: 1920, height: 1080))

    // FR-003-03 / AC-003-02: frames are half-open, so a pointer exactly on the seam belongs to the right display and one
    // point left of it to the left display. Red if the screen test becomes a closed range or checks the wrong edge.
    // OC-3004 layout half.
    @Test("AC-003-02 a pointer exactly on the seam between two displays is on the right one, one point left of it on the left one")
    func seamPointer() async {
        let rig = AdvRig()
        rig.screens.screens = [Self.left, Self.right]
        rig.screens.mainScreen = Self.left
        rig.screens.pointerLocation = CGPoint(x: 1440, y: 500)
        await rig.driver.show()
        rig.driver.hidePanel()
        rig.screens.pointerLocation = CGPoint(x: 1439, y: 500)
        await rig.driver.show()
        #expect(rig.presenter.frames == [CGRect(x: 2020, y: 240, width: 760, height: 480), CGRect(x: 340, y: 100, width: 760, height: 480)])
        #expect(rig.presenter.frames.count == 2)
    }

    // FR-003-03: a display to the left of the main one has a negative origin; the panel is centred on it.
    // centre x = -960, x = -960 - 380 = -1340; top = 1080 - 360 = 720, y = 240.
    @Test("FR-003-03 a display with a negative origin centres the panel on that display")
    func negativeOrigin() async {
        let rig = AdvRig()
        let far = LibraryScreen(frame: CGRect(x: -1920, y: 0, width: 1920, height: 1080), visibleFrame: CGRect(x: -1920, y: 0, width: 1920, height: 1080))
        rig.screens.screens = [Self.left, far]
        rig.screens.mainScreen = Self.left
        rig.screens.pointerLocation = CGPoint(x: -500, y: 500)
        await rig.driver.show()
        #expect(rig.presenter.frames == [CGRect(x: -1340, y: 240, width: 760, height: 480)])
    }

    // Mirrored displays share a frame: the first one listed decides (the old controller used `first`).
    // First has a 30 pt menu bar (y = 100), second none (y = 240 would be wrong here).
    @Test("FR-003-03 when two displays both contain the pointer the first listed decides")
    func overlappingDisplaysFirstWins() async {
        let rig = AdvRig()
        let mirror = LibraryScreen(frame: Self.left.frame, visibleFrame: CGRect(x: 0, y: 0, width: 1440, height: 900))
        rig.screens.screens = [Self.left, mirror]
        rig.screens.pointerLocation = CGPoint(x: 100, y: 100)
        await rig.driver.show()
        #expect(rig.presenter.frames == [CGRect(x: 340, y: 100, width: 760, height: 480)])
    }

    // FR-003-03: the visible frame (menu bar excluded), not the full frame, places the panel.
    // Full-frame mutation would give y = 900 - 300 - 480 = 120 instead of 100.
    @Test("FR-003-03 the panel's top edge is a third down the visible frame, not the full frame")
    func visibleFrameNotFrame() async {
        let rig = AdvRig()
        await rig.driver.show()
        #expect(rig.presenter.frames == [CGRect(x: 340, y: 100, width: 760, height: 480)])
    }

    // FR-003-02: show() itself is guarded, not only toggle(): calling it while the panel is visible neither captures
    // nor re-places the panel. (Menu item and hotkey both use toggle today; the guard is the second line of defence.)
    @Test("FR-003-02 show() while the panel is already visible does nothing")
    func showWhileVisibleIsNoop() async {
        let rig = AdvRig()
        await rig.driver.show()
        rig.screens.pointerLocation = CGPoint(x: 2000, y: 500)
        rig.screens.screens = [Self.left, Self.right]
        await rig.driver.show()
        #expect(rig.presenter.frames == [CGRect(x: 340, y: 100, width: 760, height: 480)])
        #expect(rig.presenter.hides == 0)
    }

    // FR-003-04: the panel appears only after the list has loaded (model.open ran), so the first frame the user sees
    // already has the rows. Red if show precedes open.
    @Test("FR-003-04 the panel is shown only after the model has opened")
    func shownAfterModelOpen() async {
        let rig = AdvRig()
        await rig.driver.show()
        #expect(rig.presenter.modelShownAtShow == true)
    }

    // FR-003-02 / OC-3002: Esc closes. The real chain is model.perform(.escape) -> host.hidePanel -> driver -> presenter,
    // and the model is told it hid. Red if hidePanel stops calling the presenter or the model.
    @Test("OC-3002 Esc with nothing to clear hides the panel through the model's host, once, and the model learns it hid")
    func escapeHidesThroughHost() async {
        let rig = AdvRig()
        await rig.driver.show()
        #expect(rig.model.isShown)
        rig.model.perform(.escape)
        #expect(rig.presenter.hides == 1)
        #expect(!rig.presenter.visible)
        #expect(!rig.model.isShown)
        #expect(rig.paster.calls.isEmpty)
    }

    // A real panel resigns key while being ordered out; the resulting delegate call must not hide a second time.
    @Test("FR-003-02 resign-key arriving during the hide does not hide again")
    func resignKeyDuringHideIsIdempotent() async {
        let rig = AdvRig()
        rig.presenter.resignKeyDuringHide = { rig.driver.panelResignedKey() }
        await rig.driver.show()
        rig.driver.activeSpaceChanged()
        #expect(rig.presenter.hides == 1)
        #expect(!rig.model.isShown)
    }

    // FR-003-02: no frontmost app (nil) still opens; the model records "no target" rather than a stale one.
    @Test("FR-003-02 with no frontmost app the panel still opens and a paste carries no target")
    func nilFrontmostStillOpens() async {
        let rig = AdvRig(frontmost: nil)
        await rig.driver.show()
        #expect(rig.presenter.frames.count == 1)
        let id = rig.source.rows[0].id
        await rig.model.paste(itemId: id, mode: .paste)
        #expect(rig.paster.calls == [FakePaster.Call(itemId: id, mode: .paste, target: nil)])
    }

    // After a hide by a trigger the panel opens again on the next press (isOpening does not stick).
    @Test("FR-003-02 after a hide trigger the next hotkey press opens again")
    func reopensAfterTrigger() async {
        let rig = AdvRig()
        for _ in 0..<3 {
            rig.driver.toggle()
            await rig.driver.showTask?.value
            rig.driver.applicationActivated(processId: 522, ownProcessId: 999)
        }
        #expect(rig.presenter.frames.count == 3)
        #expect(rig.presenter.hides == 3)
        #expect(!rig.presenter.visible)
    }

    // Activation of Flotsam itself with the panel open then a real other app: hides only on the real other app.
    @Test("FR-003-02 Flotsam's own pid keeps the panel open; the next foreign pid closes it")
    func ownThenForeign() async {
        let rig = AdvRig()
        await rig.driver.show()
        rig.driver.applicationActivated(processId: 999, ownProcessId: 999)
        #expect(rig.presenter.visible)
        #expect(rig.presenter.hides == 0)
        rig.driver.applicationActivated(processId: 1000, ownProcessId: 999)
        #expect(!rig.presenter.visible)
        #expect(rig.presenter.hides == 1)
    }

    // FR-003-03 / AC-003-02: the pointer's display is the one whose FULL frame contains it. A pointer in the menu-bar
    // band of the right display (inside its frame, above its visible frame) still picks the right display; picking by
    // visibleFrame would fall to the main display. Right display visible top = 1050: top = 1050 - 350 = 700, y = 220.
    @Test("AC-003-02 a pointer in the menu bar band of the second display opens the panel on that display")
    func pointerInMenuBarBand() async {
        let rig = AdvRig()
        let right = LibraryScreen(
            frame: CGRect(x: 1440, y: 0, width: 1920, height: 1080), visibleFrame: CGRect(x: 1440, y: 0, width: 1920, height: 1050))
        rig.screens.screens = [Self.left, right]
        rig.screens.mainScreen = Self.left
        rig.screens.pointerLocation = CGPoint(x: 2000, y: 1070)
        await rig.driver.show()
        #expect(rig.presenter.frames == [CGRect(x: 2020, y: 220, width: 760, height: 480)])
        #expect(rig.presenter.frames.count == 1)
    }

    // FR-003-02: two hotkey presses before the first open finishes capture once and show once. captureNow suspends
    // once (no gate, no wall clock) so the second press arrives while the first is mid-open. Red if the opening guard
    // goes (capture count 2).
    @Test("FR-003-02 two presses before the first open completes capture once and show once")
    func doublePressCapturesOnce() async {
        var captures = 0
        let rig = AdvRig(captureNow: { captures += 1; await Task.yield() })
        rig.driver.toggle()
        let first = rig.driver.showTask
        rig.driver.toggle()
        let second = rig.driver.showTask
        await first?.value
        await second?.value
        #expect(captures == 1)
        #expect(rig.presenter.frames.count == 1)
        #expect(rig.presenter.hides == 0)
    }
}
