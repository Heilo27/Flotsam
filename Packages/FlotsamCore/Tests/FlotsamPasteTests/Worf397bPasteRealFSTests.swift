import FlotsamBase
import FlotsamStorage
import Foundation
import Testing
@testable import FlotsamPaste

// TASK-397 follow-up (Worf, worf-397b): merge-conflict resolution (e). PastePayload took main's ItemContent helpers;
// paste of a missing or empty file item must still fail LIB-DAT-001, on the real file system and with real symlinks.

@Suite struct Worf397bPasteRealFSTests {
    private let dir: URL
    private let id = UUID(uuidString: "00000000-0000-0000-0000-000000000398")!

    init() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("worf397b-paste-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    private func touch(_ name: String) throws -> URL {
        let url = dir.appendingPathComponent(name)
        try Data("x".utf8).write(to: url)
        return url
    }

    private func content(_ kind: ItemKind, _ urls: [URL], directories: Bool = false) -> ItemContent {
        ItemContent(
            kind: kind, plainText: nil, representations: [],
            members: urls.map { ItemMember(path: $0.path, bookmark: nil, isDirectory: directories) })
    }

    private func outcome(_ content: ItemContent) -> (code: ErrorCode?, urls: [String]) {
        switch PastePayload.representations(for: content, mode: .paste, itemId: id, files: LocalFileSystem()) {
        case .success(let reps): return (nil, reps.map { String(decoding: $0.data, as: UTF8.self) })
        case .failure(let error): return (error.code, [])
        }
    }

    // Red if paste stops failing a file item whose only member is gone, or fails one that has a member left.
    @Test("OC-397b-P1 file item: deleted file fails LIB-DAT-001; existing file pastes its one URL")
    func fileItem() throws {
        defer { try? FileManager.default.removeItem(at: dir) }
        let live = try touch("live.txt")
        let gone = dir.appendingPathComponent("gone.txt")

        let missing = outcome(content(.file, [gone]))
        let present = outcome(content(.file, [live]))

        #expect(missing.code == .libDat001)
        #expect(missing.urls.isEmpty)
        #expect(present.code == nil)
        #expect(present.urls == [live.absoluteString])
    }

    // Red if paste treats a link as present without following it (lstat semantics), the S1 ruling (b).
    @Test("OC-397b-P2 a dangling symlink fails LIB-DAT-001; a symlink to a live file pastes")
    func symlinks() throws {
        defer { try? FileManager.default.removeItem(at: dir) }
        let fm = FileManager.default
        let target = try touch("target.txt")
        let live = try touch("live.txt")
        let dangling = dir.appendingPathComponent("dangling.txt")
        let good = dir.appendingPathComponent("good.txt")
        try fm.createSymbolicLink(at: dangling, withDestinationURL: target)
        try fm.createSymbolicLink(at: good, withDestinationURL: live)
        try fm.removeItem(at: target)

        let broken = outcome(content(.file, [dangling]))
        let working = outcome(content(.file, [good]))

        #expect(broken.code == .libDat001)
        #expect(working.code == nil)
        #expect(working.urls == [good.absoluteString])
    }

    // Red if the empty case regresses to success with zero representations (a silent no-op paste), or is gated per kind.
    @Test("OC-397b-P3 an empty bundle, a memberless file item and a memberless folder item all fail LIB-DAT-001")
    func emptyFileKinds() {
        let results = [ItemKind.bundle, .file, .folder].map { outcome(content($0, [])) }

        #expect(results.map(\.code) == [.libDat001, .libDat001, .libDat001])
        #expect(results.flatMap(\.urls).isEmpty)
    }

    // Red if the bundle rule becomes "all members must exist" or the order of surviving members changes.
    @Test("OC-397b-P4 bundle of gone, live, dangling, live pastes exactly the two live files in member order")
    func bundleSurvivors() throws {
        defer { try? FileManager.default.removeItem(at: dir) }
        let fm = FileManager.default
        let a = try touch("a.txt")
        let b = try touch("b.txt")
        let dangling = dir.appendingPathComponent("dangling.txt")
        let victim = try touch("victim.txt")
        try fm.createSymbolicLink(at: dangling, withDestinationURL: victim)
        try fm.removeItem(at: victim)
        let gone = dir.appendingPathComponent("gone.txt")

        let result = outcome(content(.bundle, [gone, b, dangling, a]))

        #expect(result.code == nil)
        #expect(result.urls == [b.absoluteString, a.absoluteString])
    }

    // Red if the file-existence gate is applied by anything other than `referencesFiles`: a text item with a stray
    // member that does not exist still pastes its text (it has no file content to lose).
    @Test("OC-397b-P5 non-file kinds never fail LIB-DAT-001, even carrying a nonexistent member path")
    func nonFileKindsIgnoreMembers() {
        let gone = dir.appendingPathComponent("nope.txt")
        let kinds = ItemKind.allCases.filter { !($0 == .file || $0 == .folder || $0 == .bundle) }
        #expect(kinds.count == 8)

        for kind in kinds {
            let item = ItemContent(
                kind: kind, plainText: "hello", representations: [PasteboardRepresentation(uti: "public.png", data: Data([1]))],
                members: [ItemMember(path: gone.path, bookmark: nil, isDirectory: false)])
            #expect(outcome(item).code == nil, "kind \(kind.rawValue)")
        }
    }
}
