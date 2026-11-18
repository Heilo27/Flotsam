import FlotsamBase
import Foundation
import Testing
@testable import FlotsamStorage

// TASK-397 follow-up blind verification (Worf), branch worf-397b. FRD-003 FR-003-07 / AC-003-05a. S1 rulings:
// (a) an empty bundle reads as Missing and the state never depends on the other rows of the page;
// (b) a dangling symlink reads as Missing and the badge result equals paste's.
// Expected values are literals. Real files, real symlinks, real database.

@Suite struct Worf397bMissingTests {
    private let dir: URL

    init() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("worf397b-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    private func touch(_ name: String) throws -> URL {
        let url = dir.appendingPathComponent(name)
        try Data("x".utf8).write(to: url)
        return url
    }

    private func page(_ rig: Rig, _ pageIndex: Int = 0) async throws -> ItemPage {
        var query = LibraryQuery()
        query.page = pageIndex
        return try await rig.store.database.items(matching: query).get()
    }

    private func state(_ page: ItemPage, _ n: Int) throws -> Bool {
        try #require(page.rows.first { $0.id == Store.id(n) }, "row \(n) not on the page").isMissing
    }

    // MARK: (a) empty bundle, three page compositions

    // Red if an empty bundle is only marked when some other file row shares the page (e.g. the member lookup is skipped
    // when no row has members), or if the empty-bundle default is "not missing".
    @Test("OC-397b-E1 a page holding only an empty bundle marks it Missing")
    func onlyEmptyBundle() async throws {
        let rig = try await Rig.make(); defer { rig.cleanUp(); try? FileManager.default.removeItem(at: dir) }
        try await rig.store.insert([Spec(n: 1, kind: .bundle)])

        let result = try await page(rig)

        #expect(result.rows.count == 1)
        #expect(result.totalCount == 1)
        #expect(try state(result, 1) == true)
    }

    // Red if a neighbour's members leak onto the empty bundle (a shared accumulator, "any live member on the page"),
    // or if an empty bundle changes the verdict of its neighbours. Identity, not position: rows are looked up by id.
    @Test("OC-397b-E2 empty bundle beside good, missing and live-bundle rows: every row keeps its own verdict")
    func emptyBundleMixedWithFileRows() async throws {
        let rig = try await Rig.make(); defer { rig.cleanUp(); try? FileManager.default.removeItem(at: dir) }
        let live = try touch("live.txt")
        let liveFolder = dir.appendingPathComponent("folder"); try FileManager.default.createDirectory(at: liveFolder, withIntermediateDirectories: false)
        let gone = dir.appendingPathComponent("gone.txt")
        try await rig.store.insert([
            Spec(n: 1, kind: .file, ageMs: 1000, members: [(path: live.path, isDirectory: false)]),
            Spec(n: 2, kind: .file, ageMs: 2000, members: [(path: gone.path, isDirectory: false)]),
            Spec(n: 3, kind: .bundle, ageMs: 3000),  // the empty bundle, in the middle of the page
            Spec(n: 4, kind: .bundle, ageMs: 4000, members: [(path: live.path, isDirectory: false), (path: gone.path, isDirectory: false)]),
            Spec(n: 5, kind: .folder, ageMs: 5000, members: [(path: liveFolder.path, isDirectory: true)]),
            Spec(n: 6, kind: .bundle, ageMs: 6000),  // a second empty bundle at the end
        ])

        let result = try await page(rig)

        #expect(result.rows.count == 6)
        #expect(try state(result, 1) == false)
        #expect(try state(result, 2) == true)
        #expect(try state(result, 3) == true)
        #expect(try state(result, 4) == false)
        #expect(try state(result, 5) == false)
        #expect(try state(result, 6) == true)
        #expect(result.rows.filter(\.isMissing).count == 3)
    }

    // Red if non-file rows are touched by the empty-bundle rule (e.g. "no members means missing" without the kind gate).
    @Test("OC-397b-E3 empty bundle beside text, link and colour rows: only the bundle is Missing")
    func emptyBundleBesideTextRows() async throws {
        let rig = try await Rig.make(); defer { rig.cleanUp(); try? FileManager.default.removeItem(at: dir) }
        try await rig.store.insert([
            Spec(n: 1, kind: .text, ageMs: 1000),
            Spec(n: 2, kind: .bundle, ageMs: 2000),
            Spec(n: 3, kind: .link, ageMs: 3000, text: "https://example.com"),
            Spec(n: 4, kind: .color, ageMs: 4000, text: "#ff0000"),
        ])

        let result = try await page(rig)

        #expect(result.rows.count == 4)
        #expect(try state(result, 1) == false)
        #expect(try state(result, 2) == true)
        #expect(try state(result, 3) == false)
        #expect(try state(result, 4) == false)
    }

    // Red if the verdict depends on page position: the empty bundle is the only row on the SECOND page, behind a full
    // first page of text rows.
    @Test("OC-397b-E4 an empty bundle alone on page 2 behind 200 text rows is Missing; page 1 has none Missing")
    func emptyBundleOnSecondPage() async throws {
        let rig = try await Rig.make(); defer { rig.cleanUp(); try? FileManager.default.removeItem(at: dir) }
        var specs = (1...200).map { Spec(n: $0, kind: .text, ageMs: Int64($0)) }
        specs.append(Spec(n: 201, kind: .bundle, ageMs: 10_000))  // oldest: lands on page index 1
        try await rig.store.insert(specs)

        let first = try await page(rig, 0)
        let second = try await page(rig, 1)

        #expect(first.rows.count == 200)
        #expect(first.rows.contains { $0.isMissing } == false)
        #expect(second.rows.count == 1)
        #expect(second.totalCount == 201)
        #expect(try state(second, 201) == true)
    }

    // MARK: (b) dangling symlink: badge equals paste

    private struct Scenario {
        let name: String
        let spec: (Int, URL) throws -> Spec
        let missing: Bool
    }

    // The badge (ItemRow.isMissing from the query layer) and paste's own existence test (the members that
    // `existingMemberURLs` returns, which is what PastePayload fails LIB-DAT-001 on when empty) must agree on every
    // case, on the real file system. Red if either side regains its own rule (they are two code paths today).
    @Test("OC-397b-S1 badge and paste agree on live, deleted, symlinked, dangling-symlinked and empty items")
    func badgeMatchesPaste() async throws {
        let rig = try await Rig.make(); defer { rig.cleanUp(); try? FileManager.default.removeItem(at: dir) }
        let fm = FileManager.default
        let live = try touch("live.txt")
        let target = try touch("target.txt")
        let liveLink = dir.appendingPathComponent("live-link.txt")
        try fm.createSymbolicLink(at: liveLink, withDestinationURL: live)
        let dangling = dir.appendingPathComponent("dangling.txt")
        try fm.createSymbolicLink(at: dangling, withDestinationURL: target)
        let targetDir = dir.appendingPathComponent("targetDir")
        try fm.createDirectory(at: targetDir, withIntermediateDirectories: false)
        let danglingDir = dir.appendingPathComponent("dangling-dir")
        try fm.createSymbolicLink(at: danglingDir, withDestinationURL: targetDir)
        let deleted = dir.appendingPathComponent("deleted.txt")
        try fm.removeItem(at: target)
        try fm.removeItem(at: targetDir)
        #expect(!fm.fileExists(atPath: dangling.path))
        #expect((try? fm.destinationOfSymbolicLink(atPath: dangling.path)) != nil)

        // (spec, expected missing). Literals only.
        let cases: [(name: String, spec: Spec, missing: Bool)] = [
            ("live file", Spec(n: 1, kind: .file, members: [(live.path, false)]), false),
            ("deleted file", Spec(n: 2, kind: .file, members: [(deleted.path, false)]), true),
            ("symlink to live file", Spec(n: 3, kind: .file, members: [(liveLink.path, false)]), false),
            ("dangling symlink", Spec(n: 4, kind: .file, members: [(dangling.path, false)]), true),
            ("dangling symlink to a folder", Spec(n: 5, kind: .folder, members: [(danglingDir.path, true)]), true),
            ("bundle of dangling + live", Spec(n: 6, kind: .bundle, members: [(dangling.path, false), (live.path, false)]), false),
            ("bundle of dangling only", Spec(n: 7, kind: .bundle, members: [(dangling.path, false)]), true),
            ("empty bundle", Spec(n: 8, kind: .bundle), true),
            ("file item with no members", Spec(n: 9, kind: .file), true),
        ]
        try await rig.store.insert(cases.map(\.spec))
        let rows = try await page(rig)
        #expect(rows.rows.count == 9)

        for (n, scenario) in cases.enumerated().map({ ($0.offset + 1, $0.element) }) {
            let badge = try state(rows, n)
            let content = try await rig.store.database.content(of: Store.id(n)).get()
            let pasteWouldFail = content.existingMemberURLs(files: LocalFileSystem()).isEmpty
            #expect(badge == scenario.missing, "badge for '\(scenario.name)'")
            #expect(pasteWouldFail == scenario.missing, "paste for '\(scenario.name)'")
        }
    }
}
