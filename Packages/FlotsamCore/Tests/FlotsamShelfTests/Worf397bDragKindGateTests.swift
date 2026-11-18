import FlotsamBase
import FlotsamStorage
import Foundation
import Testing
@testable import FlotsamShelf

// TASK-397 follow-up (Worf, worf-397b), ruling (d): ShelfDragPlanner moved from `isFileBacked` to `referencesFiles`;
// the behaviour for file, folder and bundle is unchanged and no other kind gains file URLs.

private struct ExistingFiles: FileSystemPort {
    var existing: Set<String>
    func fileExists(at url: URL) -> Bool { existing.contains(url.path) }
    private func unused() -> FlotsamResult<Void> { .failure(FlotsamError(.sysInt001, "unused")) }
    func createDirectory(at url: URL, permissions: Int) -> FlotsamResult<Void> { unused() }
    func copyItem(at source: URL, to destination: URL) -> FlotsamResult<Void> { unused() }
    func moveItem(at source: URL, to destination: URL) -> FlotsamResult<Void> { unused() }
    func removeItem(at url: URL) -> FlotsamResult<Void> { unused() }
    func contentsOfDirectory(at url: URL) -> FlotsamResult<[URL]> { .failure(FlotsamError(.sysInt001, "unused")) }
    func extendedAttribute(named name: String, at url: URL) -> Data? { nil }
    func writeFile(_ data: Data, to url: URL, permissions: Int) -> FlotsamResult<Void> { unused() }
    func readFile(at url: URL) -> FlotsamResult<Data> { .failure(FlotsamError(.sysInt001, "unused")) }
    func readFileNoFollow(at url: URL) -> FlotsamResult<Data> { .failure(FlotsamError(.sysInt001, "unused")) }
    func fileInfo(at url: URL) -> FileInfo? { nil }
    func availableCapacity(at url: URL) -> Int64? { nil }
}

@Suite struct Worf397bDragKindGateTests {
    private let fileURL = "public.file-url"

    private func urls(of result: FlotsamResult<ShelfDragPlan>) -> [String] {
        guard case .success(let plan) = result else { return [] }
        return plan.items.flatMap { item -> [String] in
            guard case .representations(let reps) = item.payload else { return [] }
            return reps.filter { $0.uti == fileURL }.map { String(decoding: $0.data, as: UTF8.self) }
        }
    }

    // Red if the gate is widened (text/image kinds start emitting file URLs from stray members) or narrowed (one of
    // file/folder/bundle stops dragging its existing members, one item per member, gone members left out).
    @Test("OC-397b-D1 exactly file, folder and bundle drag their existing members, one item per member in order")
    func gateByKind() throws {
        let present = ["/tmp/worf397b-a", "/tmp/worf397b-b"]
        let absent = "/tmp/worf397b-gone"
        let members = [present[0], absent, present[1]].map { ItemMember(path: $0, bookmark: nil, isDirectory: false) }
        var dragged: [String: [String]] = [:]

        for (n, kind) in ItemKind.allCases.enumerated() {
            let candidate = ShelfDragCandidate(
                itemId: shelfID(n + 1),
                content: ItemContent(kind: kind, plainText: "t", representations: [], members: members))
            dragged[kind.rawValue] = urls(of: ShelfDragPlanner.plan([candidate], files: ExistingFiles(existing: Set(present))))
        }

        let expected = ["file:///tmp/worf397b-a", "file:///tmp/worf397b-b"]
        #expect(ItemKind.allCases.count == 11)
        #expect(dragged["file"] == expected)
        #expect(dragged["folder"] == expected)
        #expect(dragged["bundle"] == expected)
        for kind in ["text", "richText", "link", "color", "phone", "email", "image", "screenshot"] {
            #expect(dragged[kind] == [], "kind \(kind) must not drag file URLs")
        }
    }

    // Red if a file item whose members are all gone yields a drag instead of failing/emptying (state-independent rule).
    @Test("OC-397b-D2 a bundle with every member gone, and an empty bundle, drag no file URL")
    func goneAndEmpty() {
        let goneBundle = ShelfDragCandidate(
            itemId: shelfID(1),
            content: ItemContent(kind: .bundle, plainText: nil, representations: [], members: [ItemMember(path: "/tmp/worf397b-x", bookmark: nil, isDirectory: false)]))
        let emptyBundle = ShelfDragCandidate(
            itemId: shelfID(2), content: ItemContent(kind: .bundle, plainText: nil, representations: [], members: []))

        #expect(urls(of: ShelfDragPlanner.plan([goneBundle], files: ExistingFiles(existing: []))) == [])
        #expect(urls(of: ShelfDragPlanner.plan([emptyBundle], files: ExistingFiles(existing: []))) == [])
    }
}
