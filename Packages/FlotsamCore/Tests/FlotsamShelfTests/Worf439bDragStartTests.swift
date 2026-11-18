import FlotsamBase
import FlotsamPayload
import Foundation
import Testing
@testable import FlotsamShelf

// TASK-439 re-verification (Worf, worf-439b): FR-006-11 / AC-006-24. `ShelfDragStart` is where SHF-OS-001 and LIB-DAT-001
// are decided for a Shelf drag-out. Fakes only; every expected value is a literal.

private struct PresentFiles: FileSystemPort {
    var existing: Set<String>
    func fileExists(at url: URL) -> Bool { existing.contains(url.path) }
    private func unused<T: Sendable>() -> FlotsamResult<T> { .failure(FlotsamError(.sysInt001, "unused in drag start tests")) }
    func createDirectory(at url: URL, permissions: Int) -> FlotsamResult<Void> { unused() }
    func copyItem(at source: URL, to destination: URL) -> FlotsamResult<Void> { unused() }
    func moveItem(at source: URL, to destination: URL) -> FlotsamResult<Void> { unused() }
    func removeItem(at url: URL) -> FlotsamResult<Void> { unused() }
    func contentsOfDirectory(at url: URL) -> FlotsamResult<[URL]> { unused() }
    func extendedAttribute(named name: String, at url: URL) -> Data? { nil }
    func writeFile(_ data: Data, to url: URL, permissions: Int) -> FlotsamResult<Void> { unused() }
    func readFile(at url: URL) -> FlotsamResult<Data> { unused() }
    func readFileNoFollow(at url: URL) -> FlotsamResult<Data> { unused() }
    func fileInfo(at url: URL) -> FileInfo? { nil }
    func availableCapacity(at url: URL) -> Int64? { nil }
}

private func fileItem(_ n: Int, path: String) -> ShelfDragItem {
    let data = Data("file://\(path)".utf8)
    return ShelfDragItem(itemId: shelfID(n), payload: .representations([PasteboardRepresentation(uti: PasteboardTypes.fileURL, data: data)]))
}

private func textItem(_ n: Int) -> ShelfDragItem {
    ShelfDragItem(itemId: shelfID(n), payload: .representations([PasteboardRepresentation(uti: "public.utf8-plain-text", data: Data("t\(n)".utf8))]))
}

private func plan(_ items: [ShelfDragItem], cards: [Int]) -> ShelfDragPlan {
    ShelfDragPlan(items: items, draggedItemIds: cards.map(shelfID))
}

private func preflight(
    _ p: ShelfDragPlan, window: Bool = true, event: Bool = true, existing: Set<String> = [], readable: Bool = true
) -> FlotsamResult<ShelfDragPlan> {
    ShelfDragStart.preflight(p, hasWindow: window, hasEvent: event, files: PresentFiles(existing: existing), isReadable: { _ in readable })
}

@Suite struct Worf439bPreflightTests {
    // MARK: no window / no event: the drag never starts, SHF-OS-001

    @Test func noWindowFailsWithShfOs001() {
        // red if the hasWindow guard is removed or maps to another code.
        let result = preflight(plan([textItem(1)], cards: [1]), window: false)
        #expect(result == .failure(FlotsamError(.shfOs001, "x")))
    }

    @Test func noEventFailsWithShfOs001() {
        // red if the hasEvent guard is removed or maps to another code.
        let result = preflight(plan([textItem(1)], cards: [1]), event: false)
        #expect(result == .failure(FlotsamError(.shfOs001, "x")))
    }

    @Test func windowAndEventPresentLetsATextCardThroughUnchanged() {
        // given a text card and nothing on disk, when preflight runs, then the plan is returned untouched (negative of the two guards).
        let p = plan([textItem(1)], cards: [1])
        #expect(preflight(p) == .success(p))
    }

    @Test func noWindowOutranksAMissingFileSoTheCodeIsShfOs001NotLibDat001() {
        // red if the file check runs before the window check.
        let result = preflight(plan([fileItem(1, path: "/gone")], cards: [1]), window: false)
        #expect(result == .failure(FlotsamError(.shfOs001, "x")))
    }

    // MARK: file members

    @Test func presentReadableFileIsKept() {
        let p = plan([fileItem(1, path: "/a")], cards: [1])
        #expect(preflight(p, existing: ["/a"]) == .success(p))
    }

    @Test func missingMemberIsSkippedAndItsCardLeavesTheDragList() {
        // given cards 1 (present) and 2 (missing), then only card 1 is dragged: count 2 -> 1, survivor identity kept.
        let p = plan([fileItem(1, path: "/a"), fileItem(2, path: "/b")], cards: [1, 2])
        let result = preflight(p, existing: ["/a"])
        guard case .success(let kept) = result else { Issue.record("expected success, got \(result)"); return }
        #expect(kept.items.count == 1)
        #expect(kept.items.first?.itemId == shelfID(1))
        #expect(kept.draggedItemIds == [shelfID(1)])
    }

    @Test func unreadableMemberIsSkippedEvenThoughItExists() {
        // red if isReadable is not consulted.
        let p = plan([fileItem(1, path: "/a"), textItem(2)], cards: [1, 2])
        let result = preflight(p, existing: ["/a"], readable: false)
        guard case .success(let kept) = result else { Issue.record("expected success, got \(result)"); return }
        #expect(kept.items.map(\.itemId) == [shelfID(2)])
        #expect(kept.draggedItemIds == [shelfID(2)])
    }

    @Test func unparseableFileURLDataIsSkipped() {
        let bad = ShelfDragItem(itemId: shelfID(1), payload: .representations([PasteboardRepresentation(uti: PasteboardTypes.fileURL, data: Data("not a url".utf8))]))
        let p = plan([bad, textItem(2)], cards: [1, 2])
        let result = preflight(p, existing: [])
        guard case .success(let kept) = result else { Issue.record("expected success, got \(result)"); return }
        #expect(kept.items.map(\.itemId) == [shelfID(2)])
    }

    @Test func aTextItemIsNeverSkippedForWantingAFile() {
        // negative: non-file items are not filesystem-checked, even when readable is false and nothing exists.
        let p = plan([textItem(1)], cards: [1])
        #expect(preflight(p, existing: [], readable: false) == .success(p))
    }

    @Test func bundleKeepsItsCardWhileOneMemberRemains() {
        // given one card (7) with two member items, one missing, then the card stays and the single survivor is kept.
        let p = plan([fileItem(7, path: "/m1"), fileItem(7, path: "/m2")], cards: [7])
        let result = preflight(p, existing: ["/m2"])
        guard case .success(let kept) = result else { Issue.record("expected success, got \(result)"); return }
        #expect(kept.items.count == 1)
        #expect(kept.draggedItemIds == [shelfID(7)])
    }

    @Test func bundleLeavesWhenEveryMemberIsGone() {
        let p = plan([fileItem(7, path: "/m1"), fileItem(7, path: "/m2"), textItem(8)], cards: [7, 8])
        let result = preflight(p, existing: [])
        guard case .success(let kept) = result else { Issue.record("expected success, got \(result)"); return }
        #expect(kept.draggedItemIds == [shelfID(8)])
        #expect(kept.items.map(\.itemId) == [shelfID(8)])
    }

    // MARK: nothing left: LIB-DAT-001

    @Test func everyMemberMissingFailsWithLibDat001AndTheSingleCardId() {
        // red if the emptiness guard is dropped (would return success with no items) or maps to SHF-OS-001.
        let p = plan([fileItem(5, path: "/gone")], cards: [5])
        #expect(preflight(p) == .failure(FlotsamError(.libDat001, "x", context: [.itemId: .id(shelfID(5))])))
    }

    @Test func manyCardsAllMissingFailsWithLibDat001AndNoCardIdInContext() {
        let p = plan([fileItem(1, path: "/x"), fileItem(2, path: "/y")], cards: [1, 2])
        #expect(preflight(p) == .failure(FlotsamError(.libDat001, "x")))
    }

    @Test func anEmptyPlanFailsWithLibDat001() {
        #expect(preflight(plan([], cards: [])) == .failure(FlotsamError(.libDat001, "x")))
    }
}

@Suite struct Worf439bOSErrorTests {
    @Test(arguments: [
        ShelfDragStart.OSFailure.noCard, .noWindow, .noEvent, .providerRejected, .noRepresentation,
    ])
    func everyOSFailureIsShfOs001(failure: ShelfDragStart.OSFailure) {
        #expect(ShelfDragStart.osError(failure).code == .shfOs001)
        #expect(ShelfDragStart.osError(failure).context.isEmpty)
    }

    @Test func nothingLeftToDragIsLibDat001WithTheCardOnlyWhenOne() {
        #expect(ShelfDragStart.nothingLeftToDrag(cards: [shelfID(4)]).code == .libDat001)
        #expect(ShelfDragStart.nothingLeftToDrag(cards: [shelfID(4)]).context == [.itemId: .id(shelfID(4))])
        #expect(ShelfDragStart.nothingLeftToDrag(cards: [shelfID(4), shelfID(5)]).context.isEmpty)
        #expect(ShelfDragStart.nothingLeftToDrag(cards: []).context.isEmpty)
    }
}

@Suite struct Worf439bLaunchTests {
    private let threeCards = plan([textItem(1), textItem(2), textItem(3)], cards: [1, 2, 3])

    @Test func everyItemWrittenStartsWithAllCardsAndNoReport() {
        let launch = ShelfDragStart.launch(threeCards, outcomes: [.written, .written, .written])
        #expect(launch == .start(draggedItemIds: [shelfID(1), shelfID(2), shelfID(3)], report: nil))
    }

    @Test func oc6082_everyProviderRejectedStartsNoDragAndReportsShfOs001() {
        // OC-6082: given the OS cannot supply any card's data, when the user drags, then no session starts and SHF-OS-001 shows;
        // no dragged card ids exist, so nothing can be counted as pasted (pasteCount unchanged).
        let launch = ShelfDragStart.launch(threeCards, outcomes: [.providerRejected, .providerRejected, .providerRejected])
        #expect(launch == .fail(FlotsamError(.shfOs001, "x")))
    }

    @Test func oc6082_someProvidersRejectedDragsTheRestAndReportsShfOs001() {
        // given cards 1 and 3 rejected, 2 written, then the drag goes ahead with card 2 only, plus SHF-OS-001.
        let launch = ShelfDragStart.launch(threeCards, outcomes: [.providerRejected, .written, .providerRejected])
        #expect(launch == .start(draggedItemIds: [shelfID(2)], report: FlotsamError(.shfOs001, "x")))
    }

    @Test func oc6082_aCancelledDragOfTheSurvivorsCountsNothing() {
        // given a partially rejected launch that starts, when the session ends with no operation, then it is a user cancel
        // carrying no cards: pasteCount unchanged and nothing shown.
        guard case .start(let dragged, _) = ShelfDragStart.launch(threeCards, outcomes: [.providerRejected, .written, .written]) else {
            Issue.record("expected start"); return
        }
        #expect(dragged == [shelfID(2), shelfID(3)])
        #expect(ShelfDragEnd.resolve(accepted: false, cards: dragged) == .userCancelled)
        #expect(ShelfDragEnd.resolve(accepted: true, cards: dragged) == .accepted(cards: [shelfID(2), shelfID(3)]))
    }

    @Test func unreadableImageIsSkippedSilentlyWhileOthersGo() {
        // AC-006-24: B has nothing to drag, so dragging A drags A and B is skipped with no HUD (report nil).
        let launch = ShelfDragStart.launch(plan([textItem(1), textItem(2)], cards: [1, 2]), outcomes: [.written, .imageUnreadable])
        #expect(launch == .start(draggedItemIds: [shelfID(1)], report: nil))
    }

    @Test func everyImageUnreadableFailsWithLibDat001NotShfOs001() {
        let launch = ShelfDragStart.launch(plan([textItem(1)], cards: [1]), outcomes: [.imageUnreadable])
        #expect(launch == .fail(FlotsamError(.libDat001, "x", context: [.itemId: .id(shelfID(1))])))
    }

    @Test func manyCardsAllImageUnreadableFailsWithLibDat001AndNoContext() {
        let launch = ShelfDragStart.launch(plan([textItem(1), textItem(2)], cards: [1, 2]), outcomes: [.imageUnreadable, .imageUnreadable])
        #expect(launch == .fail(FlotsamError(.libDat001, "x")))
    }

    @Test func rejectedPlusUnreadableWithNothingWrittenIsShfOs001() {
        // a rejected provider anywhere makes an all-failed launch an OS failure, not "nothing left".
        let launch = ShelfDragStart.launch(plan([textItem(1), textItem(2)], cards: [1, 2]), outcomes: [.imageUnreadable, .providerRejected])
        #expect(launch == .fail(FlotsamError(.shfOs001, "x")))
    }

    @Test func rejectedAndUnreadableBesideAWrittenOneReportsShfOs001ForTheRejectedOnly() {
        let launch = ShelfDragStart.launch(threeCards, outcomes: [.imageUnreadable, .written, .providerRejected])
        #expect(launch == .start(draggedItemIds: [shelfID(2)], report: FlotsamError(.shfOs001, "x")))
    }

    @Test func aCardWithTwoItemsStaysDraggedWhenOnlyOneItemIsWritten() {
        // a bundle card (7) with members m1 (rejected) and m2 (written) is still dragged once; card 8 is written too.
        let p = plan([fileItem(7, path: "/m1"), fileItem(7, path: "/m2"), textItem(8)], cards: [7, 8])
        let launch = ShelfDragStart.launch(p, outcomes: [.providerRejected, .written, .written])
        #expect(launch == .start(draggedItemIds: [shelfID(7), shelfID(8)], report: FlotsamError(.shfOs001, "x")))
    }

    @Test func draggedCardOrderFollowsThePlanNotTheOutcomeOrder() {
        let p = plan([textItem(3), textItem(1), textItem(2)], cards: [3, 1, 2])
        let launch = ShelfDragStart.launch(p, outcomes: [.written, .imageUnreadable, .written])
        #expect(launch == .start(draggedItemIds: [shelfID(3), shelfID(2)], report: nil))
    }
}
