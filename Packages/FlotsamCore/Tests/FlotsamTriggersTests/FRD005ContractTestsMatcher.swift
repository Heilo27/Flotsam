import FlotsamBase
import FlotsamPaste
import FlotsamStorage
import Foundation
import Testing
@testable import FlotsamTriggers

// FRD-005 8T contract tests, slice S7 (trigger matcher and policy: FR-005-11, FR-005-12, FR-005-13, FR-005-15(c);
// OC-5070, 5071, 5072, 5073, 5074, 5075, 5080, 5084, 5088, 5089, 5090, 5091, 5092, 5093, 5095, 5096, 5097, 5099,
// 5139, 5140), written from the blind oracle contract (.claude/oracle/frd-005-contract.json). Expected values are
// literals.
//
// Seams, all test doubles on production ports. `FakeKeyEventSource` is the event tap: every key goes through the real
// `TriggerEngine` and `TriggerMatcher`, and its decision (`.pass` reaches the application, `.consume` does not) is the
// only thing the test knows about a key. `Typist` below is the application's text field: it applies a key to its text
// when the tap passed it, and applies what Flotsam posted (`RecordingKeys.actions`: backspaces, boundary re-post,
// paste of the pasteboard as it was at the moment of the post) afterwards. "The document reads exactly ..." is that
// text. `ExpansionStore.recorded` is the paste count, `ExpansionPasteboard.writes` the clipboard writes,
// `RecordingPresenter.huds` the HUD, and `RecordingSink.records` the log.
//
// Not observable at package level: OC-5093 names four Flotsam fields (Library search, note popover, item editor,
// Settings excluded-apps field). The tap sees only the frontmost application, so the four are one case here (Flotsam's
// own bundle id in front); which field has focus is not an input of the matcher. OC-5095 names Safari, Xcode and VS
// Code by bundle id; the matcher cannot tell their text areas from any other. OC-5084 expects each trigger to insert
// its own item's text; `ExpansionStore` serves one content for every id, so the item is identified by the id the paste
// was recorded for and the backspace count, not by the inserted text.
//
// Analogues that stay as they are: TriggerMatcherTests, TriggerEngineTests, TriggerExpanderTests,
// TriggerExpanderAdversarialTests, Worf432bTriggerTests, TriggerPrivacyTests.

private let trigger = ";sig"
private let expansion = "Best, R"
private let hudTRGOS002 = "Couldn't expand that trigger. Your typed text was left as it was."

// Key codes as written in the contract's world (Carbon kVK_*), literals on purpose.
private let kSpace: UInt16 = 49
private let kTab: UInt16 = 48
private let kReturn: UInt16 = 36
private let kBackspace: UInt16 = 51

/// The ten default-excluded apps other than Terminal (OC-5089), by bundle identifier.
private let otherDefaultExcludedApps = [
    "com.googlecode.iterm2", "net.kovidgoyal.kitty", "com.mitchellh.ghostty", "io.alacritty",
    "dev.warp.Warp-Stable", "co.zeit.hyper", "com.microsoft.rdc.macos", "com.apple.ScreenSharing",
    "com.parallels.desktop.console", "com.vmware.fusion",
]

private let textEdit = FrontmostApp(bundleId: "com.apple.TextEdit", processId: 400)

/// An application's text field. A key the tap passed is typed into it; what Flotsam posted is applied on `applyPosted`.
@MainActor
private final class Typist {
    let h: EngineHarness
    private(set) var text = ""
    private var applied = 0
    /// The pasteboard's plain text at the moment of each post, by the index the posted action will have.
    private var pasteboardAtPost: [Int: String] = [:]

    init(_ h: EngineHarness) {
        self.h = h
        h.base.keys.beforePost = { [h, weak self] in
            self?.pasteboardAtPost[h.base.keys.actions.count] = h.base.pasteboard.plainText ?? ""
        }
    }

    private func typed(forBoundary code: UInt16) -> String {
        switch code {
        case 48: "\t"
        case 36, 76: "\n"
        default: " "
        }
    }

    /// Every character as a key press; a space is the Space key. Returns the decision for each key down.
    @discardableResult
    func type(_ string: String, flags: KeyEventFlags = []) -> [KeyDecision] {
        string.map { ch in
            if ch == " " { return press(kSpace, " ", flags: flags) }
            let down = h.source.send(KeyEvent(kind: .keyDown, keyCode: 0, flags: flags, characters: String(ch)))
            h.source.send(KeyEvent(kind: .keyUp, keyCode: 0, flags: flags, characters: String(ch)))
            if down == .pass { text.append(ch) }
            return down
        }
    }

    /// One key down and its key up. Returns the decision for the key down; the key up is stored in `lastKeyUp`.
    @discardableResult
    func press(_ code: UInt16, _ characters: String = "", flags: KeyEventFlags = []) -> KeyDecision {
        let down = h.source.send(KeyEvent(kind: .keyDown, keyCode: code, flags: flags, characters: characters))
        lastKeyUp = h.source.send(KeyEvent(kind: .keyUp, keyCode: code, flags: flags))
        if down == .pass {
            if code == kBackspace {
                if !text.isEmpty { text.removeLast() }
            } else if [kSpace, kTab, kReturn, 76].contains(code) {
                text += typed(forBoundary: code)
            } else {
                text += characters
            }
        }
        return down
    }

    private(set) var lastKeyUp: KeyDecision = .pass

    /// Applies what Flotsam posted since the last call.
    func applyPosted() {
        let actions = h.base.keys.actions
        for index in applied..<actions.count {
            switch actions[index] {
            case .key(let code, let count):
                if code == kBackspace {
                    text.removeLast(min(count, text.count))
                } else {
                    text += String(repeating: typed(forBoundary: code), count: count)
                }
            case .text(let string):
                text += string
            case .paste:
                text += pasteboardAtPost[index] ?? ""
            }
        }
        applied = actions.count
    }
}

@MainActor
private func expanderBase(_ plainText: String = expansion) -> ExpanderHarness {
    ExpanderHarness(content: .success(ItemContent(kind: .text, plainText: plainText, representations: [], members: [])))
}

/// Waits until `count` pastes were recorded, then applies what Flotsam posted to the text.
@MainActor
private func awaitExpansions(_ count: Int, _ h: EngineHarness, _ doc: Typist) async -> Bool {
    let reached = await eventually { h.base.store.recorded.count == count }
    doc.applyPosted()
    return reached
}

@MainActor
private func polRecords(_ h: EngineHarness, _ code: String) -> [LogRecord] {
    h.base.sink.records.filter { $0.headline.hasPrefix(code) }
}

/// Nothing happened to the user's world: no paste, no clipboard write, no HUD, nothing posted.
@MainActor
private func expectNoExpansion(_ h: EngineHarness, sourceLocation: SourceLocation = #_sourceLocation) {
    #expect(h.base.store.recorded.isEmpty, sourceLocation: sourceLocation)
    #expect(h.base.pasteboard.writes.isEmpty, sourceLocation: sourceLocation)
    #expect(h.base.pasteboard.plainText == "previous clipboard", sourceLocation: sourceLocation)
    #expect(h.base.presenter.huds.isEmpty, sourceLocation: sourceLocation)
    #expect(h.base.keys.actions.isEmpty, sourceLocation: sourceLocation)
}

@MainActor
@Suite("FRD-005 contract: trigger matcher and policy (S7)", .serialized, .timeLimit(.minutes(2)))
struct FRD005ContractTestsMatcher {
    private let itemId = ExpanderHarness.itemId

    private func harness(triggers: [UUID: String]? = nil, base: ExpanderHarness = expanderBase()) -> EngineHarness {
        EngineHarness(triggers: triggers ?? [itemId: trigger], triggersEnabled: true, base: base)
    }

    // MARK: Boundary and word rules (FR-005-11, FR-005-12)

    @Test("OC-5070 ';sig' + Space replaces the trigger with 'Best, R' and leaves no trailing space")
    func oc5070ExpandsWithoutTrailingSpace() async {
        // given an item with trigger ';sig' and text 'Best, R', and an empty document
        let h = harness()
        await h.engine.start()
        defer { h.engine.stop() }
        let doc = Typist(h)
        // when the user types ';sig' Space
        let keysBeforeSpace = doc.type(trigger)
        // then nothing changed in the document before Space
        #expect(keysBeforeSpace == [.pass, .pass, .pass, .pass])
        #expect(doc.text == ";sig")
        // and Space is swallowed, with its key-up
        #expect(doc.press(kSpace, " ") == .consume)
        #expect(doc.lastKeyUp == .consume)
        #expect(await awaitExpansions(1, h, doc))
        // and the document reads exactly the item text: four backspaces, one paste, no boundary key re-posted
        #expect(doc.text == "Best, R")
        #expect(h.base.keys.actions == [.key(51, count: 4), .paste])
        #expect(h.base.store.recorded == [itemId])
    }

    @Test("OC-5071 'x;sig' + Space: a trigger inside a longer word does not expand")
    func oc5071TriggerInsideWordDoesNotExpand() async {
        // given trigger ';sig'
        let h = harness()
        await h.engine.start()
        defer { h.engine.stop() }
        let doc = Typist(h)
        // when the user types 'x;sig' Space
        doc.type("x;sig")
        #expect(doc.press(kSpace, " ") == .pass)
        // then the document holds the typed text, and no clipboard write, HUD, post or paste count change happened
        #expect(doc.text == "x;sig ")
        expectNoExpansion(h)

        // control: the same engine expands a real ';sig' right after, so the silence above was the matcher's decision
        doc.type(trigger)
        #expect(doc.press(kSpace, " ") == .consume)
        #expect(await awaitExpansions(1, h, doc))
        #expect(doc.text == "x;sig Best, R")
        #expect(h.base.store.recorded == [itemId])
    }

    @Test("OC-5072 ';si' + Space: a prefix of a trigger does not expand")
    func oc5072PrefixDoesNotExpand() async {
        // given trigger ';sig'
        let h = harness()
        await h.engine.start()
        defer { h.engine.stop() }
        let doc = Typist(h)
        // when the user types ';si' Space
        doc.type(";si")
        #expect(doc.press(kSpace, " ") == .pass)
        // then the document reads ';si ' and nothing was expanded
        #expect(doc.text == ";si ")
        expectNoExpansion(h)
    }

    @Test("OC-5073 ';sig', Backspace, 'g', Space expands: Backspace edits the word")
    func oc5073BackspaceEditsTheWord() async {
        // given trigger ';sig'
        let h = harness()
        await h.engine.start()
        defer { h.engine.stop() }
        let doc = Typist(h)
        // when the user types ';sig', Backspace, 'g', Space
        doc.type(trigger)
        #expect(doc.press(kBackspace) == .pass)
        #expect(doc.text == ";si")
        doc.type("g")
        #expect(doc.press(kSpace, " ") == .consume)
        // then it expands
        #expect(await awaitExpansions(1, h, doc))
        #expect(doc.text == "Best, R")
        #expect(h.base.store.recorded == [itemId])

        // control: the same keys without the retyped 'g' leave ';si ' and expand nothing
        let control = harness()
        await control.engine.start()
        defer { control.engine.stop() }
        let controlDoc = Typist(control)
        controlDoc.type(trigger)
        controlDoc.press(kBackspace)
        #expect(controlDoc.press(kSpace, " ") == .pass)
        #expect(controlDoc.text == ";si ")
        expectNoExpansion(control)
    }

    @Test("OC-5074 a mouse click between ';sig' and Space clears the word: no expansion")
    func oc5074MouseClickClearsTheWord() async {
        // given trigger ';sig'
        let h = harness()
        await h.engine.start()
        defer { h.engine.stop() }
        let doc = Typist(h)
        // when the user types ';sig', clicks in the document, then presses Space
        doc.type(trigger)
        #expect(h.source.send(KeyEvent(kind: .mouseDown)) == .pass)
        #expect(doc.press(kSpace, " ") == .pass)
        // then nothing expanded and the document reads ';sig '
        #expect(doc.text == ";sig ")
        expectNoExpansion(h)

        // control: without the click the same keys expand
        doc.type(trigger)
        #expect(doc.press(kSpace, " ") == .consume)
        #expect(await awaitExpansions(1, h, doc))
        #expect(doc.text == ";sig Best, R")
    }

    @Test("OC-5075 Tab and Return are boundary keys: each expands and no tab or line break is inserted")
    func oc5075TabAndReturnAreBoundaries() async {
        for (code, name) in [(kTab, "Tab"), (kReturn, "Return")] {
            // given trigger ';sig'
            let h = harness()
            await h.engine.start()
            defer { h.engine.stop() }
            let doc = Typist(h)
            // when the user types ';sig' and the boundary key
            doc.type(trigger)
            #expect(doc.press(code, code == kTab ? "\t" : "\r") == .consume, "\(name) decision")
            #expect(doc.lastKeyUp == .consume, "\(name) key-up")
            // then it expands, and the document holds only the item text
            #expect(await awaitExpansions(1, h, doc), "\(name) expansion")
            #expect(doc.text == "Best, R", "\(name) document")
            #expect(h.base.keys.actions == [.key(51, count: 4), .paste], "\(name) posts")
            #expect(h.base.store.recorded == [itemId], "\(name) paste count")
        }
    }

    @Test("OC-5080 ';SIG' with Shift held and with Caps Lock on both expand; Shift on Space does not")
    func oc5080CaseInsensitive() async {
        // given trigger ';sig'
        for (name, flags) in [("Shift", KeyEventFlags.shift), ("Caps Lock", KeyEventFlags.capsLock)] {
            let h = harness()
            await h.engine.start()
            defer { h.engine.stop() }
            let doc = Typist(h)
            // when the user types ';SIG' with the modifier held, then Space
            doc.type(";")
            doc.type("SIG", flags: flags)
            #expect(doc.text == ";SIG", "\(name) typed text")
            #expect(doc.press(kSpace, " ") == .consume, "\(name) decision")
            // then it expands
            #expect(await awaitExpansions(1, h, doc), "\(name) expansion")
            #expect(doc.text == "Best, R", "\(name) document")
            #expect(h.base.store.recorded == [itemId], "\(name) paste count")
        }

        // negative: Shift on the Space key is not a boundary, so the word ends without a match
        let negative = harness()
        await negative.engine.start()
        defer { negative.engine.stop() }
        let doc = Typist(negative)
        doc.type(trigger)
        #expect(doc.press(kSpace, " ", flags: .shift) == .pass)
        #expect(doc.text == ";sig ")
        expectNoExpansion(negative)
    }

    @Test("OC-5084 triggers ';s' and ';sig': each expands its own item, and nothing changes before Space")
    func oc5084ShorterAndLongerTriggers() async {
        // given item S with ';s' and item G with ';sig'
        let sId = UUID()
        let gId = UUID()
        let h = harness(triggers: [sId: ";s", gId: ";sig"])
        await h.engine.start()
        defer { h.engine.stop() }
        let doc = Typist(h)
        // when the user types ';s' Space
        doc.type(";s")
        #expect(doc.press(kSpace, " ") == .consume)
        // then S was pasted, over two backspaces
        #expect(await awaitExpansions(1, h, doc))
        #expect(h.base.store.recorded == [sId])
        #expect(h.base.keys.actions == [.key(51, count: 2), .paste])
        #expect(doc.text == "Best, R")

        // when on a new line the user types ';sig'
        #expect(doc.press(kReturn, "\r") == .pass)
        #expect(doc.type(trigger) == [.pass, .pass, .pass, .pass])
        // then nothing changes in the document before Space, and the pastes so far are still only S's
        #expect(doc.text == "Best, R\n;sig")
        #expect(h.base.store.recorded == [sId])
        // and Space expands G, over four backspaces
        #expect(doc.press(kSpace, " ") == .consume)
        #expect(await awaitExpansions(2, h, doc))
        #expect(h.base.store.recorded == [sId, gId])
        #expect(h.base.keys.actions == [.key(51, count: 2), .paste, .key(51, count: 4), .paste])
        #expect(doc.text == "Best, R\nBest, R")
    }

    // MARK: Policy (FR-005-13)

    @Test("OC-5088 Terminal frontmost: ';sig' + Return passes through, TRG-POL-002 is logged at Info, no HUD")
    func oc5088TerminalIsExcluded() async {
        // given trigger ';sig' and Terminal frontmost, with the default excluded-apps list
        let h = harness()
        h.base.environment.frontmost = FrontmostApp(bundleId: "com.apple.Terminal", processId: 300)
        await h.engine.start()
        defer { h.engine.stop() }
        let doc = Typist(h)
        // when the user types ';sig' Return
        doc.type(trigger)
        #expect(doc.press(kReturn, "\r") == .pass)
        // then the line break reached the app and nothing was expanded
        #expect(doc.text == ";sig\n")
        // and TRG-POL-002 is logged once, at Info
        #expect(await eventually { polRecords(h, "TRG-POL-002").count == 1 })
        #expect(polRecords(h, "TRG-POL-002").map(\.headline) == ["TRG-POL-002 info"])
        #expect(polRecords(h, "TRG-POL-002").map(\.level) == [.info])
        #expect(polRecords(h, "TRG-POL-001").isEmpty)
        expectNoExpansion(h)
    }

    @Test("OC-5089 the other ten default-excluded apps pass ';sig' + Space through")
    func oc5089OtherDefaultExcludedApps() async {
        // given trigger ';sig' and the default excluded-apps list
        #expect(otherDefaultExcludedApps.count == 10)
        let h = harness()
        await h.engine.start()
        defer { h.engine.stop() }
        let doc = Typist(h)
        // when the user types ';sig' Space in each of the ten apps in turn
        for (index, bundleId) in otherDefaultExcludedApps.enumerated() {
            h.base.environment.frontmost = FrontmostApp(bundleId: bundleId, processId: Int32(600 + index))
            doc.type(trigger)
            #expect(doc.press(kSpace, " ") == .pass, "\(bundleId)")
        }
        // then none expanded: ten suppressions, no paste, no HUD
        #expect(await eventually { polRecords(h, "TRG-POL-002").count == 10 })
        #expect(doc.text == String(repeating: ";sig ", count: 10))
        expectNoExpansion(h)

        // control: an app that is not on the list expands on the same engine
        h.base.environment.frontmost = textEdit
        doc.type(trigger)
        #expect(doc.press(kSpace, " ") == .consume)
        #expect(await awaitExpansions(1, h, doc))
        #expect(h.base.store.recorded == [itemId])
    }

    @Test("OC-5090 adding TextEdit to the excluded list stops expansion there; removing it restores it")
    func oc5090UserEditsTheExcludedList() async {
        // given trigger ';sig', TextEdit frontmost, and the default excluded-apps list
        let h = harness()
        h.base.environment.frontmost = textEdit
        await h.engine.start()
        defer { h.engine.stop() }
        let doc = Typist(h)
        let original = h.settings.value(SettingKeys.triggersExcludedApps)
        // when the user adds TextEdit and types ';sig' Space
        h.settings.set(BundleIdentifierList(original.identifiers + ["com.apple.TextEdit"]), for: SettingKeys.triggersExcludedApps)
        #expect(await eventually { h.base.snapshot.policy.excludes(bundleId: "com.apple.TextEdit", ownBundleId: "com.example.flotsam") })
        doc.type(trigger)
        #expect(doc.press(kSpace, " ") == .pass)
        // then nothing expanded and TRG-POL-002 was logged once
        #expect(doc.text == ";sig ")
        #expect(await eventually { polRecords(h, "TRG-POL-002").count == 1 })
        expectNoExpansion(h)

        // when the user removes TextEdit again and types ';sig' Space
        h.settings.set(original, for: SettingKeys.triggersExcludedApps)
        #expect(await eventually { !h.base.snapshot.policy.excludes(bundleId: "com.apple.TextEdit", ownBundleId: "com.example.flotsam") })
        doc.type(trigger)
        #expect(doc.press(kSpace, " ") == .consume)
        // then it expands
        #expect(await awaitExpansions(1, h, doc))
        #expect(doc.text == ";sig Best, R")
        #expect(h.base.store.recorded == [itemId])
        #expect(polRecords(h, "TRG-POL-002").count == 1)
    }

    @Test("OC-5091 secure input on: ';sig' + Space passes through, no HUD, clipboard unchanged, TRG-POL-001 at Info")
    func oc5091SecureInputSuppresses() async {
        // given trigger ';sig', a password field focused (secure event input on), clipboard 'previous clipboard'
        let h = harness()
        h.base.environment.secureInput = true
        await h.engine.start()
        defer { h.engine.stop() }
        let doc = Typist(h)
        // when the user types ';sig' Space
        doc.type(trigger)
        #expect(doc.press(kSpace, " ") == .pass)
        // then the document reads ';sig ' and nothing was expanded, written, shown or counted
        #expect(doc.text == ";sig ")
        expectNoExpansion(h)
        // and TRG-POL-001 is logged once, at Info
        #expect(await eventually { polRecords(h, "TRG-POL-001").count == 1 })
        #expect(polRecords(h, "TRG-POL-001").map(\.headline) == ["TRG-POL-001 info"])
        #expect(polRecords(h, "TRG-POL-001").map(\.level) == [.info])

        // control: with secure input off the same engine expands
        h.base.environment.secureInput = false
        doc.type(trigger)
        #expect(doc.press(kSpace, " ") == .consume)
        #expect(await awaitExpansions(1, h, doc))
        #expect(doc.text == ";sig Best, R")
    }

    @Test("OC-5092 an input method composing: ';sig' + Space does not expand and nothing is reported")
    func oc5092InputMethodSuppresses() async {
        // given trigger ';sig' and an input method active
        let h = harness()
        h.base.environment.inputMethodActive = true
        await h.engine.start()
        defer { h.engine.stop() }
        let doc = Typist(h)
        // when the user types ';sig' Space
        doc.type(trigger)
        #expect(doc.press(kSpace, " ") == .pass)
        // then the document reads ';sig ' and nothing was expanded
        #expect(doc.text == ";sig ")
        expectNoExpansion(h)

        // control: with the input method off the engine expands; the engine handles events in order, so by then the
        // earlier suppression has been reported, and an input method reports neither TRG-POL code
        h.base.environment.inputMethodActive = false
        doc.type(trigger)
        #expect(doc.press(kSpace, " ") == .consume)
        #expect(await awaitExpansions(1, h, doc))
        #expect(doc.text == ";sig Best, R")
        #expect(polRecords(h, "TRG-POL").isEmpty)
        #expect(h.base.presenter.huds.isEmpty)
    }

    @Test("OC-5093 Flotsam's own window frontmost: ';sig' + Space is not expanded and the field keeps ';sig '")
    func oc5093OwnWindowsAreExcluded() async {
        // given trigger ';sig' and a Flotsam field focused (the frontmost app is Flotsam's own bundle id)
        let h = harness()
        h.base.environment.frontmost = FrontmostApp(bundleId: "com.example.flotsam", processId: 1)
        await h.engine.start()
        defer { h.engine.stop() }
        let doc = Typist(h)
        // when the user types ';sig' Space
        doc.type(trigger)
        #expect(doc.press(kSpace, " ") == .pass)
        // then the field contains ';sig ' and nothing was expanded
        #expect(doc.text == ";sig ")
        expectNoExpansion(h)

        // control: another app on the same engine expands, and the exclusion list holds no entry for Flotsam
        #expect(!h.settings.value(SettingKeys.triggersExcludedApps).identifiers.contains("com.example.flotsam"))
        h.base.environment.frontmost = textEdit
        doc.type(trigger)
        #expect(doc.press(kSpace, " ") == .consume)
        #expect(await awaitExpansions(1, h, doc))
        #expect(h.base.store.recorded == [itemId])
    }

    // MARK: Trigger characters inside other text (FR-005-11, FR-005-12)

    @Test("OC-5095 ';sig' inside code and URLs never expands: the typed text is exactly what the document holds")
    func oc5095TriggerInsideCodeAndURLs() async {
        let typedText = "for(i=0;sig<n;i++) a;sig b https://e.com/x;sig end"
        // given trigger ';sig' and Safari, Xcode and VS Code in turn
        for bundleId in ["com.apple.Safari", "com.apple.dt.Xcode", "com.microsoft.VSCode"] {
            let h = harness()
            h.base.environment.frontmost = FrontmostApp(bundleId: bundleId, processId: 700)
            await h.engine.start()
            defer { h.engine.stop() }
            let doc = Typist(h)
            // when the user types the text
            let decisions = doc.type(typedText)
            // then every key passed, nothing expanded, and the document holds exactly the typed text
            #expect(decisions.allSatisfy { $0 == .pass }, "\(bundleId) decisions")
            #expect(decisions.count == 50, "\(bundleId) key count")
            #expect(doc.text == "for(i=0;sig<n;i++) a;sig b https://e.com/x;sig end", "\(bundleId)")
            expectNoExpansion(h)
        }

        // control: the same trigger as a standalone word expands
        let control = harness()
        await control.engine.start()
        defer { control.engine.stop() }
        let doc = Typist(control)
        doc.type("a " + trigger)
        #expect(doc.press(kSpace, " ") == .consume)
        #expect(await awaitExpansions(1, control, doc))
        #expect(doc.text == "a Best, R")
    }

    @Test("OC-5096 an item whose text is ';sig2 and more' expands once and ';sig2' does not fire on its own")
    func oc5096ExpandedTextDoesNotRetrigger() async {
        // given ';sig' whose text is ';sig2 and more', and another item with trigger ';sig2'
        let first = UUID()
        let second = UUID()
        let h = harness(triggers: [first: ";sig", second: ";sig2"], base: expanderBase(";sig2 and more"))
        await h.engine.start()
        defer { h.engine.stop() }
        let doc = Typist(h)
        // when the user types ';sig' Space
        doc.type(trigger)
        #expect(doc.press(kSpace, " ") == .consume)
        // then the document reads exactly ';sig2 and more'
        #expect(await awaitExpansions(1, h, doc))
        #expect(doc.text == ";sig2 and more")
        // and only ';sig' was pasted: ';sig2' did not expand, then or later
        #expect(h.base.store.recorded == [first])
        #expect(h.base.keys.actions == [.key(51, count: 4), .paste])

        // control: typing ';sig2' + Space does expand the second item
        doc.type(";sig2")
        #expect(doc.press(kSpace, " ") == .consume)
        #expect(await awaitExpansions(2, h, doc))
        #expect(h.base.store.recorded == [first, second])
    }

    @Test("OC-5097 right after an expansion ';s' + Space expands: Flotsam's own backspaces and Command-V are not typed words")
    func oc5097OwnEventsDoNotEnterTheBuffer() async {
        // given ';sig' just expanded in the document, and another trigger ';s'
        let sig = UUID()
        let short = UUID()
        let h = harness(triggers: [sig: ";sig", short: ";s"])
        await h.engine.start()
        defer { h.engine.stop() }
        let doc = Typist(h)
        doc.type(trigger)
        #expect(doc.press(kSpace, " ") == .consume)
        #expect(await awaitExpansions(1, h, doc))
        #expect(doc.text == "Best, R")
        // and the tap sees Flotsam's own four backspaces and Command-V come back (they carry the event marker)
        for _ in 0..<4 {
            #expect(h.source.send(KeyEvent(kind: .keyDown, keyCode: 51, isFlotsamEvent: true)) == .pass)
            #expect(h.source.send(KeyEvent(kind: .keyUp, keyCode: 51, isFlotsamEvent: true)) == .pass)
        }
        #expect(h.source.send(KeyEvent(kind: .keyDown, keyCode: 9, flags: .command, characters: "v", isFlotsamEvent: true)) == .pass)
        #expect(h.source.send(KeyEvent(kind: .keyUp, keyCode: 9, flags: .command, isFlotsamEvent: true)) == .pass)
        // when the user immediately types ';s' Space
        doc.type(";s")
        #expect(doc.press(kSpace, " ") == .consume)
        // then ';s' expands normally: item `short`, over two backspaces
        #expect(await awaitExpansions(2, h, doc))
        #expect(h.base.store.recorded == [sig, short])
        #expect(h.base.keys.actions == [.key(51, count: 4), .paste, .key(51, count: 2), .paste])
        #expect(doc.text == "Best, RBest, R")
    }

    @Test("OC-5139 'abc' Space 'def' Space ';sig' Space reads 'abc def Best, R': only the completing Space is consumed")
    func oc5139OnlyTheCompletingSpaceIsConsumed() async {
        // given trigger ';sig' with text 'Best, R' and an empty document
        let h = harness()
        await h.engine.start()
        defer { h.engine.stop() }
        let doc = Typist(h)
        // when the user types 'abc' Space 'def' Space ';sig' Space
        #expect(doc.type("abc def ") == [.pass, .pass, .pass, .pass, .pass, .pass, .pass, .pass])
        #expect(doc.text == "abc def ")
        doc.type(trigger)
        #expect(doc.press(kSpace, " ") == .consume)
        // then the document reads exactly 'abc def Best, R'
        #expect(await awaitExpansions(1, h, doc))
        #expect(doc.text == "abc def Best, R")
        #expect(h.base.keys.actions == [.key(51, count: 4), .paste])
        #expect(h.base.store.recorded == [itemId])
    }

    @Test("OC-5140 secure input on system-wide while TextEdit is frontmost: no expansion, TRG-POL-001 logged")
    func oc5140SecureKeyboardEntryElsewhere() async {
        // given another app (Terminal) has Secure Keyboard Entry on, which makes secure input system-wide, TextEdit is
        // frontmost (not excluded), trigger ';sig', clipboard 'previous clipboard'
        let h = harness()
        h.base.environment.frontmost = textEdit
        h.base.environment.secureInput = true
        await h.engine.start()
        defer { h.engine.stop() }
        let doc = Typist(h)
        // when the user types ';sig' Space in TextEdit
        doc.type(trigger)
        #expect(doc.press(kSpace, " ") == .pass)
        // then the document contains exactly ';sig ' including the boundary key
        #expect(doc.text == ";sig ")
        // and the clipboard, HUD and paste count are unchanged
        expectNoExpansion(h)
        // and TRG-POL-001 is logged, not TRG-POL-002
        #expect(await eventually { polRecords(h, "TRG-POL-001").count == 1 })
        #expect(polRecords(h, "TRG-POL-001").map(\.headline) == ["TRG-POL-001 info"])
        #expect(polRecords(h, "TRG-POL-002").isEmpty)

        // control: once Terminal leaves Secure Keyboard Entry the same typing expands
        h.base.environment.secureInput = false
        doc.type(trigger)
        #expect(doc.press(kSpace, " ") == .consume)
        #expect(await awaitExpansions(1, h, doc))
        #expect(doc.text == ";sig Best, R")
    }

    // MARK: Switching apps during expansion (FR-005-15(c)), D3

    @Test("OC-5099 (contract drift; asserts FR-005-15(c) per S1 ruling)")
    func oc5099SwitchingAppDuringTheDelay() async {
        // given trigger ';sig', and a delay before the re-check during which the user switches to Notes
        let h = harness()
        let environment = h.base.environment
        h.base.store.beforeLoad = { environment.frontmost = FrontmostApp(bundleId: "com.apple.Notes", processId: 500) }
        h.base.environment.frontmost = textEdit
        await h.engine.start()
        defer { h.engine.stop() }
        let doc = Typist(h)
        // when the user types ';sig' Space in TextEdit
        doc.type(trigger)
        #expect(doc.press(kSpace, " ") == .consume)
        // then the failure HUD appears once
        #expect(await eventually { h.base.presenter.huds.count == 1 })
        doc.applyPosted()
        #expect(h.base.presenter.huds == [hudTRGOS002])
        #expect(await h.base.reportedCodes() == [.trgOs002])
        // and the item text was inserted neither into Notes nor into TextEdit: nothing was posted to any app, no
        // clipboard write, no paste counted
        #expect(h.base.keys.actions.isEmpty)
        #expect(h.base.keys.targets.isEmpty)
        #expect(h.base.pasteboard.writes.isEmpty)
        #expect(h.base.store.recorded.isEmpty)
        // and, per FRD-005 FR-005-15(c) (S1 ruling: the FRD wins, the contract line "TextEdit keeps ';sig '" is drift), the
        // swallowed boundary key is NOT re-posted once the user has left the app: no key event reached any app, and the
        // text stays exactly as the user left it, ';sig' with no trailing space
        #expect(h.base.keys.actions.isEmpty)
        #expect(h.base.keys.targets.isEmpty)
        #expect(doc.text == ";sig")
        #expect(doc.text != ";sig ")
    }
}
