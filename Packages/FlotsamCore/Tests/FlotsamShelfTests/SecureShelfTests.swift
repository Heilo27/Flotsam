import FlotsamBase
import FlotsamStorage
import Foundation
import Testing
@testable import FlotsamShelf

/// A filesystem with nothing on it: a secure card has no files.
private struct NoFiles: FileSystemPort {
    private func unused() -> FlotsamResult<Void> { .failure(FlotsamError(.sysInt001, "unused in secure shelf tests")) }
    func fileExists(at url: URL) -> Bool { false }
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

private func secureContent() -> ItemContent {
    ItemContent(kind: .text, plainText: nil, representations: [], members: [], secureCiphertext: Data([1, 2, 3]))
}

private func secureRow(_ n: Int, unavailable: Bool = false) -> ItemRow {
    ItemRow(
        id: shelfID(n), kind: .text, lastCopiedAt: Date(timeIntervalSince1970: 1_000_000), pasteCount: 0,
        primaryLine: unavailable ? "Unavailable" : SecureClip.mask, sourceName: "1Password", tagNames: [], isPinned: false,
        hasTrigger: false, hasShortcut: false, pixelWidth: nil, pixelHeight: nil, memberCount: 0, byteSize: 0,
        isSecure: true, isUnavailable: unavailable)
}

/// FR-006-21: a secure card is masked, and its text leaves the Shelf only once the owner has authenticated.
@Suite struct SecureShelfTests {
    // MARK: Drag-out needs the check

    @Test func aSecureCardWithoutRevealedTextHasNothingToDrag() {
        let candidate = ShelfDragCandidate(itemId: shelfID(1), content: secureContent())
        let result = ShelfDragPlanner.plan([candidate], files: NoFiles())
        guard case .failure(let error) = result else {
            Issue.record("a secure card was planned without authentication")
            return
        }
        #expect(error.code == .libDat001)
    }

    @Test func aSecureCardAfterTheCheckDragsItsTextAsConcealed() throws {
        let candidate = ShelfDragCandidate(itemId: shelfID(1), content: secureContent(), revealedSecureText: "s3cret")
        let plan = try ShelfDragPlanner.plan([candidate], files: NoFiles()).get()
        #expect(plan.items.count == 1)
        guard case .representations(let reps) = plan.items[0].payload else {
            Issue.record("expected representations")
            return
        }
        #expect(reps.first { $0.uti == PasteboardUTI.plainText }?.data == Data("s3cret".utf8))
        #expect(reps.map(\.uti).contains(PasteboardMarkers.concealed))
    }

    @Test func aDeclinedSecureCardIsSkippedWhileTheOthersStillDrag() throws {
        let plain = ShelfDragCandidate(
            itemId: shelfID(2), content: ItemContent(kind: .text, plainText: "plain", representations: [], members: []))
        let locked = ShelfDragCandidate(itemId: shelfID(1), content: secureContent())
        let plan = try ShelfDragPlanner.plan([locked, plain], files: NoFiles()).get()
        #expect(plan.items.map(\.itemId) == [shelfID(2)])
    }

    // MARK: The mask

    @Test func theShelfCardShowsTheMaskNeverTheText() {
        let card = ShelfCardPresentation(row: secureRow(1), text: "s3cret", now: Date(timeIntervalSince1970: 1_000_100))
        #expect(card.isSecure)
        #expect(card.text == SecureClip.mask)
        #expect(card.visual == .secure)
        #expect(card.unavailableBadge == nil)
    }

    @Test func aSecureCardWhoseKeyIsGoneCarriesTheUnavailableBadge() {
        let card = ShelfCardPresentation(row: secureRow(1, unavailable: true), now: Date(timeIntervalSince1970: 1_000_100))
        #expect(card.text == SecureClip.mask)
        #expect(card.unavailableBadge == ShelfText.string(ShelfText.secureUnavailable))
        #expect(card.unavailableBadge?.isEmpty == false)
    }
}
