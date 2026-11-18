import FlotsamBase
import FlotsamStorage
import Foundation
import Testing
@testable import FlotsamPaste

// FRD-005 8T contract tests, slice S8 (template variables: FR-005-16, FR-005-17, AC-005-16, AC-005-17, BR-4, BR-5;
// OC-5109, 5110, 5111, 5112, 5113, 5114, 5115, 5116, 5118, 5119, 5141, 5142), written from the blind oracle contract
// (.claude/oracle/frd-005-contract.json). Expected values are literals.
//
// Seams. Variables are expanded by `PasteExpansion.stage`, the one home a typed trigger and an item hotkey both call
// (FR-005-14), so each "user types ';x' Space" is observed as the plain text `stage` writes to the pasteboard, which is
// what the next step pastes. The pasteboard is `ScriptedPasteboard` (it also supplies the clipboard text the variable
// reads), the clock is fixed at 2026-11-16 14:05 UTC, calendar Gregorian UTC, locale en_US. The keystroke half of
// typing a trigger is the matcher's and engine's (FRD005ContractTestsMatcher / Engine); `Space` removing the trigger
// text is not re-tested here. OC-5141 and OC-5142 drive the real `PasteService`.
//
// Companion files for the halves that live in other modules:
//  - OC-5113 and OC-5114 "TRG-VAL-005 at save, the item still saves": FlotsamAppModelTests/FRD005ContractTestsVariablesSave
//    (the editor model lives there). Here: `validate` and the literal expansion.
//  - OC-5107 and OC-5117 Library Return / Copy / preview: FlotsamLibraryTests/FRD005ContractTestsVariablesLibrary.
//  - OC-5117 Shelf drag: FlotsamShelfTests/FRD005ContractTestsVariablesShelf.
// UNTESTABLE-AT-PACKAGE: "the text lands in TextEdit" (5141, 5117 drag, 5119, 5142 paste with ⌘V): the observable here is
// the pasteboard the ⌘V pastes and the ⌘V posted to the target; the document is the target app's. Missing seam: a
// UI-automation harness over TextEdit (App/OS half).

private let en = Locale(identifier: "en_US")

private func utcCalendar() -> Calendar {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "UTC") ?? .gmt
    return calendar
}

/// 2026-11-16 14:05:00 UTC, as a literal epoch.
private let fixedNow = Date(timeIntervalSince1970: 1_794_837_900)

/// A clock stuck at `fixedNow` that records what was slept.
private final class FixedClock: WallClock, @unchecked Sendable {
    private let lock = NSLock()
    private var _slept: [Duration] = []
    var slept: [Duration] { lock.withLock { _slept } }
    func now() -> Date { fixedNow }
    func sleep(for duration: Duration) async {
        lock.withLock { _slept.append(duration) }
    }
}

private func rep(_ uti: String, _ text: String) -> PasteboardRepresentation {
    PasteboardRepresentation(uti: uti, data: Data(text.utf8))
}

private func plain(_ text: String) -> PasteboardRepresentation { rep(PasteboardUTI.plainText, text) }

@MainActor
private struct Rig {
    let board: ScriptedPasteboard
    let ledger = OwnWriteLedger()
    let clock = FixedClock()
    let codec = FakeRichTextCodec()
    let expansion: PasteExpansion
    let itemId = UUID()

    init(clipboard: [PasteboardRepresentation]) {
        board = ScriptedPasteboard(clipboard)
        expansion = PasteExpansion(
            pasteboard: board, files: FakeFiles(existing: []), codec: codec,
            preserver: ClipboardPreserver(pasteboard: board, ownWrites: ledger, clock: clock),
            ownWrites: ledger, clock: clock, calendar: utcCalendar(), locale: en)
    }

    /// The plain text `stage` wrote for a plain-text item, or nil when stage failed or wrote none.
    func expanded(_ text: String) -> String? {
        let content = ItemContent(kind: .text, plainText: text, representations: [], members: [])
        guard case .success = expansion.stage(content: content, itemId: itemId) else { return nil }
        return board.writes.last?.first { $0.uti == PasteboardUTI.plainText }.map { String(decoding: $0.data, as: UTF8.self) }
    }
}

@MainActor
@Suite struct FRD005ContractTestsVariables {
    // MARK: Date and time

    // Red if `{date:fmt}` ignores its format, or reads another day than the clock's.
    @Test("OC-5109 ';d' on '{date:yyyy-MM-dd}' inserts today's date as 2026-11-16")
    func oc5109_dateWithFormat() {
        // given: the clock at 2026-11-16 14:05 UTC and an item '{date:yyyy-MM-dd}'
        let rig = Rig(clipboard: [plain("anything")])
        // when: the trigger expands
        let text = rig.expanded("{date:yyyy-MM-dd}")
        // then: exactly the date, no variable text left, one write
        #expect(text == "2026-11-16")
        #expect(rig.board.writes.count == 1)
    }

    // Red if `{date}` or `{time}` stops using the medium / short style, or swaps them.
    @Test("OC-5110 'D={date} T={time}' in en_US inserts 'D=Nov 16, 2026 T=2:05 PM'")
    func oc5110_defaultStyles() throws {
        // given: locale en_US, the clock at 14:05 UTC
        let rig = Rig(clipboard: [plain("anything")])
        // when: the item expands
        let text = try #require(rig.expanded("D={date} T={time}"))
        // then: medium date, short time (ICU may put U+202F before PM; both spellings are the short style)
        #expect(text == "D=Nov 16, 2026 T=2:05 PM" || text == "D=Nov 16, 2026 T=2:05\u{202F}PM")
        // boundary: an item with neither variable is not touched
        #expect(rig.expanded("no variables") == "no variables")
    }

    // Red if `{time:fmt}` formats in 12-hour time or another zone.
    @Test("OC-5111 ';t' on '{time:HH:mm}' inserts the 24-hour time 14:05")
    func oc5111_timeWithFormat() {
        // given: the clock at 14:05 UTC
        let rig = Rig(clipboard: [plain("anything")])
        // when / then
        #expect(rig.expanded("{time:HH:mm}") == "14:05")
    }

    // MARK: Clipboard

    // Red if `{clipboard}` reads anything but the snapshot's plain text, or an image-only clipboard leaves the token.
    @Test("OC-5112 'C={clipboard}' inserts 'C=clip-abc', then 'C=' once only an image is copied")
    func oc5112_clipboardThenImageOnly() {
        // given: 'clip-abc' copied
        let first = Rig(clipboard: [plain("clip-abc")])
        // when / then: the first expansion carries it
        #expect(first.expanded("C={clipboard}") == "C=clip-abc")
        // given: only an image on the clipboard
        let second = Rig(clipboard: [rep("public.png", "img-bytes")])
        // when / then: the variable is replaced by nothing, not left as '{clipboard}'
        #expect(second.expanded("C={clipboard}") == "C=")
        // negative: an empty clipboard behaves the same
        #expect(Rig(clipboard: []).expanded("C={clipboard}") == "C=")
    }

    // Red if an inserted clipboard value is scanned again (the `{clipboard}` replacement re-expanded).
    @Test("OC-5116 'X={clipboard}' with clipboard '{date}' inserts 'X={date}', not the date")
    func oc5116_noReExpansion() {
        // given: the clipboard text is itself a variable
        let rig = Rig(clipboard: [plain("{date}")])
        // when / then: the value goes in as it is
        #expect(rig.expanded("X={clipboard}") == "X={date}")
        // a fresh clipboard each time (stage overwrites it): two occurrences are each the value, neither re-expanded
        #expect(Rig(clipboard: [plain("{date}")]).expanded("{clipboard}{clipboard}") == "{date}{date}")
    }

    // MARK: Unknown, bad and escaped

    // Red if an unknown name or a bad format is substituted, dropped or errors the expansion.
    @Test("OC-5113 'A {foo} B {date:@@}' fails validate with TRG-VAL-005 and expands literally")
    func oc5113_unknownIsLiteral() {
        // given: an item with an unknown name and a bad format
        let rig = Rig(clipboard: [plain("clip")])
        let text = "A {foo} B {date:@@}"
        // when: validated (the save-time check) and expanded
        // then: TRG-VAL-005 with the catalogue sentence, and the text goes in unchanged
        guard case .failure(let error) = TemplateVariables.validate(text) else {
            Issue.record("expected TRG-VAL-005")
            return
        }
        #expect(error.code == .trgVal005)
        #expect(FlotsamStrings.message(for: error) == "An unknown variable was left as plain text.")
        #expect(rig.expanded(text) == "A {foo} B {date:@@}")
        // negative: text with only known variables passes validate
        if case .failure = TemplateVariables.validate("A {date} B {clipboard}") { Issue.record("known variables must validate") }
    }

    // Red if the 32-character limit moves, or an over-long format is applied.
    @Test("OC-5114 a 33-character date format and '{clipboard:x}' fail validate and stay literal; 32 characters is a variable")
    func oc5114_formatCeiling() throws {
        let rig = Rig(clipboard: [plain("clip")])
        let thirtyThree = String(repeating: "y", count: 33)
        let thirtyTwo = String(repeating: "y", count: 32)
        // given: the contract's text
        let text = "{clipboard:x} {date:\(thirtyThree)}"
        // when / then: TRG-VAL-005, both inserted literally
        guard case .failure(let error) = TemplateVariables.validate(text) else {
            Issue.record("expected TRG-VAL-005")
            return
        }
        #expect(error.code == .trgVal005)
        #expect(rig.expanded(text) == "{clipboard:x} {date:yyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyy}")
        // boundary: 32 characters is a valid format, so it validates and is substituted
        if case .failure = TemplateVariables.validate("{date:\(thirtyTwo)}") { Issue.record("32 characters must validate") }
        let substituted = try #require(Rig(clipboard: []).expanded("{date:\(thirtyTwo)}"))
        #expect(substituted.hasSuffix("2026"))
        #expect(!substituted.contains("{"))
    }

    // Red if `{{known}}` is substituted, or foreign `{{ ... }}` syntax is altered.
    @Test("OC-5115 '{{date}} {{ .Name }}' inserts '{date} {{ .Name }}'")
    func oc5115_escapesAndForeignBraces() {
        let rig = Rig(clipboard: [plain("clip")])
        // given / when / then
        #expect(rig.expanded("{{date}} {{ .Name }}") == "{date} {{ .Name }}")
        // and it is not a warning: neither part is an unknown variable
        if case .failure = TemplateVariables.validate("{{date}} {{ .Name }}") { Issue.record("must not warn") }
    }

    // MARK: Ceiling

    // Red if the ceiling is not applied after substitution, or applied at another size (10 MiB = 10485760 bytes).
    @Test("OC-5118 text just under the ceiling with '{clipboard}' and a long clipboard expands to exactly 10485760 bytes")
    func oc5118_ceiling() throws {
        // given: an item of exactly 10485760 bytes ending in '{clipboard}' and a 100-character clipboard
        let ceiling = 10_485_760
        let item = String(repeating: "A", count: ceiling - 11) + "{clipboard}"
        #expect(item.utf8.count == ceiling)
        let rig = Rig(clipboard: [plain(String(repeating: "B", count: 100))])
        // when: it expands
        let text = try #require(rig.expanded(item))
        // then: cut at the limit: 10485749 A and 11 B
        #expect(text.utf8.count == 10_485_760)
        #expect(text.hasSuffix("AB" + String(repeating: "B", count: 10)))
        #expect(text.filter { $0 == "B" }.count == 11)
        // boundary: an expansion that stays under the ceiling is not cut
        let small = try #require(Rig(clipboard: [plain("BB")]).expanded(String(repeating: "A", count: ceiling - 11) + "{clipboard}"))
        #expect(small.utf8.count == ceiling - 11 + 2)
    }

    // MARK: Rich text

    // Red if the link or the bold run is dropped, or the variable inside the link is substituted outside it.
    @Test("OC-5119 a rich item 'Report {date}' linked to https://e.com keeps the link, reads 'Report Nov 16, 2026', keeps bold")
    func oc5119_richText() throws {
        // given: stored rich text with a link whose text holds {date}, and a bold run
        var attributed = AttributedString("Note: ")
        var link = AttributedString("Report {date}")
        link.link = URL(string: "https://e.com")
        attributed.append(link)
        var bold = AttributedString(" bold")
        bold.inlinePresentationIntent = .stronglyEmphasized
        attributed.append(bold)
        let rig = Rig(clipboard: [plain("clip")])
        rig.codec.decoded = attributed
        let stored = [rep("public.rtf", "stored-rtf")]
        let content = ItemContent(kind: .richText, plainText: "Note: Report {date} bold", representations: stored, members: [])
        // when: the item expands
        guard case .success = rig.expansion.stage(content: content, itemId: rig.itemId) else {
            Issue.record("stage failed")
            return
        }
        // then: the re-encoded string has one link, to https://e.com, reading 'Report Nov 16, 2026', and the bold run
        let result = try #require(rig.codec.encoded.first)
        let linked = result.runs.filter { $0.link != nil }
        #expect(linked.count == 1)
        #expect(linked.first?.link == URL(string: "https://e.com"))
        #expect(linked.first.map { String(result[$0.range].characters) } == "Report Nov 16, 2026")
        #expect(String(result.characters) == "Note: Report Nov 16, 2026 bold")
        let boldRuns = result.runs.filter { $0.inlinePresentationIntent == .stronglyEmphasized }
        #expect(boldRuns.map { String(result[$0.range].characters) } == [" bold"])
        // and the plain text written alongside is the expanded text
        let written = try #require(rig.board.writes.last)
        #expect(written.first { $0.uti == PasteboardUTI.plainText }.map { String(decoding: $0.data, as: UTF8.self) }
            == "Note: Report Nov 16, 2026 bold")
    }

    // MARK: Library paste never expands (BR-4)

    @MainActor private struct PasteRig {
        let service: PasteService
        let board = FakePasteboard()
        let keys = FakeKeys()
        let host = FakeHost()
        let store: FakeStore
        static let target = FrontmostApp(bundleId: "com.apple.TextEdit", processId: 77)

        init(_ content: ItemContent) {
            store = FakeStore(.success(content))
            service = PasteService(
                store: store, pasteboard: board, files: FakeFiles(existing: []),
                frontmost: FakeFrontmost(target: Self.target, pollsUntilTarget: 0),
                accessibility: FakePermission(isAccessibilityTrusted: true), keys: keys, clock: FixedClock(),
                ownWrites: OwnWriteLedger())
        }

        var lastText: String? {
            board.written.last?.first { $0.uti == PasteboardUTI.plainText }.map { String(decoding: $0.data, as: UTF8.self) }
        }
    }

    // Red if the Library paste path expands variables (calls TemplateVariables / PasteExpansion).
    @Test("OC-5141 ⌥Return plain paste then Copy of '{time}' put the literal '{time}' on the clipboard and paste it")
    func oc5141_plainPasteAndCopyAreLiteral() async throws {
        // given: an item '{time}' (it has a trigger ';t'; triggers do not change what Library paste gives)
        let content = ItemContent(kind: .text, plainText: "{time}", representations: [], members: [])
        let rig = PasteRig(content)
        let id = UUID()
        // when: plain paste into TextEdit
        let pasted = try await rig.service.paste(itemId: id, mode: .plainText, target: PasteRig.target, host: rig.host).get()
        // then: the ⌘V goes to TextEdit and what it pastes is the literal
        #expect(pasted == .pasted)
        #expect(rig.keys.targets == [PasteRig.target])
        #expect(rig.lastText == "{time}")
        // when: the Copy action
        let copied = try await rig.service.paste(itemId: id, mode: .copyOnly, target: PasteRig.target, host: rig.host).get()
        // then: copied, nothing more posted, the clipboard holds the literal; two writes in all
        #expect(copied == .copied)
        #expect(rig.keys.posts == 1)
        #expect(rig.lastText == "{time}")
        #expect(rig.board.written.count == 2)
        // the same item through the expansion path is NOT literal (control: the variable is live there)
        let board = ScriptedPasteboard([plain("prev")])
        let ledger = OwnWriteLedger()
        let clock = FixedClock()
        let expansion = PasteExpansion(
            pasteboard: board, files: FakeFiles(existing: []), codec: FakeRichTextCodec(),
            preserver: ClipboardPreserver(pasteboard: board, ownWrites: ledger, clock: clock), ownWrites: ledger,
            clock: clock, calendar: utcCalendar(), locale: en)
        guard case .success = expansion.stage(content: content, itemId: id) else { Issue.record("stage failed"); return }
        #expect(board.writes.last?.first { $0.uti == PasteboardUTI.plainText }.map { String(decoding: $0.data, as: UTF8.self) }
            != "{time}")
    }

    // MARK: Clipboard restore (BR-5)

    // Red if the item-hotkey paste does not put the user's rich clipboard back after ⌘V.
    @Test("OC-5142 after an item hotkey paste and the 300 ms restore, the clipboard is the original rich text again")
    func oc5142_richClipboardRestored() async throws {
        // given: rich text with bold and a link on the clipboard, and a hotkey item 'hk-text'
        let originalRTF = rep("public.rtf", "{\\rtf1 \\b bold\\b0  and a link}")
        let originalHTML = rep("public.html", "<b>bold</b> <a href=\"https://e.com\">link</a>")
        let originalText = plain("bold and a link")
        let board = ScriptedPasteboard([originalRTF, originalHTML, originalText])
        let ledger = OwnWriteLedger()
        let clock = FixedClock()
        let keys = FakeKeys()
        let content = ItemContent(kind: .text, plainText: "hk-text", representations: [], members: [])
        let service = PasteService(
            store: FakeStore(.success(content)), pasteboard: board, files: FakeFiles(existing: []),
            frontmost: FakeFrontmost(target: FrontmostApp(bundleId: "com.apple.Notes", processId: 5), pollsUntilTarget: 0),
            accessibility: FakePermission(isAccessibilityTrusted: true), keys: keys, clock: clock, ownWrites: ledger)
        let expansion = PasteExpansion(
            pasteboard: board, files: FakeFiles(existing: []), codec: FakeRichTextCodec(),
            preserver: ClipboardPreserver(pasteboard: board, ownWrites: ledger, clock: clock), ownWrites: ledger,
            clock: clock, calendar: utcCalendar(), locale: en)
        // when: the hotkey pastes into Notes
        let outcome = try await service.pasteExpanded(
            itemId: UUID(), target: FrontmostApp(bundleId: "com.apple.Notes", processId: 5), expansion: expansion).get()
        // then: it pasted once, waited the 300 ms restore window, and the clipboard holds the original three types
        #expect(outcome == .pasted)
        #expect(keys.posts == 1)
        #expect(clock.slept.contains(.milliseconds(300)))
        #expect(board.writes.count == 2)
        #expect(board.writes[0].first { $0.uti == PasteboardUTI.plainText }.map { String(decoding: $0.data, as: UTF8.self) } == "hk-text")
        #expect(board.representations.first { $0.uti == "public.rtf" } == originalRTF)
        #expect(board.representations.first { $0.uti == "public.html" } == originalHTML)
        #expect(board.representations.first { $0.uti == PasteboardUTI.plainText } == originalText)
    }
}
