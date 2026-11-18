import FlotsamBase
import Foundation
import Testing
@testable import FlotsamStorage

// TASK-397, FRD-003 FR-003-07: a file, folder or bundle row is marked missing when none of its files exist, read from
// the disk at query time through the one `FileMemberLocator`.

@Suite struct MissingFileRowTests {
    private let rig: Rig
    private let dir: URL

    init() async throws {
        rig = try await Rig.make()
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("flotsam-missing-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    private func candidate(_ key: String, kind: ItemKind, paths: [URL], directory: Bool = false) -> IngestCandidate {
        IngestCandidate(
            kind: kind, contentKey: key,
            members: paths.map { IngestMember(path: $0.path, bookmark: nil, isDirectory: directory) },
            origin: .pasteboard, occurredAt: Date(timeIntervalSince1970: Double(rig.store.clock.millis) / 1000))
    }

    private func missing(_ id: UUID) async throws -> Bool {
        let page = try await rig.store.database.items(matching: LibraryQuery()).get()
        return try #require(page.rows.first { $0.id == id }).isMissing
    }

    private func touch(_ name: String) throws -> URL {
        let url = dir.appendingPathComponent(name)
        try Data("x".utf8).write(to: url)
        return url
    }

    @Test("a file item whose file was deleted is missing; one whose file exists is not")
    func fileItem() async throws {
        defer { rig.cleanUp(); try? FileManager.default.removeItem(at: dir) }
        let gone = try touch("gone.txt")
        let kept = try touch("kept.txt")
        let goneId = try await rig.create(candidate("k-gone", kind: .file, paths: [gone]))
        let keptId = try await rig.create(candidate("k-kept", kind: .file, paths: [kept]))
        #expect(try await missing(goneId) == false)

        try FileManager.default.removeItem(at: gone)

        #expect(try await missing(goneId))
        #expect(try await missing(keptId) == false)
    }

    @Test("a folder item whose folder was deleted is missing")
    func folderItem() async throws {
        defer { rig.cleanUp(); try? FileManager.default.removeItem(at: dir) }
        let folder = dir.appendingPathComponent("Folder")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let id = try await rig.create(candidate("k-folder", kind: .folder, paths: [folder], directory: true))
        #expect(try await missing(id) == false)

        try FileManager.default.removeItem(at: folder)

        #expect(try await missing(id))
    }

    @Test("a bundle is missing only when every member is gone, matching paste")
    func bundleItem() async throws {
        defer { rig.cleanUp(); try? FileManager.default.removeItem(at: dir) }
        let first = try touch("a.txt")
        let second = try touch("b.txt")
        let id = try await rig.create(candidate("k-bundle", kind: .bundle, paths: [first, second]))

        try FileManager.default.removeItem(at: first)
        #expect(try await missing(id) == false)

        try FileManager.default.removeItem(at: second)
        #expect(try await missing(id))
    }

    @Test("a restored file clears the missing state on the next read; text items are never missing")
    func restoredAndNonFile() async throws {
        defer { rig.cleanUp(); try? FileManager.default.removeItem(at: dir) }
        let file = try touch("back.txt")
        let id = try await rig.create(candidate("k-back", kind: .file, paths: [file]))
        let textId = try await rig.create(rig.text("k-text", "hello"))
        try FileManager.default.removeItem(at: file)
        #expect(try await missing(id))

        try Data("x".utf8).write(to: file)

        #expect(try await missing(id) == false)
        #expect(try await missing(textId) == false)
    }
}
