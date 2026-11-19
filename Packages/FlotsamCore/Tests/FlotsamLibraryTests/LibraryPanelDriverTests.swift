import CoreGraphics
import FlotsamBase
import FlotsamPaste
import Foundation
import Testing
@testable import FlotsamLibrary

/// FRD-003 FR-003-01 / FR-003-02 / FR-003-03 panel decisions (AC-003-01, AC-003-02; oracle OC-3004, OC-3005, OC-3006),
/// asserted on `LibraryPanelDriver` with a recording presenter, a scripted frontmost app and scripted screens. The App's
/// `LibraryPanelController` is glue over the same driver. Expected values are literals from the FRD and the oracle.
/// Not covered here (TASK-518, the real-OS matrix): the real `NSPanel`'s key-window status, Spaces, a real full-screen
/// overlay, the CGWindowList window count and number, and a real click outside.

private let textEdit = FrontmostApp(bundleId: "com.apple.TextEdit", processId: 411)
private let calculator = FrontmostApp(bundleId: "com.apple.calculator", processId: 522)
private let flotsamPid: Int32 = 999

private enum PanelLogEvent: Equatable {
    case captureNow
    case show(CGRect)
    case hide
}

/// Everything the driver does to the window, in order, plus the state the window reports back.
@MainActor
private final class PanelRecorder: LibraryPanelPresenter {
    var events: [PanelLogEvent] = []
    var isVisible = false
    /// Runs inside `show`, once the window reports visible, where the real panel resigns key as key moves to it.
    var duringShow: () -> Void = {}
    var minimumSizes: [PanelSize] = []
    func show(at frame: CGRect, minimumSize: PanelSize) {
        minimumSizes.append(minimumSize)
        events.append(.show(frame))
        isVisible = true
        duringShow()
    }
    func hide() {
        events.append(.hide)
        isVisible = false
    }
    var shows: [CGRect] { events.compactMap { if case .show(let frame) = $0 { frame } else { nil } } }
    var hideCount: Int { events.filter { $0 == .hide }.count }
}

@MainActor
private final class PanelFrontmost: FrontmostAppProvider {
    var current: FrontmostApp?
    private(set) var reads = 0
    init(_ current: FrontmostApp?) { self.current = current }
    func frontmost() -> FrontmostApp? {
        reads += 1
        return current
    }
}

@MainActor
private final class PanelScreens: LibraryScreenProvider {
    var pointerLocation = CGPoint.zero
    var screens: [LibraryScreen] = []
    var mainScreen: LibraryScreen?
}

@MainActor
private struct PanelRig {
    let harness = Harness(rows: Harness.rows(3))
    let presenter = PanelRecorder()
    let frontmost: PanelFrontmost
    let screens = PanelScreens()
    let driver: LibraryPanelDriver
    /// How many times `captureNow` ran, and what it does when it runs.
    let capture = CaptureScript()

    @MainActor final class CaptureScript {
        var count = 0
        var onRun: () async -> Void = {}
    }

    init(frontmost app: FrontmostApp? = textEdit) {
        frontmost = PanelFrontmost(app)
        let capture = capture
        let presenter = presenter
        driver = LibraryPanelDriver(
            model: harness.model, frontmost: frontmost, screens: screens, preferences: harness.prefs,
            captureNow: {
                capture.count += 1
                presenter.events.append(.captureNow)
                await capture.onRun()
            })
        driver.presenter = presenter
        // The default scene: one 1440x900 screen with a 30 pt menu bar, pointer on it.
        let main = LibraryScreen(frame: CGRect(x: 0, y: 0, width: 1440, height: 900), visibleFrame: CGRect(x: 0, y: 0, width: 1440, height: 870))
        screens.screens = [main]
        screens.mainScreen = main
        screens.pointerLocation = CGPoint(x: 100, y: 100)
    }

    /// The hotkey, then wait for the show it started to finish.
    func press() async {
        driver.toggle()
        await driver.showTask?.value
    }
}

/// A one-shot rendezvous so a test can hold `captureNow` open and know it has started, with no wall-clock wait.
@MainActor
private final class CaptureGate {
    private var startedContinuation: AsyncStream<Void>.Continuation?
    private var releaseContinuation: AsyncStream<Void>.Continuation?
    private let started: AsyncStream<Void>
    private let release: AsyncStream<Void>

    init() {
        var startedC: AsyncStream<Void>.Continuation?
        var releaseC: AsyncStream<Void>.Continuation?
        started = AsyncStream<Void> { startedC = $0 }
        release = AsyncStream<Void> { releaseC = $0 }
        startedContinuation = startedC
        releaseContinuation = releaseC
    }

    /// Called by the held operation: announce, then wait to be let go.
    func hold() async {
        startedContinuation?.yield()
        for await _ in release { break }
    }
    func waitUntilHeld() async { for await _ in started { break } }
    func open() { releaseContinuation?.yield() }
}

@Suite(.timeLimit(.minutes(1))) @MainActor
struct LibraryPanelDriverTests {
    // MARK: FR-003-02 toggle (AC-003-01)

    // AC-003-01. "pressing the hotkey again ... closes it". Red if the second press reopens, or hides without telling the model.
    @Test("AC-003-01 the hotkey shows the panel and the hotkey again hides it, and the model learns it hid")
    func hotkeyTogglesShowThenHide() async {
        let rig = PanelRig()
        await rig.press()
        #expect(rig.presenter.shows.count == 1)
        #expect(rig.presenter.isVisible)
        #expect(rig.harness.model.isShown)
        await rig.press()
        #expect(rig.presenter.events == [.captureNow, .show(CGRect(x: 340, y: 100, width: 760, height: 480)), .hide])
        #expect(!rig.presenter.isVisible)
        #expect(!rig.harness.model.isShown)
    }

    // FR-003-02 "Hiding without a paste restores nothing and writes nothing"; AC-003-01 "no change to the other app".
    // The presenter has no way to activate or paste, so the only possible traces are a paste call or a changed target.
    @Test("AC-003-01 closing with the hotkey or Esc pastes nothing and does not touch the other app")
    func closeLeavesOtherAppUntouched() async {
        let rig = PanelRig()
        await rig.press()
        rig.driver.hidePanel()
        #expect(rig.harness.paster.calls.isEmpty)
        #expect(rig.frontmost.current == textEdit)
        #expect(rig.presenter.events.filter { $0 == .hide }.count == 1)
        await rig.press()
        await rig.press()
        #expect(rig.harness.paster.calls.isEmpty)
        #expect(rig.frontmost.current == textEdit)
    }

    // FR-003-02 "the panel records the target app (frontmost bundle id and process id), calls captureNow, then shows".
    @Test("FR-003-02 captureNow runs before the panel shows, and the show never precedes it")
    func captureNowThenShow() async {
        let rig = PanelRig()
        await rig.press()
        #expect(rig.presenter.events.first == .captureNow)
        #expect(rig.presenter.shows.count == 1)
        #expect(rig.capture.count == 1)
    }

    // FR-003-02. The target is the app frontmost when the key was pressed, not whatever is frontmost by the time
    // captureNow finishes. Mutation: reading the frontmost app after `await captureNow()`.
    @Test("FR-003-02 the paste target is the app frontmost at the press, even if the frontmost app changes during captureNow")
    func targetRecordedAtPress() async {
        let rig = PanelRig(frontmost: textEdit)
        rig.capture.onRun = { rig.frontmost.current = calculator }
        await rig.press()
        let id = rig.harness.source.rows[0].id
        await rig.harness.model.paste(itemId: id, mode: .paste)
        #expect(rig.harness.paster.calls == [FakePaster.Call(itemId: id, mode: .paste, target: textEdit)])
        #expect(rig.frontmost.reads == 1)
    }

    // The target is re-recorded on every open (the second open's target is the second press's frontmost app).
    @Test("FR-003-02 each open records its own target")
    func targetRerecordedEachOpen() async {
        let rig = PanelRig(frontmost: textEdit)
        await rig.press()
        await rig.press()
        rig.frontmost.current = calculator
        await rig.press()
        let id = rig.harness.source.rows[0].id
        await rig.harness.model.paste(itemId: id, mode: .paste)
        #expect(rig.harness.paster.calls.map(\.target) == [calculator])
        #expect(rig.frontmost.reads == 2)
    }

    // A second press while the first is still opening (captureNow in flight) must not start a second open.
    @Test("FR-003-02 a second hotkey press while the first open is in flight does not capture or show twice")
    func pressWhileOpeningIgnored() async {
        let rig = PanelRig()
        let gate = CaptureGate()
        rig.capture.onRun = { await gate.hold() }
        rig.driver.toggle()
        let first = rig.driver.showTask
        await gate.waitUntilHeld()
        rig.driver.toggle()
        let second = rig.driver.showTask
        gate.open()
        await first?.value
        await second?.value
        #expect(rig.capture.count == 1)
        #expect(rig.presenter.shows.count == 1)
        #expect(rig.presenter.hideCount == 0)
    }

    // MARK: Hide triggers (FR-003-02, OC-3006)

    // OC-3006. Click outside (the panel resigns key), a Space change, another app becoming frontmost: each hides, and
    // nothing is pasted. Three runs, reopening each time, as the oracle does.
    @Test("OC-3006 click outside, a Space change and Calculator activating each hide the panel and paste nothing")
    func oc3006_hideTriggers() async {
        let rig = PanelRig()
        let triggers: [(String, @MainActor (LibraryPanelDriver) -> Void)] = [
            ("click outside", { $0.panelResignedKey() }),
            ("Space change", { $0.activeSpaceChanged() }),
            ("Calculator activated", { $0.applicationActivated(processId: calculator.processId, ownProcessId: flotsamPid) }),
        ]
        for (index, (name, fire)) in triggers.enumerated() {
            await rig.press()
            #expect(rig.presenter.isVisible, "\(name): opened")
            fire(rig.driver)
            #expect(!rig.presenter.isVisible, "\(name): hidden")
            #expect(rig.presenter.hideCount == index + 1, "\(name): hidden once")
            #expect(!rig.harness.model.isShown, "\(name): model told")
        }
        #expect(rig.harness.paster.calls.isEmpty)
    }

    // FR-003-02 "a different app becoming frontmost": Flotsam's own activation (the menu bar item) is not that.
    // An activation with no readable process id counts as another app. Mutation: dropping the own-process check.
    @Test("FR-003-02 Flotsam activating itself does not hide the panel; an activation with no process id does")
    func ownActivationDoesNotHide() async {
        let rig = PanelRig()
        await rig.press()
        rig.driver.applicationActivated(processId: flotsamPid, ownProcessId: flotsamPid)
        #expect(rig.presenter.isVisible)
        rig.driver.applicationActivated(processId: nil, ownProcessId: flotsamPid)
        #expect(!rig.presenter.isVisible)
    }

    // The panel resigns key as key moves onto it while it is being shown; that must not close it.
    @Test("FR-003-02 resigning key while the panel is appearing does not hide it; resigning afterwards does")
    func resignKeyDuringShowIgnored() async {
        let rig = PanelRig()
        rig.presenter.duringShow = { rig.driver.panelResignedKey() }
        await rig.press()
        #expect(rig.presenter.isVisible)
        #expect(rig.presenter.hideCount == 0)
        rig.driver.panelResignedKey()
        #expect(!rig.presenter.isVisible)
    }

    // Hide triggers on a hidden panel do nothing: no second hide, no extra model call.
    @Test("FR-003-02 hide triggers while the panel is hidden do nothing")
    func triggersWhileHidden() {
        let rig = PanelRig()
        rig.driver.panelResignedKey()
        rig.driver.activeSpaceChanged()
        rig.driver.applicationActivated(processId: calculator.processId, ownProcessId: flotsamPid)
        rig.driver.hidePanel()
        #expect(rig.presenter.events.isEmpty)
    }

    // MARK: FR-003-01 one instance, kept (OC-3005, model half)

    // OC-3005 "opened and closed 20 times": the driver talks to the one presenter every time and never asks for another
    // window; every open shows exactly once and every close hides exactly once. (The window-list count and the window
    // number are the real panel: TASK-518.)
    @Test("OC-3005 twenty open-close cycles show and hide the same presenter twenty times each, never more than one visible")
    func oc3005_twentyCycles() async {
        let rig = PanelRig()
        for _ in 0..<20 {
            await rig.press()
            #expect(rig.presenter.isVisible)
            #expect(rig.harness.model.isShown)
            await rig.press()
            #expect(!rig.presenter.isVisible)
            #expect(!rig.harness.model.isShown)
        }
        #expect(rig.presenter.shows.count == 20)
        #expect(rig.presenter.hideCount == 20)
        #expect(rig.capture.count == 20)
        // Strictly alternating: capture, show, hide, capture, show, hide...
        let shape = rig.presenter.events.map { event -> String in
            switch event {
            case .captureNow: "capture"
            case .show: "show"
            case .hide: "hide"
            }
        }
        #expect(shape == Array(repeating: ["capture", "show", "hide"], count: 20).flatMap { $0 })
    }

    // MARK: FR-003-03 the pointer's screen (AC-003-02, OC-3004)

    private static let menuBarScreen = LibraryScreen(
        frame: CGRect(x: 0, y: 0, width: 1440, height: 900), visibleFrame: CGRect(x: 0, y: 0, width: 1440, height: 870))
    /// A second display holding a full-screen app: no menu bar or Dock, so the visible frame is the whole frame.
    private static let fullScreenDisplay = LibraryScreen(
        frame: CGRect(x: 1440, y: 0, width: 1920, height: 1080), visibleFrame: CGRect(x: 1440, y: 0, width: 1920, height: 1080))

    // AC-003-02. Pointer on the second display, a full-screen app there: the panel opens on that display. Centred on
    // x 2400, top at 1080 - 1080/3 = 720, so y = 720 - 480 = 240, x = 2400 - 380 = 2020.
    @Test("AC-003-02 with the pointer on a second, full-screen display the panel opens there, 760 x 480 centred a third down")
    func ac003_02_secondDisplay() async {
        let rig = PanelRig()
        rig.screens.screens = [Self.menuBarScreen, Self.fullScreenDisplay]
        rig.screens.mainScreen = Self.menuBarScreen
        rig.screens.pointerLocation = CGPoint(x: 2000, y: 500)
        await rig.press()
        #expect(rig.presenter.shows == [CGRect(x: 2020, y: 240, width: 760, height: 480)])
    }

    // OC-3004 (layout half). The pointer's display decides, whichever is main; with the pointer back on the first
    // display: centre x 720, top 870 - 290 = 580, y = 100, x = 340.
    @Test("OC-3004 the screen is read at each press: the same panel opens on the first display when the pointer is there")
    func screenFollowsPointerEachOpen() async {
        let rig = PanelRig()
        rig.screens.screens = [Self.menuBarScreen, Self.fullScreenDisplay]
        rig.screens.mainScreen = Self.menuBarScreen
        rig.screens.pointerLocation = CGPoint(x: 2000, y: 500)
        await rig.press()
        await rig.press()
        rig.screens.pointerLocation = CGPoint(x: 100, y: 100)
        await rig.press()
        #expect(rig.presenter.shows == [CGRect(x: 2020, y: 240, width: 760, height: 480), CGRect(x: 340, y: 100, width: 760, height: 480)])
    }

    // The pointer is read when the panel appears (after captureNow and the open), not at the key press.
    @Test("FR-003-03 the pointer's screen is the one under it when the panel appears, after captureNow")
    func pointerReadAfterCapture() async {
        let rig = PanelRig()
        rig.screens.screens = [Self.menuBarScreen, Self.fullScreenDisplay]
        rig.screens.mainScreen = Self.menuBarScreen
        rig.screens.pointerLocation = CGPoint(x: 100, y: 100)
        rig.capture.onRun = { rig.screens.pointerLocation = CGPoint(x: 2000, y: 500) }
        await rig.press()
        #expect(rig.presenter.shows == [CGRect(x: 2020, y: 240, width: 760, height: 480)])
    }

    // FR-003-03 remembered size, raised to the 560 x 360 minimum: width 560, height 360 on the second display:
    // x = 2400 - 280 = 2120, y = 720 - 360 = 360.
    @Test("FR-003-03 the remembered size is raised to the 560 x 360 minimum")
    func sizeRaisedToMinimum() async {
        let rig = PanelRig()
        rig.harness.prefs.panelSize = PanelSize(width: 400, height: 300)
        rig.screens.screens = [Self.menuBarScreen, Self.fullScreenDisplay]
        rig.screens.pointerLocation = CGPoint(x: 2000, y: 500)
        await rig.press()
        #expect(rig.presenter.shows == [CGRect(x: 2120, y: 360, width: 560, height: 360)])
    }

    // A pointer outside every display (a disconnected display): the main screen; no screen at all: a 1440 x 900 default.
    @Test("FR-003-03 a pointer outside every display uses the main screen, and no screens at all uses 1440 x 900")
    func fallbacks() async {
        let rig = PanelRig()
        rig.screens.screens = [Self.menuBarScreen, Self.fullScreenDisplay]
        rig.screens.mainScreen = Self.fullScreenDisplay
        rig.screens.pointerLocation = CGPoint(x: -5000, y: -5000)
        await rig.press()
        await rig.press()
        rig.screens.screens = []
        rig.screens.mainScreen = nil
        await rig.press()
        #expect(rig.presenter.shows == [CGRect(x: 2020, y: 240, width: 760, height: 480), CGRect(x: 340, y: 120, width: 760, height: 480)])
    }

    // MARK: FR-003-01 / FR-003-02 the window is non-activating (OC-3004, AC-003-01)

    // The previous app stays frontmost because the panel is non-activating; it floats, joins every Space (so it opens
    // on the active one without switching) and sits over full-screen apps; it is resizable and movable (FR-003-03).
    @Test("FR-003-01 the Library window spec: non-activating, floating, all Spaces, full-screen auxiliary, resizable, movable")
    func windowSpecLiteral() {
        let expected = PanelWindowSpec(
            isNonActivating: true, isFloating: true, joinsAllSpaces: true, isFullScreenAuxiliary: true,
            ignoresWindowCycling: false, hidesOnDeactivate: false, isResizable: true, isMovableByBackground: true)
        #expect(LibraryPanelDriver.windowSpec == expected)
    }

    // Opening and closing never changes who is frontmost: the driver reads it once per open and has no way to set it.
    @Test("AC-003-01 the other app stays the frontmost app across an open and a close")
    func otherAppStaysFrontmost() async {
        let rig = PanelRig(frontmost: textEdit)
        await rig.press()
        #expect(rig.frontmost.current == textEdit)
        await rig.press()
        #expect(rig.frontmost.current == textEdit)
        #expect(rig.frontmost.reads == 1)
    }
}
