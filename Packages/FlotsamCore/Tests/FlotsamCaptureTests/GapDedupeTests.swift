import Foundation
import Testing
import FlotsamBase
import FlotsamPayload
@testable import FlotsamStorage
@testable import FlotsamCapture

/// TASK-144 (FR-001-15, AC-001-13): the dedupe key is the exact bytes. Case, Unicode normalisation form and trailing
/// whitespace each make a different item; only identical bytes bump.
@MainActor
@Suite(.serialized, .timeLimit(.minutes(2)))
struct GapDedupeTests {
    /// OC-144-01. given the exact text "abc" and "ABC", then their keys are the literal SHA-256 of their UTF-8 bytes,
    /// different from each other. Turns red if `ContentKey.text` lowercases, trims or normalises before hashing (the
    /// "ABC" key would become the "abc" key) or changes its prefix or hash function.
    @Test("OC-144-01 the content key of abc and ABC are the literal SHA-256 keys and differ")
    func contentKeyIsExactBytes() {
        // given / when
        let lower = ContentKey.text(Data("abc".utf8))
        let upper = ContentKey.text(Data("ABC".utf8))
        // then
        #expect(lower == "text:ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        #expect(upper == "text:b5d4045c3f466fa91fe2cc6abe79232a1a57cdf104f7a26e716e0a1e2789df78")
    }

    /// OC-144-02 OC-144-03. given six copies that a normalising or trimming dedupe would fold together (abc, ABC, the
    /// same plus a trailing space, the same plus a newline, a precomposed e-acute (NFC) and e plus a combining acute
    /// (NFD)), when each is copied once, then six items exist with six distinct keys, each copied once; and copying
    /// "ABC" again bumps that item (count 2) without a seventh item. Turns red if capture or ingest folds case,
    /// trims whitespace or normalises Unicode before keying, or if the exact repeat stops bumping.
    @Test("OC-144-02 OC-144-03 case, whitespace and Unicode form each make a distinct item; an exact repeat bumps")
    func distinctItemsAndExactRepeatBumps() async throws {
        let rig = try await GapRig()
        defer { Task { await rig.cleanUp() } }
        rig.capture.start()
        let nfc = "caf\u{00E9}"
        let nfd = "cafe\u{0301}"
        // control: Swift's own == treats NFC and NFD as equal, so every comparison below is on UTF-8 bytes
        #expect(nfc.unicodeScalars.count == 4 && nfd.unicodeScalars.count == 5)

        // given / when: each copy is waited on before the next, so ordering is deterministic
        let copies = ["abc", "ABC", "abc ", "abc\n", nfc, nfd]
        for (index, text) in copies.enumerated() {
            rig.text(text)
            rig.capture.captureNow()
            let stored = await eventually { await rig.itemCount() == index + 1 }
            #expect(stored, "copy \(index) (\(text.unicodeScalars.map(\.value))) was folded into an earlier item")
        }
        rig.text("ABC")
        await rig.settle()

        // then: read through a fresh database instance
        let rows = try await rig.freshRows()
        #expect(rows.count == 6, "a seventh item would mean the exact repeat did not bump")
        #expect(Set(rows.map(\.contentKey)).count == 6)
        #expect(rows.map { Array($0.plainText.utf8) } == copies.map { Array($0.utf8) })
        #expect(rows.map(\.copyCount) == [1, 2, 1, 1, 1, 1], "only the exact repeat of ABC is bumped")
    }

    /// OC-144-04. given "ABC" copied, then "ABC" copied again after "abc", then settled, then the repeat is the only
    /// bump: "ABC" has copyCount 2 and "abc" stays 1. Turns red if the bump lands on the wrong (case-folded) item.
    @Test("OC-144-04 an exact repeat of ABC bumps ABC and never abc")
    func repeatBumpsTheMatchingCaseOnly() async throws {
        let rig = try await GapRig()
        defer { Task { await rig.cleanUp() } }
        rig.capture.start()
        for (index, text) in ["ABC", "abc"].enumerated() {
            rig.text(text)
            rig.capture.captureNow()
            #expect(await eventually { await rig.itemCount() == index + 1 })
        }
        rig.text("ABC")
        rig.capture.captureNow()
        #expect(await eventually { rig.itemsChangedCount.value == 3 })
        await rig.settle()

        let rows = try await rig.freshRows()
        #expect(rows.map(\.plainText) == ["ABC", "abc"])
        #expect(rows.map(\.copyCount) == [2, 1])
    }
}
