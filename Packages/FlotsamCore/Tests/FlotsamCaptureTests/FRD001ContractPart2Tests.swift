import Foundation
import Testing
import FlotsamBase
import FlotsamPayload
@testable import FlotsamStorage
@testable import FlotsamCapture

// FRD-001 Capture, 8T contract tests, part 2: OC-1056..OC-1110 (oracle .claude/oracle/frd-001-contract.json).
// Same rules as part 1 (FRD001ContractTests.swift): the real capture pipeline against a real database through the
// harness in FRD001ContractHarness.swift, literal expectations only, one OC id per test. Unreachable IDs are listed at
// the end of this file.

@MainActor
func noticeMessages(_ rig: ContractRig, code: ErrorCode) -> [String] {
    rig.presenter.latestNotices.filter { $0.code == code }.map(\.message)
}

// MARK: Batch 1: OC-1056..OC-1066 (file ceilings, source resolution, remote clipboard)

@MainActor
@Suite("FRD-001 contract part 2: symlinks and the 500-member ceiling")
struct FRD001FileCeilingContractTests {

    @Test("OC-1056: a symlink link.txt is stored under its own name, not its target's")
    func oc1056() async throws {
        // given link.txt -> target.txt; when link.txt is copied; then one file item named link.txt (a resolved link
        // would name target.txt).
        try await withRig { rig in
            let target = try rig.makeFile("target.txt")
            let link = rig.files.appendingPathComponent("link.txt")
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
            rig.pasteboard.copy(PB.fileURLReps([link]))
            await rig.process()
            let stored = try await rig.items()
            #expect(stored.map(\.kind) == ["file"])
            try #expect(await rig.members(of: stored[0].id).map(fileName) == ["link.txt"])
        }
    }

    @Test("OC-1057: 600 files give one bundle of the first 500 in pasteboard order and the CAP-LIM-003 Notice for 600")
    func oc1057() async throws {
        // given 600 files copied in an order that is NOT alphabetical; then count +1, 500 members, the first 500 in order.
        try await withRig { rig in
            let urls = try (0..<600).map { try rig.makeFile("f\($0).txt") }
            rig.pasteboard.copy(PB.fileURLReps(urls))
            await rig.process()
            #expect(await rig.until { !noticeMessages(rig, code: .capLim003).isEmpty })
            let stored = try await rig.items()
            #expect(stored.count == 1)
            #expect(stored.map(\.kind) == ["bundle"])
            let members = try await rig.members(of: stored[0].id).map(fileName)
            #expect(members.count == 500)
            #expect(members == (0..<500).map { "f\($0).txt" })
            // L-A: the message carries the copy's 600 files and the fixed first-500 ceiling, never 500 for both.
            #expect(noticeMessages(rig, code: .capLim003) == ["A copy of 600 files was trimmed to the first 500."])
            #expect(rig.sink.logged(.capLim003).count == 1)
        }
    }

    @Test("OC-1058: exactly 500 files give one bundle of 500 and no CAP-LIM-003 in log or Notices")
    func oc1058() async throws {
        // given exactly 500 files; then one bundle with 500 members, and nothing trimmed.
        try await withRig { rig in
            let urls = try (0..<500).map { try rig.makeFile("g\($0).txt") }
            rig.pasteboard.copy(PB.fileURLReps(urls))
            await rig.process()
            let stored = try await rig.items()
            #expect(stored.map(\.kind) == ["bundle"])
            try #expect(await rig.members(of: stored[0].id).count == 500)
            await rig.flush()
            #expect(rig.sink.logged(.capLim003).isEmpty)
            #expect(noticeMessages(rig, code: .capLim003).isEmpty)
            #expect(rig.presenter.latestNotices.isEmpty)
        }
    }

    @Test("OC-1058 boundary: 501 files are trimmed to 500 and the Notice says 501 (L-A, the count is the copy's, not the ceiling)")
    func oc1058Boundary501() async throws {
        // given 501 files (max + 1); then 500 members and a Notice naming 501.
        try await withRig { rig in
            let urls = try (0..<501).map { try rig.makeFile("h\($0).txt") }
            rig.pasteboard.copy(PB.fileURLReps(urls))
            await rig.process()
            #expect(await rig.until { !noticeMessages(rig, code: .capLim003).isEmpty })
            let stored = try await rig.items()
            #expect(stored.count == 1)
            try #expect(await rig.members(of: stored[0].id).count == 500)
            #expect(noticeMessages(rig, code: .capLim003) == ["A copy of 501 files was trimmed to the first 500."])
        }
    }
}

@MainActor
@Suite("FRD-001 contract part 2: source resolution and the remote clipboard")
struct FRD001SourceContractTests {

    private func sidebarApps(_ rig: ContractRig) async throws -> [SidebarCounts.AppCount] {
        try await rig.database.sidebarCounts().get().apps
    }

    @Test("OC-1059: the source marker names app B even though app A is frontmost")
    func oc1059() async throws {
        // given A frontmost; when A writes text with the marker = B; then the item's source is B (stored and in the
        // sidebar's Apps), not A.
        try await withRig(frontmost: SourceApp(bundleId: "com.example.a", name: "Aye")) { rig in
            rig.sourceApps.names["com.example.b"] = "Bee"
            rig.pasteboard.copy([(PB.text, PB.data(uid("B"))), (PasteboardMarkers.source, PB.data("com.example.b"))])
            await rig.process()
            let stored = try await rig.items()
            #expect(stored.count == 1)
            #expect(stored.first?.sourceBundleId == "com.example.b")
            #expect(stored.first?.sourceName == "Bee")
            let apps = try await sidebarApps(rig)
            #expect(apps.map(\.identity) == [.bundle("com.example.b")])
            #expect(apps.first?.name == "Bee")
            #expect(apps.first?.count == 1)
        }
    }

    @Test("OC-1060: with no source marker the frontmost app C is the source")
    func oc1060() async throws {
        // given C frontmost; when C writes text with no marker; then the source is C.
        try await withRig(frontmost: SourceApp(bundleId: "com.example.c", name: "Sea")) { rig in
            rig.pasteboard.copyText(uid("C"))
            await rig.process()
            let stored = try await rig.items()
            #expect(stored.count == 1)
            #expect(stored.first?.sourceBundleId == "com.example.c")
            #expect(stored.first?.sourceName == "Sea")
        }
    }

    @Test("OC-1061: no marker and no frontmost app stores the item with no source and logs CAP-OS-002")
    func oc1061() async throws {
        // given nothing resolves; when text is copied; then count +1, source Unknown (nil bundle id and name), one CAP-OS-002.
        try await withRig(frontmost: nil) { rig in
            let text = uid("U")
            rig.pasteboard.copyText(text)
            await rig.process()
            let stored = try await rig.items()
            #expect(stored.count == 1)
            #expect(stored.first?.plainText == text)
            #expect(stored.first?.sourceBundleId == nil)
            #expect(stored.first?.sourceName == nil)
            #expect(rig.sink.logged(.capOs002).count == 1)
            let apps = try await sidebarApps(rig)
            #expect(apps.map(\.identity) == [.unknown])
        }
    }

    @Test("OC-1062: an empty source marker is ignored and the frontmost app C is the source")
    func oc1062() async throws {
        // given C frontmost; marker present but empty; then the source is C. Whitespace-only is empty too.
        try await withRig(frontmost: SourceApp(bundleId: "com.example.c", name: "Sea")) { rig in
            rig.pasteboard.copy([(PB.text, PB.data(uid("E1"))), (PasteboardMarkers.source, Data())])
            await rig.process()
            rig.pasteboard.copy([(PB.text, PB.data(uid("E2"))), (PasteboardMarkers.source, PB.data("  \n"))])
            await rig.process()
            let stored = try await rig.items()
            #expect(stored.count == 2)
            #expect(stored.map(\.sourceBundleId) == ["com.example.c", "com.example.c"])
            #expect(rig.sink.logged(.capOs002).isEmpty)
        }
    }

    @Test("OC-1063: the resolved source (marker B, ignored) is gated, not the frontmost app A")
    func oc1063() async throws {
        // given B ignored, A not; when A writes text with the marker = B; then nothing stored and one CAP-POL-002.
        try await withRig(frontmost: SourceApp(bundleId: "com.example.a", name: "Aye")) { rig in
            rig.ignored = ["com.example.b"]
            let text = uid("T")
            rig.pasteboard.copy([(PB.text, PB.data(text)), (PasteboardMarkers.source, PB.data("com.example.b"))])
            await rig.process()
            try #expect(await rig.itemCount() == 0)
            #expect(rig.sink.logged(.capPol002).count == 1)
            // negative control: the same marker from a non-ignored app B2 is stored.
            rig.pasteboard.copy([(PB.text, PB.data(text + "-ok")), (PasteboardMarkers.source, PB.data("com.example.b2"))])
            await rig.process()
            try #expect(await rig.items().map(\.sourceBundleId) == ["com.example.b2"])
        }
    }

    @Test("OC-1064: a remote clipboard copy is stored with source 'Another device' and listed under Apps")
    func oc1064() async throws {
        // given a remote pasteboard with text H; then one item for H, source 'Another device', sidebar Apps lists it.
        try await withRig { rig in
            let text = uid("H")
            rig.pasteboard.copy([(PB.text, PB.data(text)), (PasteboardMarkers.remoteClipboard, Data())])
            await rig.process()
            let stored = try await rig.items()
            #expect(stored.count == 1)
            #expect(stored.first?.plainText == text)
            #expect(stored.first?.sourceName == "Another device")
            #expect(stored.first?.sourceBundleId == nil)
            let apps = try await sidebarApps(rig)
            #expect(apps.map(\.identity) == [.anotherDevice])
            #expect(apps.first?.count == 1)
        }
    }

    @Test("OC-1065: the ignored list cannot match a remote copy, even from an ignored frontmost app")
    func oc1065() async throws {
        // given the frontmost app is ignored; when a remote pasteboard J arrives; then J is stored as 'Another device'.
        try await withRig(frontmost: SourceApp(bundleId: "com.example.ignored", name: "Ignored")) { rig in
            rig.ignored = ["com.example.ignored"]
            let text = uid("J")
            rig.pasteboard.copy([(PB.text, PB.data(text)), (PasteboardMarkers.remoteClipboard, Data())])
            await rig.process()
            let stored = try await rig.items()
            #expect(stored.count == 1)
            #expect(stored.first?.plainText == text)
            #expect(stored.first?.sourceName == "Another device")
            #expect(rig.sink.logged(.capPol002).isEmpty)
            // negative control: the same app's local copy is still dropped.
            rig.pasteboard.copyText(uid("local"))
            await rig.process()
            try #expect(await rig.itemCount() == 1)
            #expect(rig.sink.logged(.capPol002).count == 1)
        }
    }

    @Test("OC-1066: a remote clipboard copy that is also Concealed is rejected with CAP-POL-001")
    func oc1066() async throws {
        // given remote + ConcealedType + text K; then no item for K, one CAP-POL-001.
        try await withRig { rig in
            let text = uid("K")
            rig.pasteboard.copy([
                (PB.text, PB.data(text)), (PasteboardMarkers.remoteClipboard, Data()),
                (PasteboardMarkers.concealed, Data("1".utf8)),
            ])
            await rig.process()
            try #expect(await rig.item(withText: text).isEmpty)
            try #expect(await rig.itemCount() == 0)
            #expect(rig.sink.logged(.capPol001).count == 1)
            #expect(!rig.sink.everything.contains(text))
        }
    }
}
