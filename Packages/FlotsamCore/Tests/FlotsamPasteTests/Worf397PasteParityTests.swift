import FlotsamBase
import FlotsamStorage
import Foundation
import Testing
@testable import FlotsamPaste

// TASK-397 blind verification (Worf). FR-003-15 step 1 / LIB-DAT-001 must fire on the same condition the Library's
// Missing badge uses (FR-003-07). Both read the one FileMemberLocator; these literals are the same case table the
// storage-side tests (Worf397MissingTests, MissingFileRowTests) assert for the badge.

@Suite struct Worf397PasteParityTests {
    private let id = UUID(uuidString: "00000000-0000-0000-0000-000000000397")!

    private func content(_ kind: ItemKind, _ paths: [String], dirs: Bool = false) -> ItemContent {
        ItemContent(
            kind: kind, plainText: nil, representations: [],
            members: paths.map { ItemMember(path: $0, bookmark: nil, isDirectory: dirs) })
    }

    private func outcome(_ content: ItemContent, existing: Set<String>) -> (code: ErrorCode?, urls: [String]) {
        switch PastePayload.representations(for: content, mode: .paste, itemId: id, files: FakeFiles(existing: existing)) {
        case .success(let reps): return (nil, reps.map { String(decoding: $0.data, as: UTF8.self) })
        case .failure(let error): return (error.code, [])
        }
    }

    // Red if paste regains its own existence rule (e.g. "all members must exist") or loses the .referencesFiles gate.
    @Test("OC-397-PP1 LIB-DAT-001 fires exactly when no member exists (same condition as the Missing badge)")
    func libDat001Condition() {
        // file: gone -> fails; present -> pastes
        #expect(outcome(content(.file, ["/a/f"]), existing: []).code == .libDat001)
        #expect(outcome(content(.file, ["/a/f"]), existing: ["/a/f"]).urls == ["file:///a/f"])
        // folder
        #expect(outcome(content(.folder, ["/a/d"], dirs: true), existing: []).code == .libDat001)
        #expect(outcome(content(.folder, ["/a/d"], dirs: true), existing: ["/a/d"]).code == nil)
        // bundle: partial is NOT a failure, all gone is
        #expect(outcome(content(.bundle, ["/a/1", "/a/2"]), existing: ["/a/2"]).urls == ["file:///a/2"])
        #expect(outcome(content(.bundle, ["/a/1", "/a/2"]), existing: []).code == .libDat001)
    }

    // Red if the file-existence check is applied to non-file kinds (a text/image item has no members and must paste).
    @Test("OC-397-PP2 text, image and screenshot items never fail with LIB-DAT-001")
    func nonFileKinds() {
        for kind in [ItemKind.text, .richText, .link, .color, .phone, .email, .image, .screenshot] {
            let result = outcome(content(kind, []), existing: [])
            #expect(result.code == nil, "\(kind) must not report LIB-DAT-001")
        }
    }

    // CHARACTERISATION (FRD silent): paste treats a zero-member bundle as "none left" and fails LIB-DAT-001, so the
    // Library, to agree with paste, would have to show it Missing. LibraryQueries.markingMissing shows it Missing only
    // when another file row with members is on the same page (see Worf397MissingTests OC-397-E1).
    @Test("OC-397-PP3 characterisation: a bundle with zero members fails LIB-DAT-001 in paste")
    func emptyBundleInPaste() {
        #expect(outcome(content(.bundle, []), existing: []).code == .libDat001)
    }

    // Red if a member whose file exists is dropped when an earlier one is gone (order/first-member regression).
    @Test("OC-397-PP4 count and order of pasted files follow the members that exist")
    func orderPreserved() {
        let result = outcome(content(.bundle, ["/a/1", "/a/2", "/a/3"]), existing: ["/a/1", "/a/3"])
        #expect(result.urls == ["file:///a/1", "file:///a/3"])
    }
}
