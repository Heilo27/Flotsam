import Foundation
import Testing
import FlotsamBase
@testable import FlotsamScreenshots

// FR-002-08 reconcile, FR-002-12 backfill, FR-002-07 stability.
@Suite struct ScreenshotSelectionTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let day: TimeInterval = 24 * 60 * 60

    private func file(_ name: String, _ createdAt: Date) -> ScreenshotFile {
        ScreenshotFile(url: URL(fileURLWithPath: "/shots/\(name).png"), createdAt: createdAt, byteSize: 1)
    }

    @Test("FR-002-08 first launch (no watermark) imports nothing")
    func noWatermark() {
        #expect(ScreenshotSelection.reconcile([file("a", now)], lastScanAt: nil).isEmpty)
    }

    @Test("FR-002-08 the 5 s slack boundary: exactly watermark-5 s is out, a millisecond later is in; oldest first")
    func slackBoundary() {
        let mark = now
        let files = [
            file("late", mark.addingTimeInterval(10)),
            file("edge", mark.addingTimeInterval(-5)),
            file("inside", mark.addingTimeInterval(-4.999)),
            file("old", mark.addingTimeInterval(-3_600)),
        ]
        let picked = ScreenshotSelection.reconcile(files, lastScanAt: mark).map(\.url.lastPathComponent)
        #expect(picked == ["inside.png", "late.png"])
    }

    @Test("AC-002-10 700 screenshots within 30 days: backfill takes the 500 newest, oldest first")
    func backfill700() {
        let files = (0..<700).map { file("s\($0)", now.addingTimeInterval(-Double($0) * 3_600)) }  // one per hour
        let picked = ScreenshotSelection.backfill(files, now: now, retention: .d30)
        #expect(picked.count == 500)
        #expect(picked.first?.url.lastPathComponent == "s499.png")
        #expect(picked.last?.url.lastPathComponent == "s0.png")
        #expect(zip(picked, picked.dropFirst()).allSatisfy { $0.createdAt <= $1.createdAt })
    }

    @Test(
        "FR-002-12 the backfill window is the retention period, capped at 30 days",
        arguments: [(RetentionPreset.d7, 7.0), (.d30, 30), (.d90, 30), (.y1, 30), (.forever, 30)])
    func backfillWindow(retention: RetentionPreset, days: Double) {
        let inside = file("inside", now.addingTimeInterval(-days * day + 60))
        let outside = file("outside", now.addingTimeInterval(-days * day - 60))
        let picked = ScreenshotSelection.backfill([inside, outside], now: now, retention: retention)
        #expect(picked == [inside])
    }

    // MARK: Stability (FR-002-07)

    private let url = URL(fileURLWithPath: "/shots/growing.png")

    @Test("FR-002-07 a final file is stable after one 0.5 s check")
    func alreadyFinal() async throws {
        let clock = ManualClock()
        let check = StabilityCheck(fileSystem: GrowingFileSystem(clock: clock, settlesAfter: 0), clock: clock)
        let info = try await check.waitUntilStable(url).get()
        #expect(info.byteSize == 1_000)
        #expect(clock.now().timeIntervalSince(Date(timeIntervalSince1970: 1_800_000_000)) == 0.5)
    }

    @Test("AC-002-06 a file growing for 3 s is imported once it stops changing")
    func growsThreeSeconds() async throws {
        let clock = ManualClock()
        let check = StabilityCheck(fileSystem: GrowingFileSystem(clock: clock, settlesAfter: 3), clock: clock)
        let info = try await check.waitUntilStable(url).get()
        #expect(info.byteSize == 4_000)
        #expect(clock.now().timeIntervalSince(Date(timeIntervalSince1970: 1_800_000_000)) == 3.5)
    }

    @Test("AC-002-06 a file growing for over 5 s is skipped with SSP-IO-002")
    func growsTooLong() async {
        let clock = ManualClock()
        let check = StabilityCheck(fileSystem: GrowingFileSystem(clock: clock, settlesAfter: 6), clock: clock)
        guard case .failure(let error) = await check.waitUntilStable(url) else {
            Issue.record("expected SSP-IO-002")
            return
        }
        #expect(error.code == .sspIo002)
        #expect(clock.now().timeIntervalSince(Date(timeIntervalSince1970: 1_800_000_000)) == 5)
    }

    @Test("FR-002-07 a file that vanishes mid-check is SSP-IO-002")
    func vanishes() async {
        let clock = ManualClock()
        let check = StabilityCheck(
            fileSystem: GrowingFileSystem(clock: clock, settlesAfter: 6, vanishesAfter: 1), clock: clock)
        guard case .failure(let error) = await check.waitUntilStable(url) else {
            Issue.record("expected SSP-IO-002")
            return
        }
        #expect(error.code == .sspIo002)
    }
}
