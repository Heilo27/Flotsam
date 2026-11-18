import FlotsamBase
import FlotsamStorage
import Foundation
import Testing
@testable import FlotsamShelf

/// A filesystem where exactly the listed paths exist.
private struct ShelfFakeFiles: FileSystemPort {
    var existing: Set<String>
    func fileExists(at url: URL) -> Bool { existing.contains(url.path) }
    private func unused() -> FlotsamResult<Void> { .failure(FlotsamError(.sysInt001, "unused in drag planner tests")) }
    func createDirectory(at url: URL, permissions: Int) -> FlotsamResult<Void> { unused() }
    func copyItem(at source: URL, to destination: URL) -> FlotsamResult<Void> { unused() }
    func moveItem(at source: URL, to destination: URL) -> FlotsamResult<Void> { unused() }
    func removeItem(at url: URL) -> FlotsamResult<Void> { unused() }
    func contentsOfDirectory(at url: URL) -> FlotsamResult<[URL]> { .failure(FlotsamError(.sysInt001, "unused in drag planner tests")) }
    func extendedAttribute(named name: String, at url: URL) -> Data? { nil }
    func writeFile(_ data: Data, to url: URL, permissions: Int) -> FlotsamResult<Void> { unused() }
    func readFile(at url: URL) -> FlotsamResult<Data> { .failure(FlotsamError(.sysInt001, "unused in drag planner tests")) }
    func fileInfo(at url: URL) -> FileInfo? { nil }
    func availableCapacity(at url: URL) -> Int64? { nil }
}

private func rep(_ uti: String, _ text: String) -> PasteboardRepresentation {
    PasteboardRepresentation(uti: uti, data: Data(text.utf8))
}

private func textCandidate(_ n: Int, _ text: String, extra: [PasteboardRepresentation] = [], kind: ItemKind = .text) -> ShelfDragCandidate {
    ShelfDragCandidate(
        itemId: shelfID(n), content: ItemContent(kind: kind, plainText: text, representations: extra, members: []))
}

private func fileCandidate(_ n: Int, kind: ItemKind = .bundle, paths: [String]) -> ShelfDragCandidate {
    ShelfDragCandidate(
        itemId: shelfID(n),
        content: ItemContent(
            kind: kind, plainText: nil, representations: [],
            members: paths.map { ItemMember(path: $0, bookmark: nil, isDirectory: false) }))
}

private func imageCandidate(_ n: Int, kind: ItemKind = .screenshot, _ reps: [PasteboardRepresentation]) -> ShelfDragCandidate {
    ShelfDragCandidate(itemId: shelfID(n), content: ItemContent(kind: kind, plainText: nil, representations: reps, members: []))
}

private func fileURLItem(_ n: Int, _ url: String) -> ShelfDragItem {
    ShelfDragItem(itemId: shelfID(n), payload: .representations([rep("public.file-url", url)]))
}

private func plan(_ candidates: [ShelfDragCandidate], existing: Set<String> = []) -> FlotsamResult<ShelfDragPlan> {
    ShelfDragPlanner.plan(candidates, files: ShelfFakeFiles(existing: existing))
}

@Suite struct ShelfDragPlannerTests {
    // MARK: FR-006-10 text and rich text

    @Test func oc6069_aTextCardDragsItsPlainTextThenItsStoredRepresentations() throws {
        let rtf = rep("public.rtf", "{\\rtf1 drag-text-1}")
        let result = try plan([textCandidate(1, "drag-text-1", extra: [rtf])]).get()
        #expect(result.items == [ShelfDragItem(itemId: shelfID(1), payload: .representations([rep("public.utf8-plain-text", "drag-text-1"), rtf]))])
    }

    @Test func oc6076_aRichTextCardKeepsItsStoredFormattingRepresentation() throws {
        let rtf = rep("public.rtf", "{\\rtf1\\b bold}")
        let html = rep("public.html", "<b>bold</b>")
        let result = try plan([textCandidate(1, "bold", extra: [rtf, html], kind: .richText)]).get()
        guard case .representations(let written) = result.items.first?.payload else {
            Issue.record("expected representations")
            return
        }
        #expect(written == [rep("public.utf8-plain-text", "bold"), rtf, html])
    }

    @Test func oc6075_variablesAreNotExpanded() throws {
        let result = try plan([textCandidate(1, "{date}")]).get()
        #expect(result.items == [ShelfDragItem(itemId: shelfID(1), payload: .representations([rep("public.utf8-plain-text", "{date}")]))])
    }

    @Test func oc6069_everyTextBearingKindDragsAsText() throws {
        for kind in [ItemKind.text, .richText, .link, .color, .phone, .email] {
            let result = try plan([textCandidate(1, "x", kind: kind)]).get()
            #expect(result.items.count == 1, "\(kind)")
            #expect(result.items.first?.payload == .representations([rep("public.utf8-plain-text", "x")]), "\(kind)")
        }
    }

    // MARK: FR-006-10 images

    @Test func oc6067_aScreenshotIsOfferedAsItsBestImage() throws {
        let png = rep("public.png", "png-bytes")
        let tiff = rep("public.tiff", "tiff-bytes")
        let jpeg = rep("public.jpeg", "jpeg-bytes")
        #expect(try plan([imageCandidate(1, [jpeg, tiff, png])]).get().items.map(\.payload) == [.image(png)])
        #expect(try plan([imageCandidate(1, [jpeg, tiff])]).get().items.map(\.payload) == [.image(tiff)])
        #expect(try plan([imageCandidate(1, kind: .image, [jpeg])]).get().items.map(\.payload) == [.image(jpeg)])
    }

    @Test func oc6067_anImageWithNoUsableImageDataProvidesNothing() {
        let result = plan([imageCandidate(1, [rep("public.rtf", "not an image")])])
        guard case .failure(let error) = result else {
            Issue.record("expected a failure")
            return
        }
        #expect(error.code == .libDat001)
    }

    // MARK: FR-006-10 files

    @Test func oc6068_aBundleOfThreeIsThreePasteboardItemsFromOneCard() throws {
        let paths = ["/files/a.txt", "/files/b.txt", "/files/c.txt"]
        let result = try plan([fileCandidate(1, paths: paths)], existing: Set(paths)).get()
        #expect(result.items == [
            fileURLItem(1, "file:///files/a.txt"), fileURLItem(1, "file:///files/b.txt"), fileURLItem(1, "file:///files/c.txt"),
        ])
        #expect(result.draggedItemIds == [shelfID(1)])
        #expect(result.cardCount == 1)
    }

    @Test func oc6068_everyFileBackedKindDragsItsExistingMembersAsFileURLs() throws {
        for kind in [ItemKind.file, .folder, .bundle] {
            let result = try plan([fileCandidate(1, kind: kind, paths: ["/files/a"])], existing: ["/files/a"]).get()
            #expect(result.items == [fileURLItem(1, "file:///files/a")], "\(kind)")
        }
    }

    @Test func oc6073_aMissingMemberIsSkippedAndTheExistingOnesAreDragged() throws {
        let paths = ["/files/a.txt", "/files/b.txt", "/files/c.txt"]
        let result = try plan([fileCandidate(1, paths: paths)], existing: ["/files/a.txt", "/files/c.txt"]).get()
        #expect(result.items == [fileURLItem(1, "file:///files/a.txt"), fileURLItem(1, "file:///files/c.txt")])
    }

    @Test func oc6073_aStaleBookmarkFallsBackToTheStoredPath() throws {
        let member = ItemMember(path: "/files/a.txt", bookmark: Data("not a bookmark".utf8), isDirectory: false)
        let candidate = ShelfDragCandidate(
            itemId: shelfID(1), content: ItemContent(kind: .file, plainText: nil, representations: [], members: [member]))
        #expect(try plan([candidate], existing: ["/files/a.txt"]).get().items == [fileURLItem(1, "file:///files/a.txt")])
    }

    @Test func oc6079_aBundleWhoseMembersAreAllGoneDoesNotStartADrag() {
        let result = plan([fileCandidate(1, paths: ["/files/a.txt", "/files/b.txt"])])
        guard case .failure(let error) = result else {
            Issue.record("expected a failure")
            return
        }
        #expect(error.code == .libDat001)
    }

    @Test func oc6080_aFileCardWhoseFileIsGoneDoesNotStartADrag() {
        let result = plan([fileCandidate(1, kind: .file, paths: ["/files/a.txt"])])
        guard case .failure(let error) = result else {
            Issue.record("expected a failure")
            return
        }
        #expect(error.code == .libDat001)
    }

    // MARK: FR-006-10 and FR-006-11 several cards

    @Test func oc6072_threeTextCardsAreThreePasteboardItemsInTheOrderGiven() throws {
        let result = try plan([textCandidate(1, "one"), textCandidate(2, "two"), textCandidate(3, "three")]).get()
        #expect(result.items.map(\.itemId) == [shelfID(1), shelfID(2), shelfID(3)])
        #expect(result.items.map(\.payload) == [
            .representations([rep("public.utf8-plain-text", "one")]),
            .representations([rep("public.utf8-plain-text", "two")]),
            .representations([rep("public.utf8-plain-text", "three")]),
        ])
        #expect(result.cardCount == 3)
    }

    @Test func oc6078_everyContributingCardCountsOnceAndACardWithNothingLeftIsLeftOut() throws {
        let candidates = [
            textCandidate(1, "A"),
            fileCandidate(2, kind: .file, paths: ["/files/gone.txt"]),
            fileCandidate(3, paths: ["/files/a.txt", "/files/b.txt"]),
        ]
        let result = try plan(candidates, existing: ["/files/a.txt", "/files/b.txt"]).get()
        #expect(result.draggedItemIds == [shelfID(1), shelfID(3)])
        #expect(result.items.count == 3)
        #expect(result.cardCount == 2)
    }

    @Test func aMixedDragKeepsTheOrderOfItsCards() throws {
        let png = rep("public.png", "png")
        let result = try plan(
            [fileCandidate(1, paths: ["/files/a.txt"]), imageCandidate(2, [png]), textCandidate(3, "t")],
            existing: ["/files/a.txt"]).get()
        #expect(result.items.map(\.itemId) == [shelfID(1), shelfID(2), shelfID(3)])
    }

    @Test func nothingToDragIsShfOs001() {
        guard case .failure(let error) = plan([]) else {
            Issue.record("expected a failure")
            return
        }
        #expect(error.code == .shfOs001)
    }
}

@MainActor
@Suite struct ShelfDragSelectionTests {
    private func rows(_ numbers: Range<Int>) -> [ItemRow] { numbers.map { makeShelfRow($0) } }

    @Test func oc6062_clickThenShiftClickThenDragGivesTheThreeCardsInOrder() async throws {
        let rig = ShelfRig(rows: rows(1..<5))
        await rig.openSticky()
        rig.model.click(shelfID(1))
        rig.model.click(shelfID(3), modifiers: .shift)
        let dragged = rig.model.covered(by: shelfID(2))
        #expect(dragged.map(\.id) == [shelfID(1), shelfID(2), shelfID(3)])
        let candidates = dragged.map {
            ShelfDragCandidate(
                itemId: $0.id, content: ItemContent(kind: .text, plainText: $0.primaryLine, representations: [], members: []))
        }
        let result = try plan(candidates).get()
        #expect(result.items.count == 3)
        #expect(result.items.map(\.itemId) == [shelfID(1), shelfID(2), shelfID(3)])
    }

    @Test func oc6062_draggingACardOutsideTheSelectionDragsThatCardAlone() async {
        let rig = ShelfRig(rows: rows(1..<5))
        await rig.openSticky()
        rig.model.click(shelfID(1))
        rig.model.click(shelfID(2), modifiers: .shift)
        #expect(rig.model.covered(by: shelfID(4)).map(\.id) == [shelfID(4)])
        #expect(rig.model.selection == [shelfID(1), shelfID(2)])
    }

    @Test func oc6072_theSelectionDragsInOnScreenOrderPinnedBeforeRecent() async {
        let rig = ShelfRig(rows: [makeShelfRow(1), makeShelfRow(2), makeShelfRow(3, pinned: true)])
        await rig.openSticky()
        rig.model.click(shelfID(3))
        rig.model.click(shelfID(2), modifiers: .shift)
        #expect(rig.model.covered(by: shelfID(1)).map(\.id) == [shelfID(3), shelfID(1), shelfID(2)])
    }

    @Test func draggingACardThatIsNotOnTheShelfDragsNothing() async {
        let rig = ShelfRig(rows: rows(1..<3))
        await rig.openSticky()
        #expect(rig.model.covered(by: shelfID(9)).isEmpty)
    }
}
