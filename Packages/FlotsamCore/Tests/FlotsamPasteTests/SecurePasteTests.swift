import Foundation
import Testing
import FlotsamBase
import FlotsamStorage
@testable import FlotsamPaste

/// A vault that opens one known ciphertext and counts how often it is asked.
private final class SecureTestVault: SecureClipVaulting, @unchecked Sendable {
    static let ciphertext = Data([0xC1, 0xF0, 0x0D])
    static let plaintext = "correct-horse-battery-staple"

    private let lock = NSLock()
    private var _opens = 0
    let isKeyAvailable: Bool

    init(keyAvailable: Bool = true) { isKeyAvailable = keyAvailable }

    var opens: Int { lock.withLock { _opens } }
    func seal(_ text: String) -> FlotsamResult<SealedSecret> {
        .failure(FlotsamError(.sysInt001, "seal is not used by paste"))
    }
    func open(_ ciphertext: Data) -> FlotsamResult<String> {
        lock.withLock { _opens += 1 }
        return ciphertext == Self.ciphertext ? .success(Self.plaintext) : .failure(FlotsamError(.libDat002, "bad bytes"))
    }
}

/// An owner check that answers as scripted and counts the prompts shown.
private final class SecureTestAuthenticator: UserAuthenticator, @unchecked Sendable {
    private let lock = NSLock()
    private var _prompts = 0
    private let answer: FlotsamResult<Void>

    init(_ answer: FlotsamResult<Void>) { self.answer = answer }

    var prompts: Int { lock.withLock { _prompts } }
    func authenticate(reason: String) async -> FlotsamResult<Void> {
        lock.withLock { _prompts += 1 }
        return answer
    }
}

/// FR-003-23, FR-005-23: a secure item is decrypted only behind the owner check, is re-copied as Concealed, and is never
/// a trigger or hotkey payload.
@MainActor
@Suite struct SecurePasteTests {
    static let target = FrontmostApp(bundleId: "com.apple.Notes", processId: 42)
    private let itemId = UUID()

    private var secureContent: ItemContent {
        ItemContent(
            kind: .text, plainText: nil, representations: [], members: [], secureCiphertext: SecureTestVault.ciphertext)
    }

    private struct Rig {
        let service: PasteService
        let store: FakeStore
        let pasteboard: FakePasteboard
        let ledger: OwnWriteLedger
        let keys: FakeKeys
        let host: FakeHost
        let vault: SecureTestVault
        let authenticator: SecureTestAuthenticator
        let clock: RecordingClock
    }

    private func rig(
        keyAvailable: Bool = true, auth: FlotsamResult<Void> = .success(()), wired: Bool = true
    ) -> Rig {
        let store = FakeStore(.success(secureContent))
        let pasteboard = FakePasteboard()
        let ledger = OwnWriteLedger()
        let keys = FakeKeys()
        let host = FakeHost()
        let clock = RecordingClock()
        let vault = SecureTestVault(keyAvailable: keyAvailable)
        let authenticator = SecureTestAuthenticator(auth)
        let service = PasteService(
            store: store, pasteboard: pasteboard, files: FakeFiles(existing: []),
            frontmost: FakeFrontmost(target: Self.target), accessibility: FakePermission(isAccessibilityTrusted: true),
            keys: keys, clock: clock, ownWrites: ledger,
            secureAccess: wired ? SecureClipAccess(vault: vault, authenticator: authenticator) : nil)
        return Rig(
            service: service, store: store, pasteboard: pasteboard, ledger: ledger, keys: keys, host: host, vault: vault,
            authenticator: authenticator, clock: clock)
    }

    private func code(_ result: FlotsamResult<PasteOutcome>) -> ErrorCode? {
        if case .failure(let error) = result { return error.code }
        return nil
    }

    // MARK: FR-003-23 the gate

    @Test(arguments: [PasteMode.paste, .plainText, .copyOnly])
    func cancelledCheckIsNotAuthorisedAndNothingIsCopied(mode: PasteMode) async {
        let r = rig(auth: .failure(FlotsamError(.libOs002, "cancelled")))
        let result = await r.service.paste(itemId: itemId, mode: mode, target: Self.target, host: r.host)
        #expect(code(result) == .libOs002)
        #expect(r.authenticator.prompts == 1)
        #expect(r.vault.opens == 0)
        #expect(r.pasteboard.written.isEmpty)
        #expect(r.keys.posts == 0)
        #expect(r.store.recorded.isEmpty)
    }

    @Test func missingKeyIsUnavailableAndTheOwnerIsNeverPrompted() async {
        let r = rig(keyAvailable: false)
        let result = await r.service.paste(itemId: itemId, mode: .paste, target: Self.target, host: r.host)
        #expect(code(result) == .libDat002)
        #expect(r.authenticator.prompts == 0)
        #expect(r.pasteboard.written.isEmpty)
        #expect(r.keys.posts == 0)
    }

    @Test func noSecureStorageWiredIsUnavailableNeverAPlaintextFallback() async {
        let r = rig(wired: false)
        let result = await r.service.paste(itemId: itemId, mode: .paste, target: Self.target, host: r.host)
        #expect(code(result) == .libDat002)
        #expect(r.pasteboard.written.isEmpty)
    }

    @Test func authorisedPasteWritesThePlaintextConcealedAndOwnWriteMarked() async throws {
        let r = rig()
        let outcome = try await r.service.paste(itemId: itemId, mode: .paste, target: Self.target, host: r.host).get()
        #expect(outcome == .pasted)
        #expect(r.authenticator.prompts == 1)
        #expect(r.pasteboard.written.count == 1)
        let written = r.pasteboard.written[0]
        #expect(written.first { $0.uti == PasteboardUTI.plainText }?.data == Data(SecureTestVault.plaintext.utf8))
        let utis = written.map(\.uti)
        #expect(utis.contains(PasteboardMarkers.concealed))
        #expect(utis.contains(PasteboardMarkers.ownWrite))
        #expect(utis.contains(PasteboardMarkers.autoGenerated))
        #expect(r.ledger.contains(changeCount: r.pasteboard.changeCount))
        #expect(r.keys.posts == 1)
        #expect(r.store.recorded == [itemId])
    }

    @Test func copyOnlyAlsoAuthenticatesAndWritesConcealed() async throws {
        let r = rig()
        let outcome = try await r.service.paste(itemId: itemId, mode: .copyOnly, target: Self.target, host: r.host).get()
        #expect(outcome == .copied)
        #expect(r.authenticator.prompts == 1)
        #expect(r.pasteboard.written[0].map(\.uti).contains(PasteboardMarkers.concealed))
        #expect(r.keys.posts == 0)
    }

    @Test func everyPasteAsksAgain() async throws {
        let r = rig()
        _ = try await r.service.paste(itemId: itemId, mode: .paste, target: Self.target, host: r.host).get()
        _ = try await r.service.paste(itemId: itemId, mode: .paste, target: Self.target, host: r.host).get()
        #expect(r.authenticator.prompts == 2)
    }

    /// `{clipboard}` (FR-005-17) is the held clipboard's plain text; a Concealed pasteboard is read as empty, so the
    /// password Flotsam re-copied can never become a variable value.
    @Test func afterTheReCopyTheClipboardVariableReadsEmpty() async throws {
        let r = rig()
        _ = try await r.service.paste(itemId: itemId, mode: .copyOnly, target: Self.target, host: r.host).get()
        let held = ClipboardPreserver(pasteboard: r.pasteboard, ownWrites: r.ledger, clock: r.clock).capture()
        #expect(held.disposition == .concealed)
        #expect(held.plainText.isEmpty)
    }

    /// The payload builder is the last line: handed a secure item with no revealed text it fails closed rather than
    /// writing an empty string or anything stored.
    @Test func thePayloadBuilderRefusesASecureItemWithoutRevealedText() {
        let result = PastePayload.representations(
            for: secureContent, mode: .paste, itemId: itemId, files: FakeFiles(existing: []))
        guard case .failure(let error) = result else {
            Issue.record("a secure item produced a payload without authentication")
            return
        }
        #expect(error.code == .libOs002)
    }

    // MARK: FR-005-23 never a trigger or hotkey payload

    @Test func theItemHotkeyPathRefusesASecureItemWithoutPromptOrWrite() async {
        let r = rig()
        let expansion = PasteExpansion(
            pasteboard: r.pasteboard, files: FakeFiles(existing: []), codec: FakeRichTextCodec(),
            preserver: ClipboardPreserver(pasteboard: r.pasteboard, ownWrites: r.ledger, clock: r.clock),
            ownWrites: r.ledger, clock: r.clock)
        let result = await r.service.pasteExpanded(itemId: itemId, target: Self.target, expansion: expansion)
        #expect(code(result) == .trgVal006)
        #expect(r.authenticator.prompts == 0)
        #expect(r.vault.opens == 0)
        #expect(r.pasteboard.written.isEmpty)
        #expect(r.keys.posts == 0)
    }

    @Test func templatedPayloadRefusesASecureItem() {
        let result = TemplatedPayload.representations(
            for: secureContent, itemId: itemId,
            context: TemplateContext(now: .now, calendar: .current, locale: .current, clipboardText: ""),
            codec: FakeRichTextCodec(), files: FakeFiles(existing: []))
        guard case .failure(let error) = result else {
            Issue.record("a secure item produced a trigger payload")
            return
        }
        #expect(error.code == .trgVal006)
    }
}
