import FlotsamBase
import FlotsamStorage
import Foundation
import Testing
@testable import FlotsamShelf

// FRD-005 8T contract tests, slice S8, OC-5117 Shelf half (AC-005-16, BR-4): an item '{date}' dragged from the Shelf
// carries the literal text '{date}'. Observed at the drag plan, the one place the Shelf decides what a drag carries.
// UNTESTABLE-AT-PACKAGE: "into TextEdit" (the AppKit drag pasteboard and TextEdit receiving it). Missing seam: a
// UI-automation harness over a real NSDraggingSession and TextEdit (App/OS half). The Library half (Return, Copy,
// preview) is FlotsamLibraryTests/FRD005ContractTestsVariablesLibrary.

private struct S8Files: FileSystemPort {
    private func unused() -> FlotsamResult<Void> { .failure(FlotsamError(.sysInt001, "unused in drag plan tests")) }
    func fileExists(at url: URL) -> Bool { false }
    func createDirectory(at url: URL, permissions: Int) -> FlotsamResult<Void> { unused() }
    func copyItem(at source: URL, to destination: URL) -> FlotsamResult<Void> { unused() }
    func moveItem(at source: URL, to destination: URL) -> FlotsamResult<Void> { unused() }
    func removeItem(at url: URL) -> FlotsamResult<Void> { unused() }
    func contentsOfDirectory(at url: URL) -> FlotsamResult<[URL]> { .failure(FlotsamError(.sysInt001, "unused in drag plan tests")) }
    func extendedAttribute(named name: String, at url: URL) -> Data? { nil }
    func writeFile(_ data: Data, to url: URL, permissions: Int) -> FlotsamResult<Void> { unused() }
    func readFile(at url: URL) -> FlotsamResult<Data> { .failure(FlotsamError(.sysInt001, "unused in drag plan tests")) }
    func readFileNoFollow(at url: URL) -> FlotsamResult<Data> { .failure(FlotsamError(.sysInt001, "unused in drag plan tests")) }
    func fileInfo(at url: URL) -> FileInfo? { nil }
    func availableCapacity(at url: URL) -> Int64? { nil }
}

@Suite struct FRD005ContractTestsVariablesShelf {
    private func candidate(_ n: Int, _ text: String) -> ShelfDragCandidate {
        ShelfDragCandidate(itemId: shelfID(n), content: ItemContent(kind: .text, plainText: text, representations: [], members: []))
    }

    // Red if the drag planner starts expanding variables (calls the template expander) or drops the text.
    @Test("OC-5117 a Shelf drag of '{date}' carries the literal '{date}' as its only representation")
    func oc5117_shelfDragIsLiteral() throws {
        // given: the item '{date}' on the Shelf (it has a trigger; a trigger does not change a drag), and a bystander
        let candidates = [candidate(1, "{date}"), candidate(2, "{time:HH:mm} {clipboard}")]
        // when: the drag plan is made for the first card, then for the second
        let first = try ShelfDragPlanner.plan([candidates[0]], files: S8Files()).get()
        let second = try ShelfDragPlanner.plan([candidates[1]], files: S8Files()).get()
        // then: each plan is exactly one item, with its own id and its own literal text
        #expect(first.items == [ShelfDragItem(itemId: shelfID(1), payload: .representations([
            PasteboardRepresentation(uti: "public.utf8-plain-text", data: Data("{date}".utf8))]))])
        #expect(second.items == [ShelfDragItem(itemId: shelfID(2), payload: .representations([
            PasteboardRepresentation(uti: "public.utf8-plain-text", data: Data("{time:HH:mm} {clipboard}".utf8))]))])
        #expect(first.items.count == 1)
    }
}
