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

// MARK: Batch 2: OC-1067..OC-1075 (dedupe)

@MainActor
private func recentRows(_ rig: ContractRig) async throws -> [ItemRow] {
    try await rig.database.items(matching: LibraryQuery(sort: .recent)).get().rows
}

@MainActor
@Suite("FRD-001 contract part 2: dedupe by content")
struct FRD001DedupeContractTests {

    @Test("OC-1067: copying 'abc' again keeps one item with its tag, copy count 2, first in Recent")
    func oc1067() async throws {
        // given 'abc' tagged 'work'; when 'abc' is copied again; then count stays 1, tag kept, copyCount 2.
        try await withRig { rig in
            await rig.copyText("abc")
            let id = try #require(UUID(uuidString: try await rig.items()[0].id))
            _ = try await rig.database.createTagAndApply(name: "work", to: [id]).get()
            await rig.copyText("abc")
            let stored = try await rig.items()
            #expect(stored.count == 1)
            #expect(stored.map(\.copyCount) == [2])
            let rows = try await recentRows(rig)
            #expect(rows.map(\.id) == [id])
            #expect(rows.first?.tagNames == ["work"])
            // persisted: a fresh database instance sees the same single item.
            try #expect(await rig.freshItemCount() == 1)
        }
    }

    @Test("OC-1068: a trailing space and a different case are each a new item")
    func oc1068() async throws {
        // given 'abc'; when 'abc ' then 'ABC' are copied; then three distinct items, each copied once.
        try await withRig { rig in
            await rig.copyText("abc")
            await rig.copyText("abc ")
            await rig.copyText("ABC")
            let stored = try await rig.items()
            #expect(stored.count == 3)
            #expect(stored.map(\.plainText) == ["abc", "abc ", "ABC"])
            #expect(stored.map(\.copyCount) == [1, 1, 1])
        }
    }

    @Test("OC-1069: re-copying an old pinned item with a note and tag bumps it to the top and changes nothing else")
    func oc1069() async throws {
        // given pinned D (note, tag) last copied 20 days ago below 50 newer items; when D is copied again from another app.
        try await withRig { rig in
            let text = uid("D")
            await rig.copyText(text)
            let d = try await rig.items()[0]
            let id = try #require(UUID(uuidString: d.id))
            _ = try await rig.database.setPinned(ids: [id], pinned: true).get()
            _ = try await rig.database.setNote("keep this", for: id).get()
            _ = try await rig.database.createTagAndApply(name: "work", to: [id]).get()
            let twentyDaysAgoMillis = Int64((rig.clock.now().timeIntervalSince1970 - 20 * 86_400) * 1000)
            try await rig.database.pool.write {
                try $0.execute(sql: "UPDATE item SET lastCopiedAt = ? WHERE id = ?", arguments: [twentyDaysAgoMillis, d.id])
            }
            for n in 0..<50 { await rig.copyText(uid("newer\(n)")) }
            let before = try await recentRows(rig)
            #expect(before.count == 51)
            #expect(before.last?.id == id)  // D sits below all 50 newer items, pinned or not
            try #expect(await rig.itemCount() == 51)

            rig.clock.advance(by: 60)  // the rig's capture clock is manual: a later copy needs a later time
            rig.sourceApps.frontmost = SourceApp(bundleId: "com.example.other", name: "Other")
            await rig.copyText(text)

            try #expect(await rig.itemCount() == 51)
            let after = try await recentRows(rig)
            #expect(after.first?.id == id)
            #expect(after.first?.isPinned == true)
            #expect(after.first?.tagNames == ["work"])
            #expect(after.first?.kind == .text)
            #expect(after.first?.sourceName == "Writer")
            try #expect(await rig.database.note(of: id).get() == "keep this")
            let stored = try #require(try await rig.items().first { $0.id == d.id })
            #expect(stored.copyCount == 2)
            #expect(stored.kind == "text")
            #expect(stored.sourceBundleId == "com.example.writer")
        }
    }

    @Test("OC-1070: the same text copied with HTML bumps the plain item and its stored representations stay plain (reachable half)")
    func oc1070() async throws {
        // given a plain text item; when the same text arrives with public.html; then delta 0 and no html is stored.
        try await withRig { rig in
            let text = uid("Hello")
            await rig.copyText(text)
            let id = try await rig.items()[0].id
            let before = try await rig.representationTypes(of: id)
            await rig.copyText(text, extra: [(PB.html, PB.data("<b>\(text)</b>"))])
            let stored = try await rig.items()
            #expect(stored.count == 1)
            #expect(stored.map(\.kind) == ["text"])
            #expect(stored.map(\.copyCount) == [2])
            let after = try await rig.representationTypes(of: id)
            #expect(after == before)
            #expect(!after.contains(PB.html))
            let content = try await rig.database.content(of: try #require(UUID(uuidString: id))).get()
            #expect(!content.storedRepresentations.map(\.uti).contains(PB.html))
        }
    }

    @Test("OC-1071: identical PNG bytes copied twice give one image with copy count 2; different pixels are a new item")
    func oc1071() async throws {
        // given PNG P; when copied twice; then +1 then delta 0, copyCount 2. Negative control: different bytes +1.
        try await withRig { rig in
            let png = TestImage.make(.png, width: 20, height: 10, seed: 1)
            rig.pasteboard.copy(PB.png, png)
            await rig.process()
            try #expect(await rig.itemCount() == 1)
            rig.pasteboard.copy(PB.png, png)
            await rig.process()
            let stored = try await rig.items()
            #expect(stored.count == 1)
            #expect(stored.map(\.kind) == ["image"])
            #expect(stored.map(\.copyCount) == [2])
            rig.pasteboard.copy(PB.png, TestImage.make(.png, width: 20, height: 10, seed: 2))
            await rig.process()
            try #expect(await rig.itemCount() == 2)
        }
    }

    @Test("OC-1072: a screenshot's exact bytes copied to the pasteboard bump it and it stays a screenshot")
    func oc1072() async throws {
        // given a screenshot item ingested by the screenshot pipeline; when its bytes are copied as public.png.
        try await withRig { rig in
            let png = TestImage.make(.png, width: 40, height: 30, seed: 5)
            let candidate = IngestCandidate(
                kind: .screenshot, contentKey: ContentKey.image(png),
                representations: [PasteboardRepresentation(uti: PB.png, data: png)], source: nil, origin: .screenshotFile,
                occurredAt: Date(), originalPath: rig.files.appendingPathComponent("shot.png").path)
            let result = await IngestActor(database: rig.database, settings: rig.settings).ingest(candidate)
            _ = try result.get()
            let before = try await rig.items()
            #expect(before.map(\.kind) == ["screenshot"])
            #expect(before.map(\.copyCount) == [1])

            rig.pasteboard.copy(PB.png, png)
            await rig.process()
            let after = try await rig.items()
            #expect(after.count == 1)
            #expect(after.map(\.id) == before.map(\.id))
            #expect(after.map(\.kind) == ["screenshot"])
            #expect(after.map(\.copyCount) == [2])
        }
    }

    @Test("OC-1073: files A,B twice are one bundle with copy count 2; B,A is a new bundle")
    func oc1073() async throws {
        // given files A and B; when A,B twice then B,A; then count 1 (copyCount 2) then 2.
        try await withRig { rig in
            let a = try rig.makeFile("A.txt")
            let b = try rig.makeFile("B.txt")
            rig.pasteboard.copy(PB.fileURLReps([a, b]))
            await rig.process()
            rig.pasteboard.copy(PB.fileURLReps([a, b]))
            await rig.process()
            var stored = try await rig.items()
            #expect(stored.count == 1)
            #expect(stored.map(\.kind) == ["bundle"])
            #expect(stored.map(\.copyCount) == [2])
            let first = stored[0].id
            rig.pasteboard.copy(PB.fileURLReps([b, a]))
            await rig.process()
            stored = try await rig.items()
            try #require(stored.count == 2)
            #expect(stored.map(\.kind) == ["bundle", "bundle"])
            #expect(stored.map(\.copyCount) == [2, 1])
            #expect(stored[0].id == first)
            try #expect(await rig.members(of: stored[1].id).map(fileName) == ["B.txt", "A.txt"])
        }
    }

    @Test("OC-1074: after an edit, copying the new text bumps the edited item and copying the old text creates a new one")
    func oc1074() async throws {
        // given 'foo' edited to 'bar'; when 'bar' is copied then 'foo'.
        try await withRig { rig in
            let foo = uid("foo"), bar = uid("bar")
            await rig.copyText(foo)
            let id = try #require(UUID(uuidString: try await rig.items()[0].id))
            _ = try await rig.database.editText(id: id, to: bar, classifiers: .live).get()
            await rig.copyText(bar)
            var stored = try await rig.items()
            #expect(stored.count == 1)
            #expect(stored.map(\.plainText) == [bar])
            #expect(stored.map(\.copyCount) == [2])
            await rig.copyText(foo)
            stored = try await rig.items()
            #expect(stored.count == 2)
            #expect(stored.map(\.plainText) == [bar, foo])
            #expect(stored.map(\.copyCount) == [2, 1])
        }
    }

    @Test("OC-1075: NFC and NFD forms of the same letter are two items: no Unicode normalisation")
    func oc1075() async throws {
        // given U+00E9 copied, then U+0065 U+0301; then two items. Compared by scalars: String == would hide the difference.
        try await withRig { rig in
            await rig.copyText("\u{00E9}")
            await rig.copyText("e\u{0301}")
            let stored = try await rig.items()
            #expect(stored.count == 2)
            #expect(stored.map { Array(($0.plainText ?? "").unicodeScalars.map(\.value)) } == [[0xE9], [0x65, 0x301]])
            #expect(stored.map(\.copyCount) == [1, 1])
        }
    }
}

// MARK: Batch 3: OC-1076..OC-1078, OC-1107..OC-1109 (ingest ceilings and their Notices)

private let tenMiB = 10 * 1024 * 1024
private let fiveMiB = 5 * 1024 * 1024
private let hundredMiB = 100 * 1024 * 1024

/// The one info-only outcome shape of OC-1100..OC-1107: logged once at info, never a Notice, HUD or warning dot.
@MainActor
private func expectInfoOnly(_ rig: ContractRig, _ code: ErrorCode, sourceLocation: SourceLocation = #_sourceLocation) {
    let records = rig.sink.logged(code)
    #expect(records.count == 1, "exactly one \(code.rawValue) record", sourceLocation: sourceLocation)
    #expect(records.map(\.level) == [.info], "\(code.rawValue) logs at info", sourceLocation: sourceLocation)
    #expect(rig.presenter.latestNotices.isEmpty, "no Notice, so no warning dot", sourceLocation: sourceLocation)
    #expect(rig.presenter.huds.isEmpty, "no HUD", sourceLocation: sourceLocation)
}

/// A valid 10 x 10 PNG followed by zero padding so the whole representation is exactly `total` bytes.
private func paddedPNG(total: Int) -> Data {
    let png = TestImage.make(.png, width: 10, height: 10, seed: 3)
    return png + Data(repeating: 0, count: total - png.count)
}

@MainActor
@Suite("FRD-001 contract part 2: ingest ceilings")
struct FRD001LimitContractTests {

    @Test("OC-1076 / OC-1108 (L-B pin): text over 10 MiB stores nothing, raises CAP-LIM-001 with {limit} filled, leaves the pasteboard alone")
    func oc1076() async throws {
        // given one stored item and 10 MiB + 1 byte of text; then delta 0, the Notice names the limit, the clipboard is intact.
        try await withRig { rig in
            await rig.copyText(uid("baseline"))
            let big = String(repeating: "a", count: tenMiB + 1)
            rig.pasteboard.copyText(big)
            let changeBefore = rig.pasteboard.changeCount
            await rig.process()
            #expect(await rig.until { !noticeMessages(rig, code: .capLim001).isEmpty })
            try #expect(await rig.itemCount() == 1)
            #expect(noticeMessages(rig, code: .capLim001) == ["A copy was too large to save (over 10 MB). It is still on your clipboard."])
            #expect(!rig.presenter.latestNotices.isEmpty)
            #expect(rig.sink.logged(.capLim001).map(\.level) == [.default])
            #expect(rig.pasteboard.writes == 0)
            #expect(rig.pasteboard.changeCount == changeBefore)
            let held = try rig.pasteboard.readSnapshot(types: [PB.text]).get().representations
            #expect(held.count == 1)
            #expect(held.first?.data == Data(repeating: 0x61, count: 10_485_761))
        }
    }

    @Test("OC-1076 boundary: exactly 10 MiB of text is stored and raises no CAP-LIM-001")
    func oc1076AtCeiling() async throws {
        // given exactly 10 MiB; then count +1 and no LIM-001 anywhere. Kills `>` weakened to `>=` in the text ceiling.
        try await withRig { rig in
            rig.pasteboard.copyText(String(repeating: "b", count: tenMiB))
            await rig.process()
            #expect(await rig.until { (try await rig.itemCount()) == 1 })
            #expect(rig.sink.logged(.capLim001).isEmpty)
            #expect(rig.presenter.latestNotices.isEmpty)
        }
    }

    @Test("OC-1077: plain text with an html over 5 MiB stores one item without the html, logs CAP-LIM-002 only")
    func oc1077() async throws {
        // given text plus 5 MiB + 1 byte of html; then count +1, no html stored, LIM-002 once at info, no Notice or HUD.
        try await withRig { rig in
            let text = uid("rich")
            await rig.copyText(uid("baseline"))
            await rig.copyText(text, extra: [(PB.html, Data(repeating: 0x20, count: fiveMiB + 1))])
            let stored = try await rig.items()
            #expect(stored.count == 2)
            let mine = try #require(stored.first { $0.plainText == text })
            try #expect(await rig.representationTypes(of: mine.id).contains(PB.html) == false)
            #expect(mine.plainText == text, "the plain text is kept")
            expectInfoOnly(rig, .capLim002)
        }
    }

    @Test("OC-1077 boundary: html of exactly 5 MiB is kept and CAP-LIM-002 is not logged")
    func oc1077AtCeiling() async throws {
        try await withRig { rig in
            let text = uid("rich")
            await rig.copyText(text, extra: [(PB.html, Data(repeating: 0x20, count: fiveMiB))])
            let stored = try await rig.items()
            #expect(stored.count == 1)
            try #expect(await rig.representationTypes(of: stored[0].id).contains(PB.html))
            #expect(rig.sink.logged(.capLim002).isEmpty)
        }
    }

    @Test("OC-1078: an image over 100 MiB stores nothing and raises CAP-LIM-001 naming 100 MB")
    func oc1078() async throws {
        // given one stored item and a PNG of 100 MiB + 1 byte; then delta 0 and the Notice names the image ceiling.
        try await withRig { rig in
            await rig.copyText(uid("baseline"))
            rig.pasteboard.copy(PB.png, paddedPNG(total: hundredMiB + 1))
            await rig.process()
            #expect(await rig.until { !noticeMessages(rig, code: .capLim001).isEmpty })
            try #expect(await rig.itemCount() == 1)
            #expect(noticeMessages(rig, code: .capLim001) == ["A copy was too large to save (over 100 MB). It is still on your clipboard."])
            #expect(rig.pasteboard.writes == 0)
        }
    }

    @Test("OC-1078 boundary: an image of exactly 100 MiB is stored with no CAP-LIM-001")
    func oc1078AtCeiling() async throws {
        try await withRig { rig in
            rig.pasteboard.copy(PB.png, paddedPNG(total: hundredMiB))
            await rig.process()
            #expect(await rig.until(seconds: 20) { (try await rig.kinds()) == ["image"] })
            #expect(rig.sink.logged(.capLim001).isEmpty)
            #expect(rig.presenter.latestNotices.isEmpty)
        }
    }

    @Test("OC-1107: a rich representation over its ceiling is info only: no Notice, no HUD, no dot")
    func oc1107() async throws {
        try await withRig { rig in
            await rig.copyText(uid("rich"), extra: [(PB.rtf, Data(repeating: 0x20, count: fiveMiB + 1))])
            try #expect(await rig.itemCount() == 1)
            expectInfoOnly(rig, .capLim002)
        }
    }

    @Test("OC-1109: a 600-file copy raises CAP-LIM-003 with n = 600 and the warning dot shows")
    func oc1109() async throws {
        try await withRig { rig in
            rig.pasteboard.copy(PB.fileURLReps(try (0..<600).map { try rig.makeFile("g\($0).txt") }))
            await rig.process()
            #expect(await rig.until { !noticeMessages(rig, code: .capLim003).isEmpty })
            #expect(noticeMessages(rig, code: .capLim003) == ["A copy of 600 files was trimmed to the first 500."])
            #expect(!rig.presenter.latestNotices.isEmpty)
        }
    }
}

// MARK: Batch 3: OC-1080..OC-1083, OC-1085, OC-1087, OC-1098 (privacy suspension and resume, modes)

private let prmMessage = "macOS is blocking Flotsam from reading copied items. Allow Flotsam under Paste from Other Apps in System Settings."

/// One clipboard change whose types list is empty (what macOS gives an app it has blocked), watched until its watch
/// ends (FR-001-01), when FR-001-18 b counts it as one empty change, then settled.
@MainActor
private func emptyChange(_ rig: ContractRig) async {
    rig.pasteboard.copy([PasteboardRepresentation]())
    rig.capture.captureNow()
    rig.clock.advance(by: ClipboardCapture.emptyChangeWatchLimit)
    rig.capture.captureNow()
    await rig.flush()
}

@MainActor
private func suspendCapture(_ rig: ContractRig) async {
    for _ in 0..<3 { await emptyChange(rig) }
    _ = await rig.until { !noticeMessages(rig, code: .capPrm001).isEmpty }
}

@MainActor
@Suite("FRD-001 contract part 2: privacy suspension, resume and modes")
struct FRD001SuspensionContractTests {

    @Test("OC-1080 / OC-1098: three blocked changes raise CAP-PRM-001 with its catalogue message, the dot shows, nothing is stored")
    func oc1080() async throws {
        try await withRig { rig in
            await suspendCapture(rig)
            #expect(noticeMessages(rig, code: .capPrm001) == [prmMessage])
            #expect(!rig.presenter.latestNotices.isEmpty, "the menu-bar dot")
            #expect(rig.sink.logged(.capPrm001).map(\.level) == [.default], "notice level")
            try #expect(await rig.itemCount() == 0)
        }
    }

    @Test("OC-1080 boundary: two blocked changes raise only the info CAP-VAL-001, never CAP-PRM-001")
    func oc1080TwoChanges() async throws {
        try await withRig { rig in
            await emptyChange(rig)
            await emptyChange(rig)
            #expect(noticeMessages(rig, code: .capPrm001).isEmpty)
            #expect(rig.presenter.latestNotices.isEmpty)
            #expect(rig.sink.logged(.capPrm001).isEmpty)
            #expect(rig.sink.logged(.capVal001).count == 2)
        }
    }

    @Test("OC-1081: after suspension a readable copy is stored within one tick AND the warning dot clears")
    func oc1081() async throws {
        // given suspended capture; when access returns and V is copied (the 0.5 s timer, no manual poll); then V is
        // stored and the CAP-PRM-001 Notice is gone. Fails today if nothing clears the Notice on resume.
        try await withRig { rig in
            await suspendCapture(rig)
            #expect(!noticeMessages(rig, code: .capPrm001).isEmpty)
            let v = uid("V")
            rig.pasteboard.copyText(v)
            #expect(await rig.until(seconds: 2) { try await rig.item(withText: v).count == 1 })
            await rig.flush()
            #expect(noticeMessages(rig, code: .capPrm001).isEmpty, "CAP-PRM-001 must clear when capture resumes")
            #expect(rig.presenter.latestNotices.isEmpty, "the warning dot must clear when capture resumes")
        }
    }

    @Test("OC-1082: two blocked changes then a readable copy raise no CAP-PRM-001 and the copy is stored; the count restarts")
    func oc1082() async throws {
        try await withRig { rig in
            await emptyChange(rig)
            await emptyChange(rig)
            let readable = uid("readable")
            await rig.copyText(readable)
            try #expect(await rig.item(withText: readable).count == 1)
            // the readable change reset the run: two more blocked changes still do not suspend.
            await emptyChange(rig)
            await emptyChange(rig)
            #expect(rig.sink.logged(.capPrm001).isEmpty)
            #expect(rig.presenter.latestNotices.isEmpty)
        }
    }

    @Test("OC-1083: after suspension, access returns without a new copy; the 60 s probe resumes capture and clears the warning")
    func oc1083() async throws {
        // given suspension on an empty pasteboard; when the text becomes readable with NO changeCount bump and 60 s pass;
        // then the probe stores it and the Notice clears.
        try await withRig { rig in
            await suspendCapture(rig)
            let v = uid("probe")
            rig.pasteboard.reveal([PasteboardRepresentation(uti: PB.text, data: PB.data(v))])
            rig.clock.advance(by: 60)
            #expect(await rig.until(seconds: 3) { try await rig.item(withText: v).count == 1 }, "the probe stores the now-readable copy")
            await rig.flush()
            #expect(noticeMessages(rig, code: .capPrm001).isEmpty, "CAP-PRM-001 must clear when capture resumes")
            #expect(rig.presenter.latestNotices.isEmpty, "the warning dot must clear when capture resumes")
        }
    }

    @Test("OC-1083 boundary: 59 s after suspension the probe has not run and the copy is not stored yet")
    func oc1083TooEarly() async throws {
        try await withRig { rig in
            await suspendCapture(rig)
            let v = uid("early")
            rig.pasteboard.reveal([PasteboardRepresentation(uti: PB.text, data: PB.data(v))])
            rig.clock.advance(by: 59)
            try await Task.sleep(for: .milliseconds(1200))
            try #expect(await rig.item(withText: v).isEmpty)
        }
    }

    @Test("OC-1085 (Curated half): in Curated mode a copy stores nothing and logs CAP-POL-003 once")
    func oc1085() async throws {
        try await withRig { rig in
            rig.settings.set(.curated, for: SettingKeys.captureMode)
            let c = uid("C")
            await rig.copyText(c)
            try #expect(await rig.itemCount() == 0)
            #expect(rig.sink.logged(.capPol003).count == 1)
        }
    }

    @Test("OC-1087: Paused, then resumed, a copy 0.1 s later is detected within 0.6 s and stored")
    func oc1087() async throws {
        // given Paused, then Active; when N is copied after the resume; then the poll source capture left running
        // is bound to the contract's 0.6 s (interval + tolerance: the longest a copy can wait for the next tick) and
        // the very next tick reads N and stores it once. Runs on the timer seam (ADR-0011) with the source fired by
        // hand: a real-timer latency sample cannot be told apart from main-actor starvation under a full-suite run
        // (TASK-447), so latency is asserted as the scheduled bound plus "one tick is enough", not as a wall clock.
        let timers = FakeTimers()
        try await withRig(scheduleTimer: timers.schedule) { rig in
            rig.settings.set(.paused, for: SettingKeys.captureMode)
            rig.settings.set(.active, for: SettingKeys.captureMode)
            #expect(await rig.until { !timers.live.isEmpty }, "resuming Active leaves a poll source running")
            let source = try #require(timers.live.last, "capture polls after the resume")
            #expect(timers.live.count == 1, "sources live after the resume: \(timers.live.count)")
            #expect(source.interval + source.tolerance <= detectionBound,
                    "worst-case wait for the next tick is \(source.interval + source.tolerance) s")

            let n = uid("N")
            let readsBefore = rig.pasteboard.typeQueries
            rig.pasteboard.copyText(n)
            source.fire()
            #expect(rig.pasteboard.typeQueries > readsBefore, "the first tick after the copy read it")
            #expect(await rig.until(seconds: 10) { try await rig.item(withText: n).count == 1 })
            try #expect(await rig.itemCount() == 1)
        }
    }
}

// MARK: Detection latency measurement (OC-1087, OC-1088)

/// FR-001-20 / the oracle: a copy is detected at most 0.6 s after the write (0.5 s interval + 0.1 s tolerance).
private let detectionBound = 0.6

// MARK: Batch 3b: OC-1088, OC-1091..OC-1095, OC-1097, OC-1099..OC-1106, OC-1110 (latency, robustness, error codes)

@MainActor
@Suite("FRD-001 contract part 2: latency, robustness and error-code surfacing")
struct FRD001RobustnessContractTests {

    @Test("OC-1088: 50 copies at staggered times are each detected within 0.6 s and stored exactly once")
    func oc1088() async throws {
        // given the capture's scheduled poll source; the contract's 0.6 s is that source's interval + tolerance (a
        // copy waits at most one interval for the next tick, which may be late by at most the tolerance), so it is
        // asserted once, and then each of the 50 copies must be read by the NEXT tick of that same source (the
        // source stays live and one tick is enough, whatever the copy's offset) and stored exactly once. Fired by
        // hand on the timer seam (ADR-0011): the real-timer latency samples this replaces were discarded as
        // "starved" under a full-suite run and failed the test on the discard count (TASK-447).
        let timers = FakeTimers()
        try await withRig(scheduleTimer: timers.schedule) { rig in
            let source = try #require(timers.live.first, "capture schedules its poll source")
            #expect(source.interval + source.tolerance <= detectionBound,
                    "worst-case wait for the next tick is \(source.interval + source.tolerance) s")
            var texts: [String] = []
            var unread: [Int] = []
            for i in 0..<50 {
                let text = uid("L\(i)")
                texts.append(text)
                let readsBefore = rig.pasteboard.typeQueries
                rig.pasteboard.copyText(text)
                source.fire()
                if rig.pasteboard.typeQueries == readsBefore { unread.append(i) }
                #expect(timers.live.count == 1 && timers.live.first === source, "the poll source stayed running after copy \(i)")
                // Each copy is stored before the next: the dedupe/ingest path of copy i must not see copy i+1.
                #expect(await rig.until(seconds: 10) { try await rig.item(withText: text).count == 1 }, "copy \(i) stored")
            }
            #expect(unread.isEmpty, "every copy was read by the very next tick: unread \(unread)")
            #expect(await rig.until(seconds: 15) { try await rig.itemCount() == 50 })
            for text in texts { try #expect(await rig.item(withText: text).count == 1, "\(text) stored exactly once") }
        }
    }

    @Test("OC-1091 / OC-1099: a failing read creates nothing, logs CAP-OS-001 and shows its Notice; the next copy is stored")
    func oc1091() async throws {
        // Runs on the timer seam (ADR-0011): the one scheduled source is fired by hand, so no real 0.5 s tick (and no
        // sleep) decides the outcome (TASK-447: the real-timer waits lost the race under full-suite load).
        let timers = FakeTimers()
        try await withRig(scheduleTimer: timers.schedule) { rig in
            let source = try #require(timers.live.first, "capture schedules its poll source")
            rig.pasteboard.failingTypes = [PB.text]
            rig.pasteboard.copyText(uid("unreadable"))
            // No rig.process(): that stops and restarts the timer, which would hide a failure path that kills it. The
            // scheduled source must hit the failure and then still be the live, unchanged source.
            source.fire()
            #expect(await rig.until { !noticeMessages(rig, code: .capOs001).isEmpty })
            try #expect(await rig.itemCount() == 0)
            #expect(noticeMessages(rig, code: .capOs001) == ["Flotsam couldn't read the clipboard just now. It will keep trying."])
            #expect(rig.sink.logged(.capOs001).map(\.level) == [.default])

            rig.pasteboard.failingTypes = []
            #expect(timers.live.count == 1 && timers.live.first === source, "the failure path left the timer running")
            let y = uid("Y")
            rig.pasteboard.copyText(y)
            source.fire()
            #expect(await rig.until(seconds: 10) { try await rig.item(withText: y).count == 1 }, "the timer kept running")
            try #expect(await rig.itemCount() == 1)
        }
    }

    @Test("OC-1092 / OC-1110: an unwritable store stores nothing and surfaces CAP-IO-001 (error level); writing works again afterwards")
    func oc1110() async throws {
        // given the database refusing writes (SQLITE_READONLY through query_only, the same failure an unwritable data
        // folder gives the open pool); then no item, the CAP-IO-001 Notice and an error-level log record.
        try await withRig { rig in
            try await rig.database.pool.writeWithoutTransaction { try $0.execute(sql: "PRAGMA query_only = ON") }
            let f = uid("F")
            await rig.copyText(f)
            #expect(await rig.until { !rig.presenter.latestNotices.isEmpty })
            try #expect(await rig.item(withText: f).isEmpty)
            let codes = rig.presenter.latestNotices.map(\.code.rawValue)
            // OC-1092 accepts CAP-IO-001 or any STO-* code.
            #expect(codes.allSatisfy { $0 == "CAP-IO-001" || $0.hasPrefix("STO-") }, "surfaced \(codes)")
            // OC-1110 is stricter: the CAP-IO-001 catalogue message and an error-level record.
            #expect(noticeMessages(rig, code: .capIo001) == ["Flotsam couldn't save a copy. The disk may be full or its data folder unreadable."], "surfaced \(codes)")
            #expect(rig.sink.logged(.capIo001).map(\.level) == [.error])

            try await rig.database.pool.writeWithoutTransaction { try $0.execute(sql: "PRAGMA query_only = OFF") }
            let g = uid("G")
            await rig.copyText(g)
            try #expect(await rig.item(withText: g).count == 1)
            try #expect(await rig.itemCount() == 1)
        }
    }

    @Test("OC-1093 (sink half): no marker from a text, URL, email, phone, colour or file name reaches the log; kind, size and outcome do")
    func oc1093() async throws {
        try await withRig { rig in
            let markers = ["zq7markerTEXT", "zq7markerURL", "zq7markerMAIL", "5550177", "7F3A9C", "zq7markerFILE"]
            rig.pasteboard.copyText("hello zq7markerTEXT")
            await rig.process()
            for text in ["https://example.com/zq7markerURL", "zq7markerMAIL@example.com", "(415) 555-0177", "#7F3A9C"] {
                await rig.copyText(text)
            }
            rig.pasteboard.copy(PB.fileURLReps([try rig.makeFile("zq7markerFILE.txt")]))
            await rig.process()
            try #expect(await rig.itemCount() == 6)
            for marker in markers { #expect(!rig.sink.everything.contains(marker), "\(marker) leaked into the log") }
            let processed = rig.sink.records.filter { $0.headline == "pasteboard.processed" }
            #expect(processed.count == 6)
            #expect(processed.allSatisfy { $0.publicContext.contains("outcome=stored") && $0.publicContext.contains("byteSize=") && $0.publicContext.contains("kind=") })
        }
    }

    @Test("OC-1094: TransientType and AutoGeneratedType with unreadable data are rejected CAP-POL-001, never CAP-OS-001 or CAP-VAL-001")
    func oc1094() async throws {
        try await withRig { rig in
            for marker in [PasteboardMarkers.transient, PasteboardMarkers.autoGenerated] {
                rig.sink.reset()
                rig.pasteboard.failingTypes = [marker, PB.text]
                rig.pasteboard.copy([(PB.text, PB.data("x")), (marker, Data())])
                await rig.process()
                #expect(rig.sink.logged(.capPol001).count == 1, "\(marker)")
                #expect(rig.sink.logged(.capOs001).isEmpty && rig.sink.logged(.capVal001).isEmpty, "\(marker)")
                try #expect(await rig.itemCount() == 0)
            }
            #expect(rig.pasteboard.bytesRequested.isEmpty, "rejected on marker presence, no data read")
            #expect(rig.presenter.latestNotices.isEmpty)
        }
    }

    @Test("OC-1095: two texts within 50 ms: M2 is stored, M1 may be missed, and no error is raised")
    func oc1095() async throws {
        try await withRig { rig in
            let m1 = uid("M1"), m2 = uid("M2")
            rig.pasteboard.copyText(m1)
            rig.pasteboard.copyText(m2)
            await rig.process()
            let stored = try await rig.items()
            #expect(stored.contains { $0.plainText == m2 && $0.copyCount == 1 })
            #expect((1...2).contains(stored.count))
            #expect(rig.presenter.noticeLists.isEmpty && rig.presenter.huds.isEmpty)
            #expect(await rig.reporter.recentErrors().isEmpty)
        }
    }

    @Test("OC-1097: after stored, deduped, concealed, ignored-app, paused and over-limit copies the pasteboard is untouched")
    func oc1097() async throws {
        // given six outcomes; after each the changeCount equals the user's own copy and Flotsam wrote nothing.
        try await withRig { rig in
            @MainActor func check(_ label: String, expectedTypes: [String], _ copy: () -> Void) async {
                copy()
                let mine = rig.pasteboard.changeCount
                await rig.process()
                #expect(rig.pasteboard.changeCount == mine, "\(label): Flotsam changed the pasteboard")
                #expect(rig.pasteboard.writes == 0, "\(label): Flotsam wrote to the pasteboard")
                #expect(rig.pasteboard.currentTypeIdentifiers() == expectedTypes, "\(label): types were altered")
            }
            let text = uid("keep")
            await check("stored", expectedTypes: [PB.text]) { rig.pasteboard.copyText(text) }
            await check("deduped", expectedTypes: [PB.text]) { rig.pasteboard.copyText(text) }
            await check("concealed", expectedTypes: [PB.text, PasteboardMarkers.concealed]) {
                rig.pasteboard.copy([(PB.text, PB.data("s")), (PasteboardMarkers.concealed, Data())])
            }
            rig.ignored = ["com.example.writer"]
            await check("ignored app", expectedTypes: [PB.text]) { rig.pasteboard.copyText(uid("ign")) }
            rig.ignored = []
            rig.settings.set(.paused, for: SettingKeys.captureMode)
            await check("paused", expectedTypes: [PB.text]) { rig.pasteboard.copyText(uid("paused")) }
            rig.settings.set(.active, for: SettingKeys.captureMode)
            await check("over limit", expectedTypes: [PB.text]) { rig.pasteboard.copyText(String(repeating: "c", count: tenMiB + 1)) }
            try #expect(await rig.itemCount() == 1)
        }
    }

    // MARK: Info-only codes (OC-1100..OC-1106)

    @Test("OC-1100: an unresolvable source logs CAP-OS-002 at info, stores the item as Unknown, shows nothing")
    func oc1100() async throws {
        try await withRig(frontmost: nil) { rig in
            await rig.copyText(uid("anon"))
            let stored = try await rig.items()
            #expect(stored.count == 1)
            #expect(stored.map(\.sourceBundleId) == [nil] && stored.map(\.sourceName) == [nil])
            expectInfoOnly(rig, .capOs002)
        }
    }

    @Test("OC-1101: a ConcealedType copy logs CAP-POL-001 at info only")
    func oc1101() async throws {
        try await withRig { rig in
            rig.pasteboard.copy([(PB.text, PB.data("s")), (PasteboardMarkers.concealed, Data())])
            await rig.process()
            try #expect(await rig.itemCount() == 0)
            expectInfoOnly(rig, .capPol001)
        }
    }

    @Test("OC-1102: a copy from an ignored app logs CAP-POL-002 at info only")
    func oc1102() async throws {
        try await withRig { rig in
            rig.ignored = ["com.example.writer"]
            await rig.copyText(uid("ignored"))
            try #expect(await rig.itemCount() == 0)
            expectInfoOnly(rig, .capPol002)
        }
    }

    @Test("OC-1103: a copy while Paused logs CAP-POL-003 at info only")
    func oc1103() async throws {
        try await withRig { rig in
            rig.settings.set(.paused, for: SettingKeys.captureMode)
            await rig.copyText(uid("paused"))
            try #expect(await rig.itemCount() == 0)
            expectInfoOnly(rig, .capPol003)
        }
    }

    @Test("OC-1104: a Flotsam paste-back logs CAP-POL-004 at info only")
    func oc1104() async throws {
        try await withRig { rig in
            _ = rig.ledger.write([PasteboardRepresentation(uti: PB.text, data: PB.data("back"))], to: rig.pasteboard)
            await rig.process()
            try #expect(await rig.itemCount() == 0)
            expectInfoOnly(rig, .capPol004)
        }
    }

    @Test("OC-1104: each own-write guard rejects on its own (marker alone; ledger alone)")
    func oc1104EachGuard() async throws {
        // given a change that carries the own-write marker but is NOT in the ledger, then a change that IS in the ledger
        // but whose types carry no marker (the marker types are swapped out without a new changeCount); then both are
        // rejected with CAP-POL-004 at info. Deleting either guard lets one of them through and into the store.
        try await withRig { rig in
            rig.pasteboard.copy([
                PasteboardRepresentation(uti: PB.text, data: PB.data(uid("marker-only"))),
                PasteboardRepresentation(uti: PasteboardMarkers.ownWrite, data: Data()),
            ])
            await rig.process()
            try #expect(await rig.itemCount() == 0, "marker alone must reject")
            expectInfoOnly(rig, .capPol004)
        }
        try await withRig { rig in
            _ = rig.ledger.write([PasteboardRepresentation(uti: PB.text, data: PB.data(uid("ledger-only")))], to: rig.pasteboard)
            rig.pasteboard.reveal([PasteboardRepresentation(uti: PB.text, data: PB.data(uid("ledger-only-visible")))])
            await rig.process()
            try #expect(await rig.itemCount() == 0, "a ledger-recorded change must reject even with no marker type")
            expectInfoOnly(rig, .capPol004)
        }
    }

    @Test("OC-1105: a whitespace-only text copy logs CAP-VAL-001 at info only")
    func oc1105() async throws {
        try await withRig { rig in
            await rig.copyText("   \n")
            try #expect(await rig.itemCount() == 0)
            expectInfoOnly(rig, .capVal001)
        }
    }

    @Test("OC-1106: a file URL to a missing file logs CAP-DAT-001 at info only")
    func oc1106() async throws {
        try await withRig { rig in
            rig.pasteboard.copy(PB.fileURLReps([rig.files.appendingPathComponent("missing.txt")]))
            await rig.process()
            try #expect(await rig.itemCount() == 0)
            expectInfoOnly(rig, .capDat001)
        }
    }
}

// MARK: Unreachable from this package (no seam in FlotsamCore; recorded in the session log, not faked here)
//
// OC-1079, OC-1089, OC-1090  performance, memory and signposts on a running app (p95, resident size, capture.persist).
// OC-1084                    no seam: nothing raises CAP-PRM-001 at launch when the system access behaviour is not Allow
//                            (PasteboardAccess feeds onboarding only). Reported as a defect from the code, not a test.
// OC-1085 / OC-1086 (save)   the Save Clipboard action (AppContainer.saveClipboard) is a UI entry point; only the Curated
//                            half of OC-1085 is covered above.
// OC-1096                    needs a network monitor on a live process.
// OC-1093 (log show)         only the sink half and the diagnostics ring are reachable; `log show` is an app-process check.
// OC-1059/1064/1069/1070 and OC-1100..OC-1107 UI halves (rows, preview, menu-bar icon rendering, HUD drawing): the
//                            presenter-level "no Notice, no HUD, no dot" half is asserted; pixels are Data's 8V.
