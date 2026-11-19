import CoreGraphics
import FlotsamBase
import FlotsamPaste
import FlotsamStorage
import Foundation
import Testing
@testable import FlotsamLibrary

/// TASK-535 adversarial QA (FR-003-03, FR-003-06, FR-003-08, FR-003-14, AC-003-21, AC-008-15). Expected values are
/// literals from the FRD and the parity dossier, never read back from the code under test. The App target's views and
/// `windowDidEndLiveResize` have no test target; the model, driver and settings halves are exercised here and the
/// rest is listed as real-display checks in the verdict.

@MainActor
private final class W535Presenter: LibraryPanelPresenter {
    var isVisible = false
    var shown: [(frame: CGRect, minimum: PanelSize)] = []
    func show(at frame: CGRect, minimumSize: PanelSize) {
        shown.append((frame, minimumSize))
        isVisible = true
    }
    func hide() { isVisible = false }
}

@MainActor
private final class W535Frontmost: FrontmostAppProvider {
    func frontmost() -> FrontmostApp? { FrontmostApp(bundleId: "com.apple.TextEdit", processId: 411) }
}

@MainActor
private final class W535Screens: LibraryScreenProvider {
    var pointerLocation = CGPoint(x: 100, y: 100)
    var screens: [LibraryScreen]
    var mainScreen: LibraryScreen?
    init(visible: CGRect) {
        let main = LibraryScreen(frame: CGRect(x: visible.minX, y: visible.minY, width: visible.width, height: visible.height + 30), visibleFrame: visible)
        screens = [main]
        mainScreen = main
    }
}

private final class W535InvalidLog: @unchecked Sendable {
    private let lock = NSLock()
    private var keys: [String] = []
    func record(_ key: String) { lock.withLock { keys.append(key) } }
    var recorded: [String] { lock.withLock { keys } }
}

@MainActor
@Suite struct Worf535CompactAdversarialTests {
    private func key(_ input: LibraryKeyInput, _ modifiers: ChordModifiers = []) -> LibraryKeyStroke { LibraryKeyStroke(input, modifiers) }

    /// A compact harness with `count` rows, opened, with the preview showing row 0.
    private func compactWithPreview(rows count: Int = 3) async -> Harness {
        let harness = Harness(rows: Harness.rows(count))
        harness.prefs.layout = .compact
        await harness.model.open(target: FrontmostApp(bundleId: "com.apple.TextEdit", processId: 411))
        harness.model.perform(.togglePreview)
        await harness.model.awaitPreview()
        return harness
    }

    // MARK: 1. Keyboard with the preview standing in for the list

    // Red if `escape()` closes the panel while the preview is open, or closes both in one press.
    @Test func compactEsc_closesThePreviewFirstAndThePanelSecond_notBoth() async {
        let harness = await compactWithPreview()
        #expect(harness.model.isPreviewOpen)
        harness.model.perform(.escape)
        #expect(!harness.model.isPreviewOpen)
        #expect(harness.model.columns.showsList)
        #expect(harness.host.hideCount == 0, "first Esc only returns the list")
        harness.model.perform(.escape)
        #expect(harness.host.hideCount == 1, "second Esc closes the panel, once")
    }

    // Red if the ladder order (search, preview, panel) is reordered for Compact.
    @Test func compactEsc_ladderWithSearchAndPreview_takesThreePressesInOrder() async {
        let harness = await compactWithPreview(rows: 4)
        harness.model.setSearchText("item")
        await harness.model.settled()
        #expect(harness.model.isPreviewOpen)

        harness.model.perform(.escape)
        #expect(harness.model.searchText.isEmpty)
        #expect(harness.model.isPreviewOpen, "press 1 clears the search only")
        #expect(harness.host.hideCount == 0)
        harness.model.perform(.escape)
        #expect(!harness.model.isPreviewOpen, "press 2 closes the preview only")
        #expect(harness.host.hideCount == 0)
        harness.model.perform(.escape)
        #expect(harness.host.hideCount == 1, "press 3 closes the panel")
    }

    // With two rows selected and the preview closed, Esc falls back to one row before it closes the panel.
    @Test func compactEsc_multiSelectFallsBackToOneRowBeforeClosing() async {
        let harness = Harness(rows: Harness.rows(4))
        harness.prefs.layout = .compact
        await harness.model.open(target: nil)
        harness.model.perform(.extend(.down))
        #expect(harness.model.selection.count == 2)
        harness.model.perform(.escape)
        #expect(harness.model.selection.count == 1)
        #expect(harness.host.hideCount == 0)
        harness.model.perform(.escape)
        #expect(harness.host.hideCount == 1)
    }

    // Red if ↑/↓ stop driving the selection or the preview does not follow it while it replaces the list.
    @Test func compactPreview_followsTheSelection_downThenUp_withStableIdentity() async {
        let harness = await compactWithPreview(rows: 3)
        let rows = harness.model.visibleRows.map(\.id)
        #expect(harness.model.preview?.itemId == rows[0])

        #expect(harness.model.handle(key(.down)))
        await harness.model.awaitPreview()
        #expect(harness.model.selection == [rows[1]])
        #expect(harness.model.preview?.itemId == rows[1])

        #expect(harness.model.handle(key(.down)))
        await harness.model.awaitPreview()
        #expect(harness.model.preview?.itemId == rows[2])

        // Past the last row: the selection stays, so does the preview.
        #expect(harness.model.handle(key(.down)))
        await harness.model.awaitPreview()
        #expect(harness.model.preview?.itemId == rows[2])

        #expect(harness.model.handle(key(.up)))
        await harness.model.awaitPreview()
        #expect(harness.model.preview?.itemId == rows[1])
        #expect(harness.model.isPreviewOpen)
        #expect(harness.model.visibleRows.count == 3)
    }

    // Red if Return, ⌘C, ⌘K or ⌘Delete act on the row the list last showed instead of the row the preview shows.
    @Test func compactPreview_returnCopyShortcutAndDelete_actOnThePreviewedRow() async {
        let harness = await compactWithPreview(rows: 3)
        let rows = harness.model.visibleRows.map(\.id)
        harness.model.handle(key(.down))
        await harness.model.awaitPreview()

        harness.model.handle(key(.returnKey))
        await harness.model.pasteTask?.value
        #expect(harness.paster.calls.count == 1)
        #expect(harness.paster.calls.first?.itemId == rows[1])
        #expect(harness.paster.calls.first?.mode == .paste)

        harness.model.handle(key(.character("c"), .command))
        await harness.model.pasteTask?.value
        #expect(harness.paster.calls.count == 2)
        #expect(harness.paster.calls.last?.itemId == rows[1])
        #expect(harness.paster.calls.last?.mode == .copyOnly)

        harness.model.handle(key(.delete, .command))
        #expect(harness.reported.external.count == 1)
        #expect(harness.reported.external.first?.0 == .delete)
        #expect(harness.reported.external.first?.1 == [rows[1]])

        // ⌘K hides the panel first and hands over exactly the previewed row.
        harness.model.handle(key(.character("k"), .command))
        #expect(harness.reported.external.count == 2)
        #expect(harness.reported.external.last?.0 == .shortcutAndTrigger)
        #expect(harness.reported.external.last?.1 == [rows[1]])
        #expect(harness.host.hideCount == 1)
    }

    // Red if ⌘1…⌘9 resolve against the hidden list's rows incorrectly while the preview is shown.
    @Test func compactPreview_commandDigit_pastesThatVisibleRow_andMovesThePreviewToIt() async {
        let harness = await compactWithPreview(rows: 3)
        let rows = harness.model.visibleRows.map(\.id)
        harness.model.handle(key(.character("3"), .command))
        await harness.model.pasteTask?.value
        #expect(harness.paster.calls.map(\.itemId) == [rows[2]])
        #expect(harness.model.selection == [rows[2]])
    }

    // Red if a keystroke that belongs to the search field is swallowed while the preview is open, or Space toggles
    // the preview while the search holds text.
    @Test func compactPreview_typingGoesToTheSearchField_andSpaceWithTextDoesNotToggle() async {
        let harness = await compactWithPreview()
        #expect(!harness.model.handle(key(.character("a"))), "a letter is the field's")
        harness.model.setSearchText("item 1")
        await harness.model.settled()
        await harness.model.awaitPreview()
        #expect(!harness.model.handle(key(.space)), "Space types a space once the search has text")
        #expect(harness.model.isPreviewOpen, "the preview is untouched by typing")
        #expect(harness.model.selection.count == 1)
        #expect(harness.model.preview?.itemId == harness.model.selectedRow?.id)
    }

    // Space/⌘Y both close the preview, and the list returns, in Compact.
    @Test func compactPreview_spaceAndCommandY_toggleBothWays() async {
        let harness = await compactWithPreview()
        #expect(harness.model.handle(key(.space)))
        #expect(harness.model.columns.preview == .hidden)
        #expect(harness.model.handle(key(.character("y"), .command)))
        #expect(harness.model.columns.preview == .replacesList)
        #expect(harness.model.handle(key(.character("y"), .command)))
        #expect(harness.model.columns.showsList)
    }

    // Multi-select while the preview replaces the list: no preview for several rows, Return does not paste (FR-003-08).
    @Test func compactPreview_withTwoRowsSelected_hasNoPreviewAndPasteKeysAreDisabled() async {
        let harness = await compactWithPreview(rows: 3)
        harness.model.handle(key(.down, .shift))
        await harness.model.awaitPreview()
        #expect(harness.model.selection.count == 2)
        #expect(harness.model.preview == nil)
        harness.model.handle(key(.returnKey))
        await harness.model.pasteTask?.value
        #expect(harness.paster.calls.isEmpty)
    }

    // MARK: 1b. Defects found: states whose only visible home is the list column

    // The list column carries the "no results" message (FR-003-17). In Compact the open preview takes that column's
    // place, so a search with no match leaves the user a blank "preview unavailable" pane and no "No results" message.
    // Known issue (TASK-535 QA finding F1); this test turns green, and the `withKnownIssue` wrapper starts failing, when
    // the layout keeps the results-state message visible.
    @Test func compactPreview_noResultsMessageIsStillVisible() async {
        let harness = await compactWithPreview(rows: 3)
        harness.model.setSearchText("zzz-no-match")
        await harness.model.settled()
        #expect(harness.model.isNoResults)
        withKnownIssue("F1: the preview hides the list column that carries the no-results message") {
            #expect(harness.model.columns.showsList)
        }
    }

    // Same for a failed load: the inline error and its Retry button live in the list column (FR-003-20).
    @Test func compactPreview_loadFailureWithRetryIsStillVisible() async {
        let harness = await compactWithPreview(rows: 3)
        harness.source.failItems = FlotsamError(.stoDb004, "query failed")
        await harness.model.retry()
        guard case .failed = harness.model.loadState else {
            Issue.record("expected the load to fail")
            return
        }
        withKnownIssue("F1: the preview hides the list column that carries the error and Retry") {
            #expect(harness.model.columns.showsList)
        }
    }

    // MARK: 2. Layout switch, saved sizes, hostile values

    // Red if the driver's frame/minimum come from the layout at the previous open rather than the one just loaded.
    @Test func driver_switchingLayoutBetweenOpens_usesThatLayoutsSizeAndMinimumEachTime() async {
        let harness = Harness(rows: Harness.rows(3))
        harness.prefs.panelSize = PanelSize(width: 900, height: 600)
        harness.prefs.compactPanelSize = PanelSize(width: 500, height: 450)
        let presenter = W535Presenter()
        let screens = W535Screens(visible: CGRect(x: 0, y: 0, width: 1440, height: 870))
        let driver = LibraryPanelDriver(
            model: harness.model, frontmost: W535Frontmost(), screens: screens, preferences: harness.prefs, captureNow: {})
        driver.presenter = presenter

        harness.prefs.layout = .compact
        driver.toggle()
        await driver.showTask?.value
        driver.toggle()
        harness.prefs.layout = .standard
        driver.toggle()
        await driver.showTask?.value
        driver.toggle()
        harness.prefs.layout = .compact
        driver.toggle()
        await driver.showTask?.value

        #expect(presenter.shown.count == 3)
        #expect(presenter.shown.map(\.frame.size) == [CGSize(width: 500, height: 450), CGSize(width: 900, height: 600), CGSize(width: 500, height: 450)])
        #expect(presenter.shown.map(\.minimum) == [
            PanelSize(width: 480, height: 400), PanelSize(width: 560, height: 360), PanelSize(width: 480, height: 400),
        ])
        // Neither key was touched by merely opening.
        #expect(harness.prefs.panelSize == PanelSize(width: 900, height: 600))
        #expect(harness.prefs.compactPanelSize == PanelSize(width: 500, height: 450))
    }

    // The model's layout is the one the panel opened in; a Settings change while it is shown does not flip the columns
    // (and so does not flip which size key a live resize writes to) until the next open.
    @Test func model_layoutChangedInSettingsWhileShown_waitsForTheNextOpen() async {
        let harness = Harness(rows: Harness.rows(2))
        harness.prefs.layout = .compact
        await harness.model.open(target: nil)
        harness.prefs.layout = .standard
        harness.model.perform(.togglePreview)
        #expect(harness.model.layout == .compact)
        #expect(harness.model.columns.preview == .replacesList)
        await harness.model.open(target: nil)
        #expect(harness.model.layout == .standard)
        #expect(harness.model.columns.preview == .hidden, "open resets the preview")
    }

    // A remembered Compact size below the minimum, and one far larger than the screen (external display unplugged).
    @Test func compactFrame_belowMinimumIsRaised_andLargerThanTheScreenIsCutToIt() async {
        let laptop = CGRect(x: 0, y: 0, width: 1280, height: 775)
        let harness = Harness(rows: Harness.rows(2))
        harness.prefs.layout = .compact
        let screens = W535Screens(visible: laptop)
        let presenter = W535Presenter()
        let driver = LibraryPanelDriver(
            model: harness.model, frontmost: W535Frontmost(), screens: screens, preferences: harness.prefs, captureNow: {})
        driver.presenter = presenter

        harness.prefs.compactPanelSize = PanelSize(width: 300, height: 200)
        driver.toggle()
        await driver.showTask?.value
        driver.toggle()
        #expect(presenter.shown[0].frame.size == CGSize(width: 480, height: 400), "raised to 480 x 400, not to Standard's 560 x 360")

        harness.prefs.compactPanelSize = PanelSize(width: 3000, height: 2000)  // last seen on a 4K display
        driver.toggle()
        await driver.showTask?.value
        let big = presenter.shown[1].frame
        #expect(big.size == CGSize(width: 1280, height: 775))
        #expect(laptop.contains(big), "the panel never opens off the screen")
        #expect(big.minX == 0 && big.minY == 0)
    }

    // Hostile stored values through the real store: each falls back to its default and raises one SET-DAT-001 hook per
    // key (FR-008-02), and the bad value is gone from the store afterwards.
    @Test(arguments: [
        ("library.compactPanelSize", "0x0", "520.0x520.0"), ("library.compactPanelSize", "-5x300", "520.0x520.0"),
        ("library.compactPanelSize", "nanx300", "520.0x520.0"), ("library.compactPanelSize", "infx300", "520.0x520.0"),
        ("library.compactPanelSize", "banana", "520.0x520.0"), ("library.compactPanelSize", "", "520.0x520.0"),
        ("library.layout", "squarish", "standard"), ("library.layout", "Compact", "standard"),
        ("library.layout", "", "standard"), ("library.layout", " compact", "standard"),
    ])
    func hostileStoredValues_fallBackToTheDefault_andRaiseOneInvalidNoticePerKey(name: String, stored: String, expected: String) {
        let kv = ContractMemoryKV()
        let log = W535InvalidLog()
        let store = SettingsStore(store: kv, onInvalid: { log.record($0) })
        kv.setString(stored, forKey: name)
        let prefs = SettingsLibraryPreferences(settings: store)

        let first = name == "library.layout" ? prefs.layout.persisted : prefs.compactPanelSize.persisted
        let second = name == "library.layout" ? prefs.layout.persisted : prefs.compactPanelSize.persisted
        #expect(first == expected)
        #expect(second == expected)
        #expect(log.recorded == [name], "one notice per launch per key, not per read")
        #expect(kv.string(forKey: name) == expected, "the default is written back over the bad value")
    }

    // A valid but tiny/odd compact size is kept as stored (the clamp is the layout's job), and does not touch Standard.
    @Test func validOddCompactSize_roundTripsThroughAFreshStore_andStandardIsUntouched() {
        let kv = ContractMemoryKV()
        SettingsLibraryPreferences(settings: SettingsStore(store: kv)).setPanelSize(PanelSize(width: 100.5, height: 90), for: .compact)
        let fresh = SettingsLibraryPreferences(settings: SettingsStore(store: kv))
        #expect(fresh.compactPanelSize == PanelSize(width: 100.5, height: 90))
        #expect(fresh.panelSize == PanelSize(width: 760, height: 480))
        #expect(kv.string(forKey: "library.panelSize") == nil, "Standard's key is never written by a Compact resize")
    }

    // MARK: 3. A hand-edited layout opens the Standard layout end to end

    @Test func handEditedLayout_opensStandardWithStandardSizeAndPreviewPane() async {
        let kv = ContractMemoryKV()
        kv.setString("tiny", forKey: "library.layout")
        let prefs = SettingsLibraryPreferences(settings: SettingsStore(store: kv))
        let source = FakeSource(rows: Harness.rows(2))
        let model = LibraryViewModel(
            source: source, paster: FakePaster(), host: FakeHost(), preferences: prefs,
            effects: LibraryEffects(
                report: { _ in }, reveal: { _ in }, openSettings: {}, external: { _, _ in }, isAccessibilityTrusted: { true }))
        let presenter = W535Presenter()
        let driver = LibraryPanelDriver(
            model: model, frontmost: W535Frontmost(), screens: W535Screens(visible: CGRect(x: 0, y: 0, width: 1440, height: 870)),
            preferences: prefs, captureNow: {})
        driver.presenter = presenter
        driver.toggle()
        await driver.showTask?.value
        #expect(presenter.shown.first?.frame.size == CGSize(width: 760, height: 480))
        #expect(presenter.shown.first?.minimum == PanelSize(width: 560, height: 360))
        model.perform(.togglePreview)
        #expect(model.columns.preview == .rightPane)
    }

    // MARK: 4. Secure items, empty library

    // The preview in Compact still shows the mask for a secure row, never its text (AC-003-19).
    @Test func compactPreview_ofASecureRow_showsTheMaskNotTheText() async {
        let harness = Harness(rows: [makeRow(0, secure: true), makeRow(1)])
        harness.source.content = ItemContent(kind: .text, plainText: "hunter2-secret", representations: [], members: [])
        harness.prefs.layout = .compact
        await harness.model.open(target: nil)
        harness.model.perform(.togglePreview)
        await harness.model.awaitPreview()
        #expect(harness.model.selectedRow?.isSecure == true)
        let shown = harness.model.preview?.text(showingAll: true)
        #expect(shown?.contains("hunter2-secret") == false)
        #expect(harness.model.columns.preview == .replacesList)
    }

    // Empty history: Space in Compact must not crash, selects nothing, and Esc still unwinds preview then panel.
    @Test func compactPreview_onAnEmptyLibrary_hasNoPreview_andEscUnwinds() async {
        let harness = Harness(rows: [])
        harness.prefs.layout = .compact
        await harness.model.open(target: nil)
        harness.model.perform(.togglePreview)
        await harness.model.awaitPreview()
        #expect(harness.model.isHistoryEmpty)
        #expect(harness.model.preview == nil)
        #expect(harness.model.selection.isEmpty)
        harness.model.perform(.escape)
        #expect(!harness.model.isPreviewOpen)
        #expect(harness.host.hideCount == 0)
        harness.model.perform(.escape)
        #expect(harness.host.hideCount == 1)
    }
}
