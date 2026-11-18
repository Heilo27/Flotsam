import Foundation
import Testing
import FlotsamBase
@testable import FlotsamScreenshots

// WORF-471 (FRD-002 FR-002-08, FR-002-10): adversarial cases for the hold a fresh hidden file puts on the persisted
// watermark. Expected values are literals or test-owned dates (the hidden file's own birth plus a stated number of
// seconds); no production formula is repeated.

private let tolerance: TimeInterval = 0.05
private let t0 = Date(timeIntervalSinceReferenceDate: 800_000_000)
private func at(_ seconds: TimeInterval) -> Date { t0.addingTimeInterval(seconds) }

@Suite("Worf471 hold arithmetic with hidden births")
struct Worf471HoldArithmeticTests {
    /// OC-471-W1. given a hidden file born at 0 s, when asked at 59.999 s, 60 s and 60.001 s, then it holds only before 60 s.
    @Test("OC-471-W1 the window is exactly 60 s: held just before, released at 60 s and after")
    func windowBoundary() {
        #expect(ScreenshotSelection.isHeld(at(0), now: at(59.999)))
        #expect(!ScreenshotSelection.isHeld(at(0), now: at(60)))
        #expect(!ScreenshotSelection.isHeld(at(0), now: at(60.001)))
        #expect(ScreenshotSelection.isHeld(at(0), now: at(0)))
    }

    /// OC-471-W2. given two hidden files born at 0 s and 15 s, when both are inside their windows, then the watermark
    /// goes no further than the older birth; when the older has expired the newer one holds alone.
    @Test("OC-471-W2 two hidden files: the oldest live birth holds, an expired one does not")
    func oldestLiveBirthHolds() {
        #expect(ScreenshotSelection.heldBack(at(45), now: at(45), births: [at(15), at(0)]) == at(0))
        #expect(ScreenshotSelection.heldBack(at(65), now: at(65), births: [at(0), at(15)]) == at(15))
        #expect(ScreenshotSelection.heldBack(at(80), now: at(80), births: [at(0), at(15)]) == at(80))
    }
}

@Suite("Worf471 hidden files and the live watermark", .serialized)
struct Worf471WatcherTests {
    private func hidden(_ rig: WatcherRig, born: Date, name: String = ".hidden-note \(UUID().uuidString).txt", attribute: Bool? = nil) throws -> URL {
        try rig.shot(in: rig.desktop, name, born: born, attribute: attribute)
    }

    /// OC-471-A1. given a hidden temporary born at T, when macOS renames it to a screenshot (birth kept), then the screenshot
    /// is imported once, the hold ends with the rename (watermark 5 s past the imported birth), and a relaunch offers nothing.
    @Test("OC-471-A1 a hidden file renamed into a screenshot is imported once and stops holding")
    func renamedIntoScreenshot() async throws {
        let rig = try WatcherRig(watermark: Date().addingTimeInterval(-100))
        defer { rig.cleanUp() }
        await rig.watcher.start()
        let born = rig.clock.now()
        let temp = try hidden(rig, born: born, name: ".Screenshot-tmp-\(UUID().uuidString).png", attribute: true)
        rig.event(temp)
        await letItSettle()
        let finalURL = rig.desktop.appendingPathComponent("Screenshot \(UUID().uuidString).png")
        try FileManager.default.moveItem(at: temp, to: finalURL)

        rig.source.emit(.changed([temp, finalURL]))

        #expect(await eventually { rig.ingest.names == [finalURL.lastPathComponent] })
        #expect(await eventually { (rig.marks.value ?? .distantPast) >= born.addingTimeInterval(5 - tolerance) })
        let marked = try #require(rig.marks.value)
        #expect(marked <= born.addingTimeInterval(5 + tolerance), "watermark \(marked) not at 5 s past the imported birth")
        rig.relaunch()
        await rig.watcher.start()
        await letItSettle()
        #expect(rig.ingest.names == [finalURL.lastPathComponent])
    }

    /// OC-471-A2. given a hidden file named like a screenshot, with the screen-capture attribute, that is never renamed,
    /// then it is never imported (FR-002-06 a), not live and not on relaunch, though it holds the watermark.
    @Test("OC-471-A2 a hidden file that is never renamed is never imported")
    func neverRenamedNotImported() async throws {
        let rig = try WatcherRig(watermark: Date().addingTimeInterval(-100))
        defer { rig.cleanUp() }
        await rig.watcher.start()
        let born = rig.clock.now()
        let temp = try hidden(rig, born: born, name: ".Screenshot \(UUID().uuidString).png", attribute: true)

        rig.event(temp)
        await letItSettle()
        rig.relaunch()
        await rig.watcher.start()
        await letItSettle()

        #expect(rig.ingest.names.isEmpty)
        #expect(try #require(rig.marks.value) <= born.addingTimeInterval(tolerance))
    }

    /// OC-471-A3. given a fresh hidden file that is then deleted and its event delivered, when a tick runs, then it holds
    /// nothing: the watermark reaches the tick's time.
    @Test("OC-471-A3 a hidden file deleted with its event stops holding at once")
    func deletedWithEventReleases() async throws {
        let rig = try WatcherRig(watermark: Date().addingTimeInterval(-100))
        defer { rig.cleanUp() }
        await rig.watcher.start()
        let born = rig.clock.now()
        let temp = try hidden(rig, born: born)
        rig.event(temp)
        await letItSettle()
        try FileManager.default.removeItem(at: temp)
        rig.event(temp)
        await letItSettle()

        await rig.tick()

        let marked = try #require(rig.marks.value)
        #expect(marked >= born.addingTimeInterval(30 - tolerance), "watermark \(marked) still held at the deleted file")
    }

    /// OC-471-A4. given a hidden file deleted with no event, when time passes the window, then the hold is gone anyway; and
    /// a relaunch's own listing (no hidden file any more) does not hold at all.
    @Test("OC-471-A4 a hidden file deleted silently stops holding by 60 s; a fresh listing never holds it")
    func deletedSilently() async throws {
        let rig = try WatcherRig(watermark: Date().addingTimeInterval(-100))
        defer { rig.cleanUp() }
        await rig.watcher.start()
        let born = rig.clock.now()
        let temp = try hidden(rig, born: born)
        rig.event(temp)
        await letItSettle()
        try FileManager.default.removeItem(at: temp)

        rig.clock.advance(by: 61)
        await rig.watcher.tickFired()

        #expect(try #require(rig.marks.value) >= born.addingTimeInterval(61 - tolerance))
        // given a second silent deletion, when a relaunch lists the folder (clock 10 s on), then nothing holds
        let second = try hidden(rig, born: rig.clock.now())
        rig.event(second)
        await letItSettle()
        try FileManager.default.removeItem(at: second)
        rig.clock.advance(by: 10)
        rig.relaunch()
        await rig.watcher.start()
        #expect(await eventually { (rig.marks.value ?? .distantPast) >= born.addingTimeInterval(71 - tolerance) })
    }

    /// OC-471-A5. given two hidden files born 15 s apart, when ticks run, then the older holds first, then the newer alone
    /// after the older expires, then nothing after both expire.
    @Test("OC-471-A5 two hidden files hold in turn: oldest, then the newer alone, then none")
    func twoHiddenFiles() async throws {
        let rig = try WatcherRig(watermark: Date().addingTimeInterval(-100))
        defer { rig.cleanUp() }
        await rig.watcher.start()
        let bornA = rig.clock.now()
        let a = try hidden(rig, born: bornA)
        rig.event(a)
        rig.clock.advance(by: 15)
        let bornB = rig.clock.now()
        let b = try hidden(rig, born: bornB)
        rig.event(b)
        await letItSettle()

        rig.clock.advance(by: 30)  // 45 s after A
        await rig.watcher.tickFired()
        #expect(try #require(rig.marks.value) <= bornA.addingTimeInterval(tolerance), "older hidden file does not hold")

        rig.clock.advance(by: 20)  // 65 s after A: A has expired, B (50 s old) holds
        await rig.watcher.tickFired()
        let second = try #require(rig.marks.value)
        #expect(second >= bornB.addingTimeInterval(-tolerance) && second <= bornB.addingTimeInterval(tolerance), "watermark \(second) not at B's birth")

        rig.clock.advance(by: 20)  // 85 s after A: both expired
        await rig.watcher.tickFired()
        #expect(try #require(rig.marks.value) >= bornA.addingTimeInterval(85 - tolerance))
    }

    /// OC-471-A6. given a hidden file, when a tick runs 59 s then 61 s after its birth, then it holds at 59 s and not at 61 s.
    @Test("OC-471-A6 the hold lasts past 59 s and is gone at 61 s")
    func windowExpiryThroughWatcher() async throws {
        let rig = try WatcherRig(watermark: Date().addingTimeInterval(-100))
        defer { rig.cleanUp() }
        await rig.watcher.start()
        let born = rig.clock.now()
        let temp = try hidden(rig, born: born)
        rig.event(temp)
        await letItSettle()

        rig.clock.advance(by: 59)
        await rig.watcher.tickFired()
        #expect(try #require(rig.marks.value) <= born.addingTimeInterval(tolerance), "released before 60 s")

        rig.clock.advance(by: 2)
        await rig.watcher.tickFired()
        #expect(try #require(rig.marks.value) >= born.addingTimeInterval(61 - tolerance), "still held after 60 s")
    }

    /// OC-471-A7. given a fresh hidden file already in the folder at launch (found by the listing, not an event), when the
    /// scan sets the watermark 20 s later, then it stops at the hidden file's birth.
    @Test("OC-471-A7 a hidden file present at launch holds the launch scan's watermark")
    func presentAtLaunch() async throws {
        let rig = try WatcherRig(watermark: Date().addingTimeInterval(-100))
        defer { rig.cleanUp() }
        let born = rig.clock.now()
        _ = try hidden(rig, born: born)
        rig.clock.advance(by: 20)

        await rig.watcher.start()

        #expect(await eventually { (rig.marks.value ?? .distantPast) >= born.addingTimeInterval(-tolerance) })
        #expect(try #require(rig.marks.value) <= born.addingTimeInterval(tolerance), "launch scan passed the fresh hidden file")
    }

    /// OC-471-A8. given a hidden file born 120 s ago (negative case), then it holds nothing.
    @Test("OC-471-A8 an old hidden file does not hold")
    func oldHiddenDoesNotHold() async throws {
        let rig = try WatcherRig(watermark: Date().addingTimeInterval(-300))
        defer { rig.cleanUp() }
        let now = rig.clock.now()
        _ = try hidden(rig, born: now.addingTimeInterval(-120))
        await rig.watcher.start()

        await rig.tick()

        #expect(try #require(rig.marks.value) >= now.addingTimeInterval(30 - tolerance))
    }

    /// OC-471-A9. given a fresh hidden directory (FRD: regular files only), when its event arrives and a tick runs, then
    /// it holds nothing.
    @Test("OC-471-A9 a fresh hidden folder does not hold")
    func hiddenFolderDoesNotHold() async throws {
        let rig = try WatcherRig(watermark: Date().addingTimeInterval(-100))
        defer { rig.cleanUp() }
        await rig.watcher.start()
        let born = rig.clock.now()
        let dir = try rig.temp.folder("home/Desktop/.fseventsd-\(UUID().uuidString)")
        try FileManager.default.setAttributes([.creationDate: born], ofItemAtPath: dir.path)
        rig.event(dir)
        await letItSettle()

        await rig.tick()

        #expect(try #require(rig.marks.value) >= born.addingTimeInterval(30 - tolerance))
    }
}
