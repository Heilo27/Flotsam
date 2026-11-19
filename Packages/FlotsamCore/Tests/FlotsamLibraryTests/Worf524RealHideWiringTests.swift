import CoreGraphics
import FlotsamBase
import FlotsamPaste
import Foundation
import Testing
@testable import FlotsamLibrary

// Worf, TASK-524 adversarial pass. Obrien's tests host the model on `FakeHost`, whose `hidePanel` only flips a flag. The
// real host is `LibraryPanelDriver.hidePanel`, which also runs `model.panelDidHide()` (cancels loads, bumps the
// generation, drops the event subscription). `perform` reads the selection AGAIN after the hide to build the ids it
// hands the editor, so a real hide that disturbed the selection would open the editor for nobody while the Library had
// already gone. These tests run the real driver as the host.

@MainActor
private final class RealHidePresenter: LibraryPanelPresenter {
    var isVisible = false
    var hideCount = 0
    func show(at frame: CGRect) { isVisible = true }
    func hide() { hideCount += 1; isVisible = false }
}

@MainActor
private struct Frontmost: FrontmostAppProvider {
    func frontmost() -> FrontmostApp? { FrontmostApp(bundleId: "com.apple.TextEdit", processId: 4242) }
}

@MainActor
private struct Screens: LibraryScreenProvider {
    var pointerLocation: CGPoint { CGPoint(x: 100, y: 100) }
    var screens: [LibraryScreen] { [main] }
    var mainScreen: LibraryScreen? { main }
    private var main: LibraryScreen {
        LibraryScreen(frame: CGRect(x: 0, y: 0, width: 1440, height: 900), visibleFrame: CGRect(x: 0, y: 0, width: 1440, height: 870))
    }
}

/// The model needs its host and the host needs the model (the App's `HostBox`).
@MainActor
private final class HostBox: PasteHost {
    weak var target: LibraryPanelDriver?
    var isPanelVisible: Bool { target?.isPanelVisible ?? false }
    func hidePanel() { target?.hidePanel() }
}

@MainActor
private final class RealRig {
    let rows = Harness.rows(3)
    let source: FakeSource
    let paster = FakePaster()
    let presenter = RealHidePresenter()
    let driver: LibraryPanelDriver
    let model: LibraryViewModel
    /// What the Library looked like when each window command reached its effect.
    var settingsOpened: [(panelVisible: Bool, shown: Bool)] = []
    var externalCalls: [(command: LibraryExternalCommand, ids: [UUID], panelVisible: Bool)] = []

    init() async {
        source = FakeSource(rows: rows)
        let box = HostBox()
        var effectsHook: (@MainActor () -> Void)?
        var externalHook: (@MainActor (LibraryExternalCommand, [UUID]) -> Void)?
        model = LibraryViewModel(
            source: source, paster: paster, host: box, preferences: FakePreferences(),
            effects: LibraryEffects(
                openSettings: { effectsHook?() }, external: { externalHook?($0, $1) }))
        driver = LibraryPanelDriver(
            model: model, frontmost: Frontmost(), screens: Screens(), preferences: FakePreferences(), captureNow: {})
        driver.presenter = presenter
        box.target = driver
        effectsHook = { [unowned self] in settingsOpened.append((panelVisible: driver.isPanelVisible, shown: model.isShown)) }
        externalHook = { [unowned self] command, ids in
            externalCalls.append((command: command, ids: ids, panelVisible: driver.isPanelVisible))
        }
        await driver.show()
    }
}

@MainActor
@Suite struct Worf524RealHideWiringTests {
    @Test func commandComma_realHideRunsBeforeSettingsOpens_andModelIsNoLongerShown() async {
        let rig = await RealRig()
        #expect(rig.presenter.isVisible)
        rig.model.perform(.openSettings)
        #expect(rig.settingsOpened.count == 1)
        #expect(rig.settingsOpened.first?.panelVisible == false)
        #expect(rig.settingsOpened.first?.shown == false)
        #expect(rig.presenter.hideCount == 1)
    }

    @Test func commandK_selectionSurvivesTheRealHide_andTheEditorGetsTheSelectedItem() async {
        let rig = await RealRig()
        let selected = rig.model.selectedRows.map(\.id)
        #expect(selected == [rig.rows[0].id])
        rig.model.perform(.external(.shortcutAndTrigger))
        #expect(rig.externalCalls.count == 1)
        #expect(rig.externalCalls.first?.ids == [rig.rows[0].id])
        #expect(rig.externalCalls.first?.panelVisible == false)
        #expect(rig.presenter.hideCount == 1)
    }

    @Test func commandK_withTwoRowsSelected_realHostKeepsTheLibraryUp() async {
        let rig = await RealRig()
        rig.model.perform(.extend(.down))
        #expect(rig.model.selectedRows.count == 2)
        rig.model.perform(.external(.shortcutAndTrigger))
        #expect(rig.presenter.hideCount == 0)
        #expect(rig.presenter.isVisible)
        #expect(rig.model.isShown)
    }

    @Test func hidingForSettings_pastesNothing_andTheNextShowOpensFresh() async {
        let rig = await RealRig()
        rig.model.setSearchText("zzz")
        rig.model.perform(.openSettings)
        #expect(rig.paster.calls.isEmpty)
        await rig.driver.show()
        #expect(rig.presenter.isVisible)
        #expect(rig.model.isShown)
        #expect(rig.model.searchText.isEmpty)
        #expect(rig.model.selectedRows.map(\.id) == [rig.rows[0].id])
    }

    @Test func commandComma_whenTheLibraryIsAlreadyHidden_hidesAgainHarmlessly() async {
        let rig = await RealRig()
        rig.driver.hidePanel()
        #expect(rig.presenter.hideCount == 1)
        rig.model.perform(.openSettings)
        #expect(rig.presenter.hideCount == 1)
        #expect(rig.settingsOpened.count == 1)
    }

    // The one rule as a table: every command, literal expectation. Kills a mutant that widens or narrows the rule.
    @Test func opensFlotsamWindow_everyCommand() {
        let one = [makeRow(1)]
        let two = [makeRow(1), makeRow(2)]
        let opens: [(LibraryCommand, [ItemRow])] = [(.openSettings, []), (.openSettings, one), (.openSettings, two), (.external(.shortcutAndTrigger), one)]
        for (command, rows) in opens { #expect(command.opensFlotsamWindow(selection: rows), "\(command) \(rows.count)") }
        let closed: [(LibraryCommand, [ItemRow])] = [
            (.external(.shortcutAndTrigger), []), (.external(.shortcutAndTrigger), two),
            (.external(.pin), one), (.external(.tags), one), (.external(.note), one), (.external(.edit), one),
            (.external(.delete), one), (.external(.cycleSort), one), (.external(.ungroup), one),
            (.move(.down), one), (.extend(.down), one), (.jumpToFirst, one), (.jumpToLast, one),
            (.paste(.paste), one), (.pasteRow(1), one), (.togglePreview, one), (.escape, one),
            (.previousFilter, one), (.nextFilter, one), (.toggleViewMode, one), (.revealInFinder, one),
        ]
        // A secure item opens no editor, so a lone secure selection does not hide the Library either.
        #expect(!LibraryCommand.external(.shortcutAndTrigger).opensFlotsamWindow(selection: [makeRow(3, secure: true)]))
        for (command, rows) in closed { #expect(!command.opensFlotsamWindow(selection: rows), "\(command) \(rows.count)") }
    }
}
