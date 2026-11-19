import Foundation
import Testing
import FlotsamBase
@testable import FlotsamPaste

/// AC-001-26, "no trigger variable can take its value": the only variable that reads content from outside Flotsam is
/// `{clipboard}` (FR-005-17). A secure item can reach the pasteboard only as a re-copy, which carries ConcealedType, and
/// `{clipboard}` reads a concealed pasteboard as empty (FR-005-16). So the revealed password cannot be pasted into a
/// trigger's expansion by way of `{clipboard}`.
@MainActor
@Suite struct SecureTriggerVariableTests {
    private static let secret = "swordfish-7731"

    private func clipboardValue(after recopy: [PasteboardRepresentation]) -> (text: String, disposition: HeldClipboard.Disposition, bytesRead: Int) {
        let board = ScriptedPasteboard([])
        _ = OwnWriteLedger().write(recopy, to: board)
        let held = ClipboardPreserver(pasteboard: board, ownWrites: OwnWriteLedger(), clock: RecordingClock()).capture()
        let context = TemplateContext(
            now: Date(timeIntervalSince1970: 0), calendar: Calendar(identifier: .gregorian),
            locale: Locale(identifier: "en_US"), clipboardText: held.plainText)
        return (TemplateVariables.expand("[{clipboard}]", context: context), held.disposition, board.readTypes.count)
    }

    @Test func aSecureRecopyExpandsClipboardAsEmpty() {
        let result = clipboardValue(after: SecureClip.pasteboardRepresentations(revealing: Self.secret))
        #expect(result.disposition == .concealed)
        #expect(result.text == "[]")
        #expect(!result.text.contains(Self.secret))
        #expect(result.bytesRead == 0, "a concealed pasteboard is recognised from its type list, before any bytes are read")
    }

    /// The control: the same text without ConcealedType is readable, so the test above fails for the right reason.
    @Test func theSameTextWithoutTheConcealedMarkerIsReadable() {
        let plain = [PasteboardRepresentation(uti: PasteboardUTI.plainText, data: Data(Self.secret.utf8))]
        let result = clipboardValue(after: plain)
        #expect(result.disposition == .held)
        #expect(result.text == "[\(Self.secret)]")
    }
}
