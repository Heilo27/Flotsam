import Foundation
import Testing
import FlotsamBase
@testable import FlotsamPaste

/// A pasteboard whose content a test controls, and whose `changeCount` another app can bump.
@MainActor
final class ScriptedPasteboard: PasteboardPort {
    var types: [String]
    var representations: [PasteboardRepresentation]
    var readFailure: FlotsamError?
    private(set) var changeCount = 10
    private(set) var readTypes: [[String]] = []
    private(set) var writes: [[PasteboardRepresentation]] = []

    init(_ representations: [PasteboardRepresentation]) {
        self.representations = representations
        self.types = representations.map(\.uti)
    }

    func currentTypeIdentifiers() -> [String] { types }
    func readSnapshot(types: [String]) -> FlotsamResult<PasteboardSnapshot> {
        readTypes.append(types)
        if let readFailure { return .failure(readFailure) }
        return .success(PasteboardSnapshot(changeCount: changeCount, typeIdentifiers: self.types, representations: representations))
    }
    func write(_ representations: [PasteboardRepresentation]) -> FlotsamResult<Int> {
        writes.append(representations)
        self.representations = representations
        types = representations.map(\.uti)
        changeCount += 1
        return .success(changeCount)
    }
    /// Another app copying.
    func otherAppCopies() { changeCount += 1 }
}

/// FR-005-16 / AC-005-15.
@MainActor
@Suite struct ClipboardPreserverTests {
    private func rep(_ uti: String, _ text: String = "x") -> PasteboardRepresentation {
        PasteboardRepresentation(uti: uti, data: Data(text.utf8))
    }

    private func preserver(_ board: ScriptedPasteboard) -> (ClipboardPreserver, OwnWriteLedger, RecordingClock) {
        let ledger = OwnWriteLedger()
        let clock = RecordingClock()
        return (ClipboardPreserver(pasteboard: board, ownWrites: ledger, clock: clock), ledger, clock)
    }

    /// Simulates the expansion's own write, returning the changeCount it produced.
    private func expansionWrites(_ board: ScriptedPasteboard, _ ledger: OwnWriteLedger) throws -> Int {
        try ledger.write([rep(PastePayload.plainTextType, "expanded")], to: board).get()
    }

    @Test func captureHoldsEveryTypeAndExposesThePlainText() {
        let board = ScriptedPasteboard([rep("public.png", "img"), rep(PastePayload.plainTextType, "hello")])
        let capture = preserver(board).0.capture()
        #expect(capture.disposition == .held)
        #expect(capture.plainText == "hello")
        #expect(board.readTypes == [["public.png", PastePayload.plainTextType]])
    }

    @Test func restoreWritesTheCopyBackAfterTheDelayWhenNobodyElseCopied() async throws {
        let board = ScriptedPasteboard([rep("public.png", "img"), rep(PastePayload.plainTextType, "hello")])
        let (preserver, ledger, clock) = preserver(board)
        let capture = preserver.capture()
        let afterWrite = try expansionWrites(board, ledger)

        let outcome = await preserver.restore(capture, writeChangeCount: afterWrite)

        #expect(outcome == .restored)
        #expect(clock.slept == [.milliseconds(300)])
        let restored = try #require(board.writes.last)
        #expect(restored.filter { $0.uti == "public.png" || $0.uti == PastePayload.plainTextType }.count == 2)
        #expect(restored.first { $0.uti == "public.png" }?.data == Data("img".utf8))
        // Written through the ledger: own-write markers present, change recorded so capture skips it.
        #expect(restored.contains { $0.uti == PasteboardMarkers.ownWrite })
        #expect(ledger.contains(changeCount: board.changeCount))
    }

    @Test func restoreIsSkippedWhenAnotherAppCopiedInTheWindow() async throws {
        let board = ScriptedPasteboard([rep(PastePayload.plainTextType, "hello")])
        let (preserver, ledger, _) = preserver(board)
        let capture = preserver.capture()
        let afterWrite = try expansionWrites(board, ledger)
        board.otherAppCopies()
        let writesBefore = board.writes.count

        #expect(await preserver.restore(capture, writeChangeCount: afterWrite) == .changedByAnotherApp)
        #expect(board.writes.count == writesBefore)
    }

    @Test func concealedAndTransientPasteboardsAreNeverReadHeldOrRestored() async throws {
        for marker in [PasteboardMarkers.concealed, PasteboardMarkers.transient] {
            let board = ScriptedPasteboard([rep(PastePayload.plainTextType, "hunter2"), rep(marker, "")])
            let (preserver, ledger, clock) = preserver(board)
            let capture = preserver.capture()
            #expect(capture.disposition == .concealed)
            #expect(capture.plainText == "")
            #expect(board.readTypes.isEmpty, "no bytes were read")
            let afterWrite = try expansionWrites(board, ledger)
            let writes = board.writes.count
            #expect(await preserver.restore(capture, writeChangeCount: afterWrite) == .nothingHeld)
            #expect(board.writes.count == writes)
            #expect(clock.slept.isEmpty)
        }
    }

    @Test func overTheCapIsNotHeldAndNotRestored() async throws {
        let big = PasteboardRepresentation(uti: "public.tiff", data: Data(count: ClipboardPreserver.snapshotCap + 1))
        let board = ScriptedPasteboard([big, rep(PastePayload.plainTextType, "caption")])
        let (preserver, ledger, _) = preserver(board)
        let capture = preserver.capture()
        #expect(capture.disposition == .tooLarge)
        #expect(capture.plainText == "caption")
        let afterWrite = try expansionWrites(board, ledger)
        #expect(await preserver.restore(capture, writeChangeCount: afterWrite) == .nothingHeld)
    }

    @Test func exactlyTheCapIsHeld() {
        let board = ScriptedPasteboard([PasteboardRepresentation(uti: "public.tiff", data: Data(count: ClipboardPreserver.snapshotCap))])
        #expect(preserver(board).0.capture().disposition == .held)
    }

    @Test func anEmptyOrUnreadablePasteboardHoldsNothingAndHasNoText() {
        #expect(preserver(ScriptedPasteboard([])).0.capture().disposition == .empty)
        let blocked = ScriptedPasteboard([rep(PastePayload.plainTextType, "secret")])
        blocked.readFailure = FlotsamError(.sysInt001, "blocked")
        let capture = preserver(blocked).0.capture()
        #expect(capture.disposition == .unreadable)
        #expect(capture.plainText == "")
    }

    @Test func multiItemPasteboardsKeepTheFirstRepresentationOfEachType() async throws {
        let board = ScriptedPasteboard([
            rep("public.file-url", "file:///a"), rep("public.file-url", "file:///b"),
            rep(PasteboardMarkers.ownWrite, ""), rep(PasteboardMarkers.autoGenerated, ""),
        ])
        let (preserver, ledger, _) = preserver(board)
        let capture = preserver.capture()
        let afterWrite = try expansionWrites(board, ledger)
        #expect(await preserver.restore(capture, writeChangeCount: afterWrite) == .restored)
        let restored = try #require(board.writes.last)
        #expect(restored.filter { $0.uti == "public.file-url" }.map(\.data) == [Data("file:///a".utf8)])
        // The ledger's markers appear once each, not duplicated from the snapshot.
        #expect(restored.filter { $0.uti == PasteboardMarkers.ownWrite }.count == 1)
        #expect(restored.filter { $0.uti == PasteboardMarkers.autoGenerated }.count == 1)
    }
}
