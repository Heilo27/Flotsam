import FlotsamBase
import FlotsamStorage
import Foundation
import Testing
@testable import FlotsamShelf

// TASK-397 re-verify (Worf, worf-397c), finding F1: the Shelf drag-out reaches the bookmark rule only through
// FileMemberLocator (via ItemContent.existingMemberURLs). Real files, real bookmark, real LocalFileSystem.

@Suite struct Worf397cMovedFileDragTests {
    private let dir: URL

    init() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("worf397c-drag-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    private func dragged(_ members: [ItemMember]) -> [String] {
        let candidate = ShelfDragCandidate(
            itemId: shelfID(1),
            content: ItemContent(kind: .bundle, plainText: nil, representations: [], members: members))
        guard case .success(let plan) = ShelfDragPlanner.plan([candidate], files: LocalFileSystem()) else { return [] }
        return plan.items.flatMap { item -> [String] in
            guard case .representations(let reps) = item.payload else { return [] }
            return reps.filter { $0.uti == "public.file-url" }.map { String(decoding: $0.data, as: UTF8.self) }
        }
    }

    // Red if drag-out stops following the bookmark (the moved file would be dropped) or still offers the deleted one.
    @Test("OC-397c-D1 a moved bookmarked file drags from its new location; a deleted bookmarked file is left out")
    func movedAndDeleted() throws {
        defer { try? FileManager.default.removeItem(at: dir) }
        let moved = dir.appendingPathComponent("m.txt")
        let gone = dir.appendingPathComponent("g.txt")
        for url in [moved, gone] { try Data("x".utf8).write(to: url) }
        let movedBookmark = try moved.bookmarkData()
        let goneBookmark = try gone.bookmarkData()
        try FileManager.default.moveItem(at: moved, to: dir.appendingPathComponent("m2.txt"))
        try FileManager.default.removeItem(at: gone)

        let urls = dragged([
            ItemMember(path: moved.path, bookmark: movedBookmark, isDirectory: false),
            ItemMember(path: gone.path, bookmark: goneBookmark, isDirectory: false)])

        #expect(urls.count == 1)
        #expect(urls.first?.hasSuffix("/m2.txt") == true)
    }
}
