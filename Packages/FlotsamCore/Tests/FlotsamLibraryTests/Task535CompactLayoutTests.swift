import CoreGraphics
import FlotsamBase
import FlotsamPaste
import Foundation
import Testing
@testable import FlotsamLibrary

/// TASK-535 (FR-003-03, FR-003-06, FR-008-01): the Compact layout. Expected values are literals from the FRD and
/// `docs/research/linkhiv-parity.md` T3 (520 x 520 default, 480 x 400 minimum, no preview column), not read back from
/// the code under test.

@MainActor
private final class SizeRecorder: LibraryPanelPresenter {
    var isVisible = false
    var shown: [(frame: CGRect, minimum: PanelSize)] = []
    func show(at frame: CGRect, minimumSize: PanelSize) {
        shown.append((frame, minimumSize))
        isVisible = true
    }
    func hide() { isVisible = false }
}

@MainActor
private final class StillFrontmost: FrontmostAppProvider {
    func frontmost() -> FrontmostApp? { FrontmostApp(bundleId: "com.apple.TextEdit", processId: 411) }
}

@MainActor
private final class OneScreen: LibraryScreenProvider {
    var pointerLocation = CGPoint(x: 100, y: 100)
    var screens: [LibraryScreen]
    var mainScreen: LibraryScreen?
    init() {
        let main = LibraryScreen(
            frame: CGRect(x: 0, y: 0, width: 1440, height: 900), visibleFrame: CGRect(x: 0, y: 0, width: 1440, height: 870))
        screens = [main]
        mainScreen = main
    }
}

@MainActor
@Suite struct Task535CompactLayoutTests {
    // MARK: Which columns exist (LibraryColumns)

    @Test func columns_previewClosed_isHiddenAndListShownInBothLayouts() {
        for layout in LibraryLayoutMode.allCases {
            let columns = LibraryColumns.resolve(layout: layout, previewOpen: false)
            #expect(columns.preview == .hidden, "\(layout)")
            #expect(columns.showsList, "\(layout)")
        }
    }

    @Test func columns_standardPreviewOpen_isARightPaneAndTheListStays() {
        let columns = LibraryColumns.resolve(layout: .standard, previewOpen: true)
        #expect(columns.preview == .rightPane)
        #expect(columns.showsList)
    }

    @Test func columns_compactPreviewOpen_replacesTheList() {
        let columns = LibraryColumns.resolve(layout: .compact, previewOpen: true)
        #expect(columns.preview == .replacesList)
        #expect(!columns.showsList)
    }

    // MARK: Geometry

    @Test func minimumSizes_areThePerLayoutLiterals() {
        #expect(LibraryLayout.minimumSize(for: .standard) == PanelSize(width: 560, height: 360))
        #expect(LibraryLayout.minimumSize(for: .compact) == PanelSize(width: 480, height: 400))
    }

    @Test func clamped_raisesToThePerLayoutMinimum_andDefaultsToStandard() {
        let tiny = PanelSize(width: 100, height: 100)
        #expect(LibraryLayout.clamped(tiny, layout: .compact) == PanelSize(width: 480, height: 400))
        #expect(LibraryLayout.clamped(tiny, layout: .standard) == PanelSize(width: 560, height: 360))
        #expect(LibraryLayout.clamped(tiny) == PanelSize(width: 560, height: 360))
        // At or above the minimum nothing changes, per axis.
        #expect(LibraryLayout.clamped(PanelSize(width: 481, height: 399), layout: .compact) == PanelSize(width: 481, height: 400))
        #expect(LibraryLayout.clamped(PanelSize(width: 479, height: 401), layout: .compact) == PanelSize(width: 480, height: 401))
    }

    @Test func compactFrame_isCentredAndAThirdDown() {
        let visible = CGRect(x: 0, y: 0, width: 1440, height: 870)
        let frame = LibraryLayout.frame(in: visible, size: PanelSize(width: 520, height: 520), layout: .compact)
        #expect(frame == CGRect(x: 460, y: 60, width: 520, height: 520))
        // A remembered size below the compact minimum is raised to it, not to the Standard minimum.
        let small = LibraryLayout.frame(in: visible, size: PanelSize(width: 400, height: 380), layout: .compact)
        #expect(small.size == CGSize(width: 480, height: 400))
    }

    // MARK: The driver opens in the layout the model loaded

    @Test func driver_compact_opensAtTheCompactSizeWithTheCompactMinimum() async {
        let harness = Harness(rows: Harness.rows(3))
        harness.prefs.layout = .compact
        harness.prefs.panelSize = PanelSize(width: 900, height: 600)
        harness.prefs.compactPanelSize = PanelSize(width: 600, height: 560)
        let presenter = SizeRecorder()
        let driver = LibraryPanelDriver(
            model: harness.model, frontmost: StillFrontmost(), screens: OneScreen(), preferences: harness.prefs, captureNow: {})
        driver.presenter = presenter
        driver.toggle()
        await driver.showTask?.value
        #expect(presenter.shown.count == 1)
        #expect(presenter.shown.first?.frame == CGRect(x: 420, y: 20, width: 600, height: 560))
        #expect(presenter.shown.first?.minimum == PanelSize(width: 480, height: 400))
    }

    @Test func driver_standard_ignoresTheCompactSize() async {
        let harness = Harness(rows: Harness.rows(3))
        harness.prefs.compactPanelSize = PanelSize(width: 600, height: 560)
        let presenter = SizeRecorder()
        let driver = LibraryPanelDriver(
            model: harness.model, frontmost: StillFrontmost(), screens: OneScreen(), preferences: harness.prefs, captureNow: {})
        driver.presenter = presenter
        driver.toggle()
        await driver.showTask?.value
        #expect(presenter.shown.first?.frame == CGRect(x: 340, y: 100, width: 760, height: 480))
        #expect(presenter.shown.first?.minimum == PanelSize(width: 560, height: 360))
    }

    // MARK: The model reads the layout at each open

    @Test func model_readsTheLayoutAtEachOpen() async {
        let harness = Harness(rows: Harness.rows(3))
        #expect(harness.model.layout == .standard)
        harness.prefs.layout = .compact
        await harness.model.open(target: nil)
        #expect(harness.model.layout == .compact)
        harness.prefs.layout = .standard
        await harness.model.open(target: nil)
        #expect(harness.model.layout == .standard)
    }

    @Test func model_previewPlacementFollowsTheLayout_andEscReturnsTheList() async {
        let harness = Harness(rows: Harness.rows(3))
        harness.prefs.layout = .compact
        await harness.model.open(target: nil)
        #expect(harness.model.columns.preview == .hidden)
        harness.model.perform(.togglePreview)
        #expect(harness.model.isPreviewOpen)
        #expect(harness.model.columns.preview == .replacesList)
        #expect(!harness.model.columns.showsList)
        // The selection survives, so arrows still move the preview's item (FR-003-14: opening never changes it).
        #expect(harness.model.selection.count == 1)
        harness.model.perform(.togglePreview)
        #expect(harness.model.columns.preview == .hidden)
        #expect(harness.model.columns.showsList)

        harness.prefs.layout = .standard
        await harness.model.open(target: nil)
        harness.model.perform(.togglePreview)
        #expect(harness.model.columns.preview == .rightPane)
    }

    // MARK: Settings values (FR-008-01)

    @Test func settings_defaultsAndPersistenceAreKeptPerLayout() {
        let kv = ContractMemoryKV()
        let prefs = SettingsLibraryPreferences(settings: SettingsStore(store: kv))
        #expect(prefs.layout == .standard)
        #expect(prefs.panelSize == PanelSize(width: 760, height: 480))
        #expect(prefs.compactPanelSize == PanelSize(width: 520, height: 520))

        prefs.layout = .compact
        prefs.setPanelSize(PanelSize(width: 610, height: 590), for: .compact)
        // Resizing in Compact leaves the Standard size alone ...
        #expect(prefs.panelSize == PanelSize(width: 760, height: 480))
        prefs.setPanelSize(PanelSize(width: 880, height: 700), for: .standard)
        // ... and the reverse.
        #expect(prefs.compactPanelSize == PanelSize(width: 610, height: 590))
        #expect(prefs.panelSize(for: .compact) == PanelSize(width: 610, height: 590))
        #expect(prefs.panelSize(for: .standard) == PanelSize(width: 880, height: 700))

        let relaunched = SettingsLibraryPreferences(settings: SettingsStore(store: kv))
        #expect(relaunched.layout == .compact)
        #expect(relaunched.compactPanelSize == PanelSize(width: 610, height: 590))
        #expect(relaunched.panelSize == PanelSize(width: 880, height: 700))
    }

    @Test func settings_anUnknownLayoutReadsStandard() {
        let kv = ContractMemoryKV()
        kv.setString("squarish", forKey: "library.layout")
        let prefs = SettingsLibraryPreferences(settings: SettingsStore(store: kv))
        #expect(prefs.layout == .standard)
    }
}
