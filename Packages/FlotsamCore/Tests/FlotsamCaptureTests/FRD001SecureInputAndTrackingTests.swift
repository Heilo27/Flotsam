import Carbon
import CoreFoundation
import Foundation
import Testing
import FlotsamBase
import FlotsamPayload
@testable import FlotsamStorage
@testable import FlotsamCapture

// TASK-156. FRD-001 FR-001-21 ("Secure Event Input has no effect on capture") and the run-loop half of AC-001-01,
// oracle .claude/oracle/frd-001-contract.json: OC-1003, OC-1022, OC-1023.
//
// Capture has no Secure Event Input seam and the FRD says it must not have one (the Triggers module is the only
// reader, FRD-005), so there is no provider to inject. The tests therefore turn the REAL system state on
// (`EnableSecureEventInput`, process scoped, balanced by `DisableSecureEventInput`) around the real ClipboardCapture
// pipeline, and assert the precondition `IsSecureEventInputEnabled() == true` before every copy, so a regression that
// reads the system call in the poll, the gates or the read path turns them red. A regression that reads it through an
// injected `KeyboardEnvironment` is caught by bin/check-architecture.sh (FR-001-21 rule). Only the ON state can be
// forced: another process on the machine may already hold Secure Event Input, so the OFF state is not reachable from
// a test and nothing here asserts it. The window is held only for the few milliseconds each copy needs.

/// Runs `body` with Secure Event Input really enabled for this process, and proves it was (the precondition the
/// assertions in `body` depend on).
@MainActor
private func withSecureEventInput(_ body: @MainActor () async throws -> Void) async throws {
    EnableSecureEventInput()
    defer { DisableSecureEventInput() }
    #expect(IsSecureEventInputEnabled(), "precondition: Secure Event Input is really on")
    try await body()
    #expect(IsSecureEventInputEnabled(), "Secure Event Input stayed on for the whole window")
}

@MainActor
@Suite("FRD-001 contract: Secure Event Input and menu tracking (TASK-156)", .serialized)
struct FRD001SecureInputAndTrackingTests {

    /// Runs the main run loop in `mode` only. Not callable from an async context, hence the detour through a sync function.
    nonisolated private static func spin(mode: RunLoop.Mode, seconds: TimeInterval) {
        _ = RunLoop.main.run(mode: mode, before: Date().addingTimeInterval(seconds))
    }

    private static func storedLines(_ rig: ContractRig) -> [LogRecord] {
        rig.sink.records.filter { $0.headline == "pasteboard.processed" && $0.publicContext.contains("outcome=stored") }
    }

    /// OC-1022 (AC-001-17). given Active, a non-ignored source and Secure Event Input on, when text is copied, then it
    /// is stored as a new item (count +1) with its exact text and source, and the processed line says stored.
    /// Mutation: in `ClipboardCapture.poll`, return early while `IsSecureEventInputEnabled()`: the count stays 0.
    @Test("OC-1022: text copied while Secure Event Input is on is stored as a new item")
    func oc1022() async throws {
        try await withRig { rig in
            try await withSecureEventInput {
                let text = "oc1022-password-field-focused-\(UUID().uuidString)"
                try #expect(await rig.itemCount() == 0)
                rig.pasteboard.copyText(text)
                await rig.process()
                let stored = try await rig.items()
                #expect(stored.count == 1)
                #expect(stored.first?.plainText == text)
                #expect(stored.first?.copyCount == 1)
                #expect(stored.first?.sourceBundleId == ContractRig.writerApp.bundleId)
                #expect(Self.storedLines(rig).count == 1)
                #expect(rig.sink.skipped.isEmpty)
            }
        }
    }

    /// OC-1023 (FR-001-21). given Secure Event Input on for the whole run, when five distinct texts are copied across
    /// 60 s (the manual clock moves 12 s between copies, the poll runs each time), then all five are stored, each with
    /// its exact text, in order, and none was skipped or raised. Mutation: gate any poll on secure input (return before
    /// `gather`), or only after the first copy: fewer than five items.
    @Test("OC-1023: five distinct texts copied during 60 s of Secure Event Input are all stored with their exact text")
    func oc1023() async throws {
        try await withRig { rig in
            try await withSecureEventInput {
                let texts = (1...5).map { "oc1023-copy-\($0)-\(UUID().uuidString)" }
                for text in texts {
                    rig.pasteboard.copyText(text)
                    await rig.process()
                    rig.clock.advance(by: 12)
                }
                let stored = try await rig.items()
                #expect(stored.count == 5)
                #expect(stored.map(\.plainText) == texts)
                #expect(stored.allSatisfy { $0.copyCount == 1 })
                #expect(Self.storedLines(rig).count == 5)
                #expect(rig.sink.skipped.isEmpty)
            }
        }
    }

    /// OC-1023 variant, the window opens and closes mid-run. given copies made before, during, between and after two
    /// secure-input windows, then every copy is stored: the state in force at the poll never decides. (Where another
    /// process already holds Secure Event Input the system state does not change at "off"; the assertion is the same.)
    /// Mutation: skip a poll while secure input is on and replay nothing: the in-window copies are lost.
    @Test("OC-1023: copies before, during and between secure-input windows are all stored")
    func oc1023Toggling() async throws {
        try await withRig { rig in
            var texts: [String] = []
            @MainActor func copy(_ label: String) async {
                let text = "oc1023-toggle-\(label)-\(UUID().uuidString)"
                texts.append(text)
                rig.pasteboard.copyText(text)
                await rig.process()
            }
            await copy("before")
            try await withSecureEventInput { await copy("window1") }
            await copy("between")
            try await withSecureEventInput { await copy("window2") }
            await copy("after")
            let stored = try await rig.items()
            #expect(stored.map(\.plainText) == texts)
            #expect(rig.sink.skipped.isEmpty)
        }
    }

    /// FR-001-21 with the gates of FR-001-04 (the concealed-copy ruling). given Secure Event Input on, then a normal
    /// copy is stored, a concealed copy is stored as an encrypted, masked secure item (no plain text anywhere), a
    /// transient copy is dropped with CAP-POL-001 and a copy from an ignored app is dropped with CAP-POL-002: the
    /// gates decide exactly as they do with secure input off. Mutation: let secure input bypass a gate (store the
    /// transient copy), or drop the concealed copy: the counts or the codes change.
    @Test("FR-001-21: under Secure Event Input the gates still decide alike: concealed sealed, transient and ignored-app dropped")
    func gatesUnchangedUnderSecureInput() async throws {
        try await withRig(withVault: true) { rig in
            try await withSecureEventInput {
                let normal = "fr00121-normal-\(UUID().uuidString)"
                let concealed = "secret-marker-fr00121-concealed-\(UUID().uuidString)"
                let transient = "secret-marker-fr00121-transient-\(UUID().uuidString)"
                let ignoredText = "fr00121-ignored-\(UUID().uuidString)"

                rig.pasteboard.copyText(normal)
                await rig.process()
                rig.pasteboard.copy([(PB.text, PB.data(concealed)), (PasteboardMarkers.concealed, Data("1".utf8))])
                await rig.process()
                rig.pasteboard.copy([(PB.text, PB.data(transient)), (PasteboardMarkers.transient, Data("1".utf8))])
                await rig.process()
                rig.ignored = ["com.example.ignored"]
                rig.pasteboard.copy([
                    (PB.text, PB.data(ignoredText)), (PasteboardMarkers.source, Data("com.example.ignored".utf8)),
                ])
                await rig.process()
                await rig.flush()

                // normal text and the concealed copy are stored; transient and ignored-app copies are not
                try #expect(await rig.itemCount() == 2)
                try #expect(await rig.item(withText: normal).count == 1)
                let secure = try await rig.secureRows()
                #expect(secure.count == 1)
                #expect(secure.first?.plainText == nil)
                #expect(secure.first?.ciphertext?.isEmpty == false)
                try #expect(await rig.item(withText: ignoredText).isEmpty)
                #expect(rig.sink.logged(.capPol001).count == 1)
                #expect(rig.sink.logged(.capPol002).count == 1)
                // no content of the concealed or the transient copy reaches the database, its WAL or the log
                #expect(rig.allDataBytes().range(of: Data(concealed.utf8)) == nil)
                #expect(!rig.sink.everything.contains(concealed))
                #expect(!rig.sink.everything.contains(transient))
            }
        }
    }

    /// OC-1003 (AC-001-01). given Active, a non-ignored source, and the main run loop held in a tracking-style mode
    /// (what AppKit does while another app's Edit menu is open: a custom COMMON mode, never `.default`), when text T is
    /// written to the pasteboard, then the production timer alone (nothing calls `captureNow`) captures it while the
    /// loop has never returned to `.default`; and afterwards the Library holds exactly one item with text T. The 0.6 s
    /// bound is the 0.5 s interval plus 0.1 s tolerance (OC-115-01 pins both numbers); a wall-clock assertion would
    /// measure machine load (TASK-459), so the wait here is a 10 s hang guard that returns the moment the entry is
    /// logged. Mutation: add the timer for `.default` instead of `.common` in `ClipboardCapture.systemTimer`: the loop
    /// never fires it in the tracking mode and the guard expires.
    @Test("OC-1003: a copy made while the run loop is in a menu-tracking mode is captured by the timer, not on menu close")
    func oc1003() async throws {
        try await withRig { rig in
            let mode = "frd001.oc1003.tracking"
            CFRunLoopAddCommonMode(CFRunLoopGetMain(), CFRunLoopMode(mode as CFString))
            let text = "oc1003-menu-open-\(UUID().uuidString)"
            rig.pasteboard.copyText(text)

            let deadline = Date().addingTimeInterval(10)
            while Self.storedLines(rig).isEmpty, Date() < deadline { Self.spin(mode: RunLoop.Mode(mode), seconds: 0.02) }
            #expect(Self.storedLines(rig).count == 1, "stored while only the tracking mode ran")

            // the menu closes: the loop returns to .default and the item is in the Library
            let landed = await rig.until(seconds: 10) { try await rig.item(withText: text).count == 1 }
            #expect(landed)
            try #expect(await rig.itemCount() == 1)
        }
    }
}
