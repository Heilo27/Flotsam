import FlotsamBase
import FlotsamPaste
import Foundation
import Testing
@testable import FlotsamLibrary

// TASK-524, FR-003-02: opening a Flotsam window from the Library (Settings with ⌘,, the item shortcut editor with ⌘K)
// hides the Library, whatever state that window was in. S2's real-OS run: Settings closed hid the Library (as a side
// effect of the new window taking key); Settings minimized brought Settings back from the Dock and left the Library
// above it. The rule is the Library's own and does not wait for AppKit to move key, so these fakes never move key: they
// only record whether the Library was still on screen at the moment the window was ordered front.

private final class Task524KV: KeyValueStore, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: String] = [:]
    func string(forKey key: String) -> String? { lock.withLock { values[key] } }
    func setString(_ value: String, forKey key: String) { lock.withLock { values[key] = value } }
    func removeValue(forKey key: String) { lock.withLock { _ = values.removeValue(forKey: key) } }
}

/// The Settings window as the driver sees it. `isMiniaturized` is what the S2 run varied; bringing the window to the
/// front records the Library's visibility then and nothing else: it does not resign the Library's key.
@MainActor
private final class Task524SettingsWindow: SettingsWindowHandle {
    unowned let rig: Task524Rig
    var isMiniaturized = false
    init(rig: Task524Rig) { self.rig = rig }
    func select(_ pane: SettingsPane) {}
    func bringToFront() {
        rig.fronted.append((libraryVisible: rig.host.isPanelVisible, miniaturized: isMiniaturized))
    }
}

@MainActor
private final class Task524Presenter: SettingsWindowPresenter {
    unowned let rig: Task524Rig
    init(rig: Task524Rig) { self.rig = rig }
    func makeWindow(items: [SettingsPaneItem], didSelect: @escaping @MainActor (SettingsPane) -> Void) -> any SettingsWindowHandle {
        let window = Task524SettingsWindow(rig: rig)
        rig.window = window
        return window
    }
}

@MainActor
private final class Task524Rig {
    let host = FakeHost()
    let source: FakeSource
    var model: LibraryViewModel!
    var settings: SettingsWindowDriver!
    var presenter: Task524Presenter!
    var window: Task524SettingsWindow?
    /// Each time a Flotsam window was ordered front: was the Library still visible, was that window miniaturized.
    var fronted: [(libraryVisible: Bool, miniaturized: Bool)] = []
    /// The shortcut editor: the Library's visibility at the moment it opened, and for which item.
    var editorOpened: [(libraryVisible: Bool, id: UUID?)] = []
    var externalCalls: [(LibraryExternalCommand, [UUID])] = []

    init(rows: [ItemRow] = Harness.rows(3)) async {
        source = FakeSource(rows: rows)
        presenter = Task524Presenter(rig: self)
        settings = SettingsWindowDriver(settings: SettingsStore(store: Task524KV()))
        settings.presenter = presenter
        model = LibraryViewModel(
            source: source, paster: FakePaster(), host: host, preferences: FakePreferences(),
            effects: LibraryEffects(
                openSettings: { [unowned self] in settings.open() },
                external: { [unowned self] command, ids in
                    externalCalls.append((command, ids))
                    // The App's `actions.editShortcutAndTrigger`: it opens the editor for the one id the Library resolved.
                    guard command == .shortcutAndTrigger, let id = ids.first else { return }
                    editorOpened.append((libraryVisible: host.isPanelVisible, id: id))
                }))
        await model.open(target: FrontmostApp(bundleId: "com.apple.TextEdit", processId: 4242))
    }

    /// The Library is on screen again, as after the hotkey.
    func showLibrary() { host.isPanelVisible = true }
}

@MainActor
@Suite struct Task524WindowOpenHidesLibraryTests {
    // MARK: Settings, one test per state of the Settings window (AC 2)

    @Test func settingsClosed_commandCommaHidesTheLibraryBeforeSettingsIsFronted() async {
        let rig = await Task524Rig()
        #expect(rig.window == nil)
        rig.model.perform(.openSettings)
        #expect(rig.fronted.count == 1)
        #expect(rig.fronted.first?.libraryVisible == false)
        #expect(rig.host.hideCount == 1)
    }

    @Test func settingsOpenBehind_commandCommaHidesTheLibraryBeforeSettingsIsFronted() async {
        let rig = await Task524Rig()
        rig.model.perform(.openSettings)
        rig.showLibrary()
        #expect(rig.window?.isMiniaturized == false)
        rig.model.perform(.openSettings)
        #expect(rig.fronted.count == 2)
        #expect(rig.fronted.last?.libraryVisible == false)
        #expect(rig.host.hideCount == 2)
    }

    @Test func settingsMinimized_commandCommaHidesTheLibraryBeforeSettingsIsFronted() async {
        let rig = await Task524Rig()
        rig.model.perform(.openSettings)
        rig.showLibrary()
        rig.window?.isMiniaturized = true
        rig.model.perform(.openSettings)
        #expect(rig.fronted.count == 2)
        #expect(rig.fronted.last?.miniaturized == true)
        #expect(rig.fronted.last?.libraryVisible == false)
        #expect(rig.host.hideCount == 2)
    }

    // MARK: The item editor shares the path (⌘K and the context-menu row both arrive as `.external(.shortcutAndTrigger)`)

    @Test func shortcutEditorFromOneSelectedRow_hidesTheLibraryBeforeTheEditorOpens() async {
        let rig = await Task524Rig()
        let id = rig.model.selectedRows.first?.id
        #expect(rig.model.selectedRows.count == 1)
        rig.model.perform(.external(.shortcutAndTrigger))
        #expect(rig.editorOpened.count == 1)
        #expect(rig.editorOpened.first?.id == id)
        #expect(rig.editorOpened.first?.libraryVisible == false)
        #expect(rig.host.hideCount == 1)
    }

    // A secure item opens no editor (FR-005-09), so the Library must not hide for one: it would vanish and show nothing.
    @Test func shortcutEditorOnASecureSingleSelection_opensNothingAndTheLibraryStays() async {
        let rig = await Task524Rig(rows: [makeRow(0, secure: true), makeRow(1)])
        #expect(rig.model.selectedRows.count == 1)
        #expect(rig.model.selectedRows.first?.isSecure == true)
        #expect(!LibraryCommand.external(.shortcutAndTrigger).opensFlotsamWindow(selection: rig.model.selectedRows))
        rig.model.perform(.external(.shortcutAndTrigger))
        #expect(rig.editorOpened.isEmpty)
        #expect(rig.externalCalls.isEmpty)
        #expect(rig.host.hideCount == 0)
    }

    @Test func shortcutEditorWithSeveralRowsSelected_opensNothingAndTheLibraryStays() async {
        let rig = await Task524Rig()
        rig.model.perform(.extend(.down))
        #expect(rig.model.selectedRows.count == 2)
        rig.model.perform(.external(.shortcutAndTrigger))
        // The Library resolves the one target itself (TASK-526), so with several rows nothing reaches the app at all.
        #expect(rig.externalCalls.isEmpty)
        #expect(rig.editorOpened.isEmpty)
        #expect(rig.host.hideCount == 0)
    }

    @Test func shortcutEditorWithNothingSelected_opensNothingAndTheLibraryStays() async {
        let rig = await Task524Rig()
        rig.model.select(id: UUID())
        #expect(rig.model.selectedRows.isEmpty)
        rig.model.perform(.external(.shortcutAndTrigger))
        #expect(rig.editorOpened.isEmpty)
        #expect(rig.host.hideCount == 0)
    }

    // MARK: Commands that open no Flotsam window leave the Library alone

    @Test func otherCommandsDoNotHideTheLibraryOnTheWindowRule() async {
        let rig = await Task524Rig()
        for command: LibraryCommand in [.togglePreview, .toggleViewMode, .move(.down), .external(.pin), .external(.tags), .external(.edit)] {
            rig.model.perform(command)
        }
        #expect(rig.host.hideCount == 0)
        #expect(rig.fronted.isEmpty)
    }
}
