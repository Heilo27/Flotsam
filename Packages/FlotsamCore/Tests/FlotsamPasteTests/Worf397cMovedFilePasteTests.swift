import FlotsamBase
import FlotsamStorage
import Foundation
import Testing
@testable import FlotsamPaste

// TASK-397 re-verify (Worf, worf-397c), finding F1: paste now reaches the bookmark rule only through
// FileMemberLocator (via ItemContent.existingMemberURLs). Real files, real bookmark, real LocalFileSystem.

@Suite struct Worf397cMovedFilePasteTests {
    private let dir: URL
    private let id = UUID(uuidString: "00000000-0000-0000-0000-000000000397")!

    init() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("worf397c-paste-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    private func paste(_ content: ItemContent) -> (code: ErrorCode?, urls: [String]) {
        switch PastePayload.representations(for: content, mode: .paste, itemId: id, files: LocalFileSystem()) {
        case .success(let reps): return (nil, reps.map { String(decoding: $0.data, as: UTF8.self) })
        case .failure(let error): return (error.code, [])
        }
    }

    // Red if paste stops following the bookmark (stored path alone is gone after the move -> LIB-DAT-001), or if it
    // pastes the stale stored path instead of the file's new location.
    @Test("OC-397c-P1 a moved file with a bookmark pastes its new location; the same move without a bookmark fails LIB-DAT-001")
    func movedFile() throws {
        defer { try? FileManager.default.removeItem(at: dir) }
        let oldA = dir.appendingPathComponent("a.txt")
        let oldB = dir.appendingPathComponent("b.txt")
        try Data("x".utf8).write(to: oldA)
        try Data("x".utf8).write(to: oldB)
        let bookmarkA = try oldA.bookmarkData()
        let bookmarkB = try oldB.bookmarkData()
        let newA = dir.appendingPathComponent("a-moved.txt")
        let newB = dir.appendingPathComponent("b-moved.txt")
        try FileManager.default.moveItem(at: oldA, to: newA)
        try FileManager.default.moveItem(at: oldB, to: newB)
        let resolvedA = try #require(
            paste(ItemContent(kind: .file, plainText: nil, representations: [], members: [
                ItemMember(path: oldA.path, bookmark: bookmarkA, isDirectory: false)])).urls.first)

        let withBookmark = paste(ItemContent(kind: .file, plainText: nil, representations: [], members: [
            ItemMember(path: oldB.path, bookmark: bookmarkB, isDirectory: false)]))
        let withoutBookmark = paste(ItemContent(kind: .file, plainText: nil, representations: [], members: [
            ItemMember(path: oldB.path, bookmark: nil, isDirectory: false)]))

        #expect(withBookmark.code == nil)
        #expect(withBookmark.urls.count == 1)
        #expect(withBookmark.urls.first?.hasSuffix("/b-moved.txt") == true)
        #expect(resolvedA.hasSuffix("/a-moved.txt"))
        #expect(withoutBookmark.code == .libDat001)
        #expect(withoutBookmark.urls.isEmpty)
    }

    // Red if a bundle drops members the bookmark can still find, or keeps the one whose file is truly gone.
    @Test("OC-397c-P2 a bundle of a moved file, a deleted file and a live file pastes the moved and the live one, in order")
    func bundleMixed() throws {
        defer { try? FileManager.default.removeItem(at: dir) }
        let moved = dir.appendingPathComponent("m.txt")
        let gone = dir.appendingPathComponent("g.txt")
        let live = dir.appendingPathComponent("l.txt")
        for url in [moved, gone, live] { try Data("x".utf8).write(to: url) }
        let movedBookmark = try moved.bookmarkData()
        let goneBookmark = try gone.bookmarkData()
        try FileManager.default.moveItem(at: moved, to: dir.appendingPathComponent("m2.txt"))
        try FileManager.default.removeItem(at: gone)

        let result = paste(ItemContent(kind: .bundle, plainText: nil, representations: [], members: [
            ItemMember(path: moved.path, bookmark: movedBookmark, isDirectory: false),
            ItemMember(path: gone.path, bookmark: goneBookmark, isDirectory: false),
            ItemMember(path: live.path, bookmark: nil, isDirectory: false)]))

        #expect(result.code == nil)
        #expect(result.urls.count == 2)
        #expect(result.urls.first?.hasSuffix("/m2.txt") == true)
        #expect(result.urls.last == live.absoluteString)
    }
}
