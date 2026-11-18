import Foundation
import Testing
import FlotsamBase
import FlotsamStorage
@testable import FlotsamPaste

// TASK-435, FRD-008 FR-008-13 (OC-8110): PasteService requests Accessibility once per session, when a paste-back
// finds it untrusted. Observed at the layer the OS sees: the count of request(.accessibility) calls on the probe.

/// A probe whose trust can change mid-session and which records every permission request.
final class Worf435Probe: PermissionProbe, @unchecked Sendable {
    private let lock = NSLock()
    private var trusted: Bool
    private var _requests: [PermissionKind] = []
    init(trusted: Bool) { self.trusted = trusted }
    var requests: [PermissionKind] { lock.withLock { _requests } }
    func setTrusted(_ value: Bool) { lock.withLock { trusted = value } }
    func isGranted(_ kind: PermissionKind) -> Bool { lock.withLock { kind == .accessibility ? trusted : false } }
    func request(_ kind: PermissionKind) { lock.withLock { _requests.append(kind) } }
    func openSystemSettings(_ kind: PermissionKind) {}
}

@MainActor
@Suite("TASK-435: Accessibility prompt at first paste (OC-8110)")
struct Worf435AccessibilityPromptTests {
    static let target = FrontmostApp(bundleId: "com.apple.Notes", processId: 42)
    let itemId = UUID()

    struct Rig {
        let service: PasteService
        let probe: Worf435Probe
        let keys: FakeKeys
        let board: FakePasteboard
        let host: FakeHost
        let store: FakeStore
    }

    private var content: ItemContent {
        ItemContent(kind: .text, plainText: "hello",
                    representations: [PasteboardRepresentation(uti: "public.utf8-plain-text", data: Data("hello".utf8))], members: [])
    }

    private func rig(trusted: Bool, probe shared: Worf435Probe? = nil) -> Rig {
        let probe = shared ?? Worf435Probe(trusted: trusted)
        let board = FakePasteboard()
        let keys = FakeKeys()
        let store = FakeStore(.success(content))
        let service = PasteService(
            store: store, pasteboard: board, files: FakeFiles(existing: []),
            frontmost: FakeFrontmost(target: Self.target), accessibility: probe, keys: keys,
            clock: RecordingClock(), ownWrites: OwnWriteLedger())
        return Rig(service: service, probe: probe, keys: keys, board: board, host: FakeHost(), store: store)
    }

    private func choose(_ r: Rig, mode: PasteMode = .paste) async -> PasteOutcome? {
        try? await r.service.paste(itemId: itemId, mode: mode, target: Self.target, host: r.host).get()
    }

    // OC-8110. Red if the paste path stops requesting (count 0) or requests on every attempt (count 3).
    @Test("OC-8110: untrusted, three paste attempts -> exactly one Accessibility request, every item still copied")
    func promptsOnFirstAttemptOnly() async {
        let r = rig(trusted: false)
        // given Accessibility untrusted and no paste attempted yet
        #expect(r.probe.requests.isEmpty)
        // when the user chooses an item three times
        var outcomes: [PasteOutcome?] = []
        outcomes.append(await choose(r))
        let afterFirst = r.probe.requests
        outcomes.append(await choose(r))
        outcomes.append(await choose(r))
        // then the prompt came on the first attempt and never again; each choice copied but did not paste
        #expect(afterFirst == [.accessibility])
        #expect(r.probe.requests == [.accessibility])
        #expect(outcomes == [.copiedAccessibilityDenied, .copiedAccessibilityDenied, .copiedAccessibilityDenied])
        #expect(r.board.written.count == 3)
        #expect(r.keys.posts == 0)
        #expect(r.store.recorded == [itemId, itemId, itemId])
    }

    // OC-8110 negative. Red if a trusted paste ever asks for permission it already has.
    @Test("OC-8110: trusted, repeated pastes never request and each posts command-V")
    func trustedNeverPrompts() async {
        let r = rig(trusted: true)
        var outcomes: [PasteOutcome?] = []
        for _ in 0..<3 { outcomes.append(await choose(r)) }
        #expect(r.probe.requests.isEmpty)
        #expect(outcomes == [.pasted, .pasted, .pasted])
        #expect(r.keys.posts == 3)
    }

    // OC-8110 / FR-003-17. Copy-only mode never needs Accessibility, so it must not prompt, and must not use up the
    // session's one prompt either. Red if copy-only requests, or consumes the once-flag.
    @Test("OC-8110: copy-only never prompts and does not spend the one prompt")
    func copyOnlyDoesNotPromptOrSpendIt() async {
        let r = rig(trusted: false)
        #expect(await choose(r, mode: .copyOnly) == .copied)
        #expect(await choose(r, mode: .copyOnly) == .copied)
        #expect(r.probe.requests.isEmpty)
        // when a real paste attempt then happens it is the "first attempt" and prompts
        #expect(await choose(r) == .copiedAccessibilityDenied)
        #expect(r.probe.requests == [.accessibility])
    }

    // OC-8110. Granting afterwards must paste normally and add no request. Red if trust is not re-read per attempt.
    @Test("OC-8110: after the user grants Accessibility the next choice pastes with no further request")
    func grantAfterPromptPastes() async {
        let r = rig(trusted: false)
        #expect(await choose(r) == .copiedAccessibilityDenied)
        r.probe.setTrusted(true)
        #expect(await choose(r) == .pasted)
        #expect(r.probe.requests == [.accessibility])
        #expect(r.keys.posts == 1)
    }

    // OC-8110. Once per SESSION: revoking later and pasting again does not prompt a second time; and a revocation
    // after only trusted pastes still prompts once (the flag is set by an untrusted attempt, not by a trusted one).
    @Test("OC-8110: trusted pastes do not spend the prompt; a later revoke prompts once, then never again")
    func revokeMidSession() async {
        let r = rig(trusted: true)
        #expect(await choose(r) == .pasted)
        #expect(r.probe.requests.isEmpty)
        r.probe.setTrusted(false)
        #expect(await choose(r) == .copiedAccessibilityDenied)
        #expect(await choose(r) == .copiedAccessibilityDenied)
        #expect(r.probe.requests == [.accessibility])
        // grant, revoke again: still the single prompt for this session
        r.probe.setTrusted(true)
        #expect(await choose(r) == .pasted)
        r.probe.setTrusted(false)
        #expect(await choose(r) == .copiedAccessibilityDenied)
        #expect(r.probe.requests == [.accessibility])
    }

    // OC-8110. Only Accessibility is ever requested from the paste path (never Input Monitoring).
    @Test("OC-8110: the paste path requests nothing but Accessibility")
    func onlyAccessibilityRequested() async {
        let r = rig(trusted: false)
        _ = await choose(r)
        #expect(r.probe.requests.allSatisfy { $0 == .accessibility })
        #expect(!r.probe.requests.contains(.inputMonitoring))
    }

    // OC-8110. A new session (new service over a fresh process) prompts again: the flag is session state, not stored.
    @Test("OC-8110: a second session prompts again on its own first attempt")
    func newSessionPromptsAgain() async {
        let probe = Worf435Probe(trusted: false)
        let session1 = rig(trusted: false, probe: probe)
        _ = await choose(session1)
        _ = await choose(session1)
        #expect(probe.requests == [.accessibility])
        let session2 = rig(trusted: false, probe: probe)
        _ = await choose(session2)
        _ = await choose(session2)
        #expect(probe.requests == [.accessibility, .accessibility])
    }

    // OC-8110. The item-hotkey / expansion path shares the session's one prompt with Library paste: Library paste
    // then hotkey paste = one request total (and the reverse order too).
    @Test("OC-8110: Library paste and expanded paste share the single prompt")
    func expandedPathSharesThePrompt() async throws {
        func expansion() -> PasteExpansion {
            let board = FakePasteboard()
            let ledger = OwnWriteLedger()
            let clock = RecordingClock()
            return PasteExpansion(
                pasteboard: board, files: FakeFiles(existing: []), codec: FakeRichTextCodec(),
                preserver: ClipboardPreserver(pasteboard: board, ownWrites: ledger, clock: clock), ownWrites: ledger, clock: clock)
        }
        let a = rig(trusted: false)
        #expect(await choose(a) == .copiedAccessibilityDenied)
        let viaHotkey = try await a.service.pasteExpanded(itemId: itemId, target: Self.target, expansion: expansion()).get()
        #expect(viaHotkey == .copiedAccessibilityDenied)
        #expect(a.probe.requests == [.accessibility])

        let b = rig(trusted: false)
        let first = try await b.service.pasteExpanded(itemId: itemId, target: Self.target, expansion: expansion()).get()
        #expect(first == .copiedAccessibilityDenied)
        #expect(b.probe.requests == [.accessibility])
        #expect(await choose(b) == .copiedAccessibilityDenied)
        #expect(b.probe.requests == [.accessibility])
        #expect(b.keys.posts == 0)
    }
}
