import Foundation
import Testing
@testable import FlotsamBase

// AC-008-03 / OC-8024 (TASK-086). The decisions behind the Settings window run in `SettingsWindowDriver` with a fake
// window; what only a real window can show (key and front under a real process, Tab and Space focus, VoiceOver speech)
// stays in the live-app matrix, TASK-518.

@MainActor
private final class FakeWindow: SettingsWindowHandle {
    unowned let presenter: FakePresenter
    init(presenter: FakePresenter) { self.presenter = presenter }
    func select(_ pane: SettingsPane) { presenter.log.append("select:\(pane.rawValue)") }
    func bringToFront() { presenter.log.append("front") }
}

@MainActor
private final class FakePresenter: SettingsWindowPresenter {
    var log: [String] = []
    private(set) var windows: [FakeWindow] = []
    private(set) var itemsSeen: [[SettingsPaneItem]] = []
    /// The callback the window was given: what a click on a toolbar button calls.
    private(set) var didSelect: (@MainActor (SettingsPane) -> Void)?
    /// What a real tab controller does while it is built: it reports its first tab as selected.
    var selectionReportedWhileBuilding: SettingsPane?

    func makeWindow(items: [SettingsPaneItem], didSelect: @escaping @MainActor (SettingsPane) -> Void) -> any SettingsWindowHandle {
        itemsSeen.append(items)
        self.didSelect = didSelect
        log.append("make")
        if let pane = selectionReportedWhileBuilding { didSelect(pane) }
        let window = FakeWindow(presenter: self)
        windows.append(window)
        return window
    }
}

@MainActor
private struct Rig {
    let suite = TestDefaultsSuite("frd008.window")
    let presenter = FakePresenter()
    let driver: SettingsWindowDriver

    init() {
        let driver = SettingsWindowDriver(settings: Rig.launch(suite))
        driver.presenter = presenter
        self.driver = driver
    }

    /// A fresh `SettingsStore` over the same defaults domain: what a relaunch sees.
    static func launch(_ suite: TestDefaultsSuite) -> SettingsStore {
        SettingsStore(store: UserDefaultsStore(defaults: suite.defaults))
    }

    func relaunched() -> (SettingsWindowDriver, FakePresenter) {
        let presenter = FakePresenter()
        let driver = SettingsWindowDriver(settings: Rig.launch(suite))
        driver.presenter = presenter
        return (driver, presenter)
    }

    func wipe() { suite.remove() }
}

@MainActor
@Suite("FRD-008 AC-008-03: Settings window driver") struct Frd008SettingsWindowDriverTests {
    // OC-8024 (window count). Opening twice builds one window, and both opens bring it to the front.
    @Test("OC-8024: opening Settings again reuses the one window and brings it to the front each time")
    func singleWindowRefocused() {
        let rig = Rig(); defer { rig.wipe() }
        rig.driver.open()
        rig.driver.open()
        rig.driver.open()

        #expect(rig.presenter.windows.count == 1, "one window however often it is opened")
        #expect(rig.presenter.log.filter { $0 == "make" }.count == 1)
        #expect(rig.presenter.log.filter { $0 == "front" }.count == 3, "every open asks the window to come forward")
    }

    // OC-8024 (key and front). Selecting the pane happens before the window is ordered front, so it never flashes the wrong pane.
    @Test("OC-8024: the pane is selected, then the window is brought to the front")
    func selectThenFront() {
        let rig = Rig(); defer { rig.wipe() }
        rig.driver.open()
        #expect(rig.presenter.log == ["make", "select:general", "front"])
        rig.driver.open()
        #expect(rig.presenter.log.suffix(2) == ["select:general", "front"])
    }

    // OC-8023. The panes are handed to the window in the FRD-008 order, with titles and icons.
    @Test("OC-8023: the window is built with the eight panes in the stated order")
    func paneOrderHandedToWindow() {
        let rig = Rig(); defer { rig.wipe() }
        rig.driver.open()
        let items = rig.presenter.itemsSeen.first ?? []
        #expect(items.map(\.pane) == [.general, .library, .shortcuts, .types, .triggers, .privacy, .storage, .tips, .about])
        #expect(items.map(\.label) == ["General", "Library", "Shortcuts", "Types", "Triggers", "Privacy", "Storage", "Tips", "About"])
        #expect(items.map(\.symbolName) == ["gearshape", "list.bullet.rectangle", "keyboard", "square.grid.2x2", "bolt", "hand.raised", "internaldrive", "lightbulb", "info.circle"])
        #expect(items == SettingsWindowDriver.items)
    }

    // OC-8025 (reopen). The pane picked in the window is the one the next open selects, on the same window.
    @Test("OC-8025: reopening selects the pane last used, on the same window")
    func reopensOnLastPane() {
        let rig = Rig(); defer { rig.wipe() }
        rig.driver.open()
        rig.driver.paneSelected(.privacy)
        rig.driver.open()
        #expect(rig.presenter.windows.count == 1)
        #expect(rig.presenter.log.last(where: { $0.hasPrefix("select:") }) == "select:privacy")

        rig.driver.paneSelected(.about)
        rig.driver.paneSelected(.storage)
        rig.driver.open()
        #expect(rig.presenter.log.last(where: { $0.hasPrefix("select:") }) == "select:storage", "the latest choice wins")
    }

    // OC-8025 (relaunch). A new launch opens on the stored pane.
    @Test("OC-8025: a relaunch opens on the pane last used")
    func relaunchOpensOnLastPane() {
        let rig = Rig(); defer { rig.wipe() }
        rig.driver.open()
        rig.driver.paneSelected(.triggers)

        let (driver, presenter) = rig.relaunched()
        driver.open()
        #expect(presenter.log == ["make", "select:triggers", "front"])
    }

    // The window selects its first tab while it is built; that must not replace the stored pane before it is read.
    @Test("OC-8025: a selection the window reports while it is built does not lose the stored pane")
    func initialSelectionDoesNotClobber() {
        let rig = Rig(); defer { rig.wipe() }
        rig.driver.open()
        rig.driver.paneSelected(.shortcuts)

        let (driver, presenter) = rig.relaunched()
        presenter.selectionReportedWhileBuilding = .general
        driver.open()
        #expect(presenter.log.last(where: { $0.hasPrefix("select:") }) == "select:shortcuts")
    }

    // Worf (mutation survivor): the callback handed to the window is the one that stores the pane. A click on a toolbar
    // button reaches only that callback, so a no-op there left every other test green.
    @Test("OC-8025: a pane picked through the window's callback is stored and reopened on, by a fresh launch")
    func windowCallbackStoresPane() {
        let rig = Rig(); defer { rig.wipe() }
        rig.driver.open()
        rig.presenter.didSelect?(.storage)

        let (driver, presenter) = rig.relaunched()
        driver.open()
        #expect(presenter.log == ["make", "select:storage", "front"])
        #expect(SettingsPane.lastOpened(in: Rig.launch(rig.suite)) == .storage)
    }

    // Closing with ⌘W or Escape only hides the window (it is not released), so the driver has no "closed" state: a
    // reopen after close is the same call and reuses the window (`singleWindowRefocused`).
    @Test("OC-8024: with no presenter set, open builds nothing and a selection is still remembered")
    func noPresenter() {
        withTestDefaults("frd008.window.none") { suite in
            let driver = SettingsWindowDriver(settings: Rig.launch(suite))
            driver.open()
            driver.paneSelected(.about)
            #expect(SettingsPane.lastOpened(in: Rig.launch(suite)) == .about)
        }
    }

    // FR-008-17 (VoiceOver, package side). The toolbar button and icon are read as the pane's title.
    @Test("AC-008-03: every pane button has a distinct, non-empty label and an icon")
    func paneLabelsAreSpoken() {
        let items = SettingsWindowDriver.items
        #expect(items.count == SettingsPane.allCases.count)
        #expect(items.allSatisfy { !$0.label.trimmingCharacters(in: .whitespaces).isEmpty && !$0.symbolName.isEmpty })
        #expect(Set(items.map(\.label)).count == items.count, "two panes must not read the same")
        #expect(items.map(\.label) == SettingsPane.allCases.map { FlotsamStrings.text(forKey: "ui.settings.pane\($0.rawValue.capitalized)") ?? "?" })
    }
}

// MARK: - Static scan of the pane views (Tab, Space and VoiceOver, source side)

/// One SwiftUI control in a pane source: its kind, the text that labels it, and what follows it (modifiers).
private struct ScannedControl {
    let kind: String
    let file: String
    let label: String
    let after: String
}

/// Finds `Toggle`, `Picker`, `Button`, `Link`, `TextField`, `Stepper`, `Slider` and reads each one's label: the `label:`
/// closure when there is one, else the first trailing closure (Toggle, Button), else the arguments (string-title form).
private func scanControls(in code: String, file: String) -> [ScannedControl] {
    let chars = Array(code)
    let regex = try! NSRegularExpression(pattern: #"\b(Toggle|Picker|Button|Link|TextField|Stepper|Slider)(\(| \{)"#) // test-only fixed pattern
    func balanced(from open: Int, _ openChar: Character, _ closeChar: Character) -> Int? {
        var depth = 0
        var i = open
        while i < chars.count {
            if chars[i] == openChar { depth += 1 } else if chars[i] == closeChar { depth -= 1; if depth == 0 { return i } }
            i += 1
        }
        return nil
    }
    func skipSpace(_ i: Int) -> Int {
        var i = i
        while i < chars.count, chars[i].isWhitespace { i += 1 }
        return i
    }
    var found: [ScannedControl] = []
    for match in regex.matches(in: code, range: NSRange(code.startIndex..., in: code)) {
        let kind = (code as NSString).substring(with: match.range(at: 1))
        let start = match.range.location
        var pos = start + match.range.length - 1  // at "(" or "{"
        var args = ""
        if chars[pos] == "(" {
            guard let close = balanced(from: pos, "(", ")") else { continue }
            args = String(chars[(pos + 1)..<close])
            pos = close + 1
        }
        var blocks: [(isLabel: Bool, text: String)] = []
        while true {
            var next = skipSpace(pos)
            var isLabel = false
            if next + 6 <= chars.count, String(chars[next..<(next + 6)]) == "label:" {
                next = skipSpace(next + 6)
                isLabel = true
            }
            guard next < chars.count, chars[next] == "{", let close = balanced(from: next, "{", "}") else { break }
            blocks.append((isLabel, String(chars[(next + 1)..<close])))
            pos = close + 1
        }
        // A first argument that is not a `name:` parameter is the title (`Button(SettingsString.x.text) { act }`), and then
        // the trailing closure is the action, not the label.
        let titleInArgs = !args.isEmpty && args.range(of: #"^\s*\w+:"#, options: .regularExpression) == nil
        let label = blocks.first(where: \.isLabel)?.text ?? (titleInArgs ? args : (blocks.first?.text ?? args))
        let after = String(chars[min(pos, chars.count)..<min(pos + 300, chars.count)])
        found.append(ScannedControl(kind: kind, file: file, label: label, after: after))
    }
    return found
}

/// The two ways a control reaches the catalogue (FR-000-05): a `Text(.key)` / `Text(verbatim:)` of a catalogue-derived
/// string, or a `SettingsString` title. A bare string literal title is not a catalogue key.
private func labelProblem(_ control: ScannedControl) -> String? {
    let label = control.label
    // `Text("Shelf")` and `Text(verbatim: "Shelf")` are literals too: they compile, and VoiceOver reads them, but they
    // are not the catalogue's text (FR-000-05).
    if label.range(of: #"\b(Text|Label)\((verbatim:\s*)?""#, options: .regularExpression) != nil {
        return "\(control.kind) in \(control.file) labels itself with a literal string"
    }
    let usesText = label.contains("Text(") || label.contains("SettingsString.") || label.contains("Label(")
    if label.trimmingCharacters(in: .whitespaces).hasPrefix("\"") { return "\(control.kind) in \(control.file) has a literal title" }
    if usesText { return nil }
    // An icon-only control is spoken only through an explicit accessibility label.
    if label.contains("Image("), control.after.contains(".accessibilityLabel(") { return nil }
    return label.contains("Image(")
        ? "icon-only \(control.kind) in \(control.file) has no accessibilityLabel"
        : "\(control.kind) in \(control.file) has no text label"
}

@Suite("FRD-008 AC-008-03: every pane control is labelled (source scan)") struct Frd008SettingsControlLabelTests {
    private func paneSources() throws -> [(path: String, code: String)] {
        let root = try frd008SourceRoot()
        let directory = "App/Flotsam/Settings"
        let names = try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent(directory).path)
        return try names.filter { $0.hasSuffix(".swift") }.sorted().map { (directory + "/" + $0, try frd008Code(directory + "/" + $0)) }
    }

    // Standard SwiftUI Toggle, Picker and Button are in the Tab order and answer Space; the live check is TASK-518.
    // What this pins is that none is built without a catalogue label, and an icon-only one carries an explicit label.
    @Test("OC-8024: every Settings control has a catalogue text label; icon-only ones have an accessibility label")
    func everyControlLabelled() throws {
        var controls: [ScannedControl] = []
        for source in try paneSources() { controls += scanControls(in: source.code, file: source.path) }
        // 37 at TASK-086 (25 Button, 6 Toggle, 6 Picker). Raise it when a pane gains a control; a lower number would let
        // the scan quietly stop seeing a dozen of them.
        #expect(controls.count >= 37, "the scan must see the panes' controls (saw \(controls.count))")
        #expect(controls.filter { $0.kind == "Button" }.count >= 25)
        #expect(controls.filter { $0.kind == "Toggle" }.count >= 6)
        #expect(controls.filter { $0.kind == "Picker" }.count >= 6)
        #expect(Set(controls.map(\.kind)).isSuperset(of: ["Toggle", "Picker", "Button"]))
        #expect(controls.compactMap(labelProblem).isEmpty, "\(controls.compactMap(labelProblem))")
    }

    // Worf: the scan only knows the control kinds in its pattern. A kind it does not know, or a tap gesture standing in
    // for a button (not in the Tab order, no Space), would pass unseen, so the Settings sources may not use them.
    @Test("OC-8024: Settings views use no control kind the label scan cannot see, and no tap gesture or focus opt-out")
    func noUnscannedControlKinds() throws {
        let banned = ["SecureField", "Menu(", "Menu {", "DatePicker", "ColorPicker", "TextEditor", "DisclosureGroup", "onTapGesture",
                      "onLongPressGesture", ".focusable(false)", "allowsHitTesting(false)", "NSSlider", "NSButton", "NSTextField"]
        var hits: [String] = []
        for source in try paneSources() { for word in banned where source.code.contains(word) { hits.append("\(word) in \(source.path)") } }
        #expect(hits.isEmpty, "\(hits): teach scanControls this kind, or keep it out of Settings")
    }

    // The scan above must be able to fail: the same checks on synthetic sources.
    @Test("OC-8024: the label scan flags a literal title, a missing label and an unlabelled icon button")
    func scanSeesViolations() {
        func problems(_ code: String) -> [String] { scanControls(in: code, file: "x.swift").compactMap(labelProblem) }
        #expect(problems(#"Toggle("Shelf", isOn: $on)"#).count == 1)
        #expect(problems("Button { go() } label: { Image(systemName: \"plus\") }").count == 1)
        #expect(problems("Button { go() } label: { Image(systemName: \"plus\") }\n.accessibilityLabel(addLabel)").isEmpty)
        #expect(problems("Toggle(isOn: $on) { Text(.shelf) }").isEmpty)
        #expect(problems("Picker(selection: $p) { Text(.a) } label: { Text(.shelfPlacement) }").isEmpty)
        #expect(problems(#"Button(SettingsString.cancel.text, role: .cancel) {}"#).isEmpty)
        #expect(problems(#"Toggle(isOn: $on) { Text("Shelf") }"#).count == 1, "a literal Text is not a catalogue label")
        #expect(problems(#"Toggle(isOn: $on) { Text(verbatim: "Shelf") }"#).count == 1)
        #expect(problems(#"Toggle(isOn: $on) { Text(verbatim: SettingsString.shelf.text) }"#).isEmpty)
    }

    // The toolbar buttons are labelled from the driver's items, not from a second copy of the titles.
    @Test("OC-8024: the toolbar tabs take their label and icon description from the driver's items; openSettings is one call")
    func glueUsesDriver() throws {
        let code = try frd008Code("App/Flotsam/Settings/SettingsWindowController.swift")
        #expect(code.contains("tab.label = item.label"))
        #expect(code.contains("accessibilityDescription: item.label"))
        #expect(code.contains("func openSettings() { driver.open() }"))
        #expect(!code.contains("SettingsPane.allCases"), "pane order has one home, the driver")
    }

    // Worf (mutation survivors): the window itself is built in the App target, which no unit test compiles. These are
    // the choices that were in the controller before TASK-086 and that nothing else would notice losing.
    @Test("OC-8024: the glue keeps the window's title, toolbar style, close behaviour and the forwards to the driver")
    func glueKeepsWindowShape() throws {
        let code = try frd008Code("App/Flotsam/Settings/SettingsWindowController.swift")
        let required = [
            "tabStyle = .toolbar",
            "tabs.title = SettingsString.window.text",
            "window.title = SettingsString.window.text",
            "window.styleMask = [.titled, .closable, .miniaturizable]",
            "window.isReleasedWhenClosed = false",  // a closed window is reopened, never rebuilt
            "window.setFrameAutosaveName(\"\")",
            "window.center()",
            "func select(_ pane: SettingsPane) { tabs.select(pane) }",
            "front = WindowFrontAdapter(window: window)",  // activation and ordering front: WindowFrontAdapter (TASK-521)
            "func bringToFront() { front.bringToFront() }",
            "didSelect(items[index].pane)",
            "driver = SettingsWindowDriver(settings: env.settings)",
            "driver.presenter = self",
            "for item in items { addTabViewItem(tabItem(for: item)) }",
            "tab.identifier = item.pane.rawValue",
        ]
        #expect(required.filter { !code.contains($0) } == [], "removed from the Settings window glue")
    }
}
