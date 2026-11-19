import FlotsamBase
import Foundation
import Testing
@testable import FlotsamScreenshots
@testable import FlotsamStorage

// TASK-218 (OC-2037/2038/2040, FR-002-08) and TASK-219 (FR-002-09, AC-002-08), against the real ingest pipeline and a
// real database. Persistence is always read back through a FRESH database handle (`rig.relaunch()`).
//
// UNTESTABLE-AT-PACKAGE: the ⌘⌫ keystroke of OC-2038 (a Library UI path). Seam: `FlotsamDatabase.delete(ids:)`, the
// only deletion path (FR-007-15), which the UI calls.
// UNTESTABLE-AT-PACKAGE: "Flotsam is quit" as a process exit. Seam: `RealIngestRig.relaunch()` (new database handle,
// new watcher, same data folder and watched folder).

private let screenshotKind = "screenshot"

private func paths(_ urls: [URL]) -> Set<String> { Set(urls.map(\.path)) }

/// All stored `originalPath`s, read through the rig's current database handle.
private func storedPaths(_ rig: RealIngestRig) async throws -> Set<String> {
    var found: Set<String> = []
    for id in try await rig.itemIds() { if let path = try await rig.itemRow(id)?.originalPath { found.insert(path) } }
    return found
}

@Suite("FRD-002 gap: launch reconcile (TASK-218)")
struct LaunchReconcileGapTests {
    /// A rig whose watermark is 100 s before "now", with the clock then moved on so files born "before launch" are
    /// strictly after the watermark and strictly before the launch.
    private func makeRig() async throws -> (rig: RealIngestRig, mark: Date) {
        let mark = Date().addingTimeInterval(-100)
        return (try await RealIngestRig.make(watermark: mark), mark)
    }

    @Test("TASK-218 OC-2037: three screenshots added while Flotsam was quit appear on launch, count +3, exactly those")
    func threeNewShotsImportedOnLaunch() async throws {
        // given a watermark, 3 qualifying files born after it, and 1 born before it
        let (rig, mark) = try await makeRig()
        defer { rig.cleanUp() }
        let fresh = try (0..<3).map { _ in try rig.shot(in: rig.desktop, born: mark.addingTimeInterval(30)).url }
        let old = try rig.shot(in: rig.desktop, born: mark.addingTimeInterval(-60)).url
        #expect(try await rig.itemCount() == 0)
        // when Flotsam launches
        try await rig.relaunch()
        await rig.watcher.start()
        // then exactly the 3 newer files are items, the older one is not
        #expect(await rig.waitForItems(3))
        await letItSettle()
        #expect(try await rig.itemCount() == 3, "count delta +3, no more")
        let stored = try await storedPaths(rig)
        #expect(stored == paths(fresh))
        #expect(!stored.contains(old.path))
    }

    @Test("TASK-218 OC-2038: a screenshot deleted from history stays absent after relaunch on a fresh database; the file stays on disk")
    func deletedShotStaysDeletedAfterRelaunch() async throws {
        // given 3 imported screenshots
        let (rig, mark) = try await makeRig()
        defer { rig.cleanUp() }
        let urls = try (0..<3).map { _ in try rig.shot(in: rig.desktop, born: mark.addingTimeInterval(30)).url }
        rig.clock.advance(by: 60)
        await rig.watcher.start()
        #expect(await rig.waitForItems(3))
        let ids = try await rig.itemIds()
        var byPath: [String: UUID] = [:]
        for id in ids { if let path = try await rig.itemRow(id)?.originalPath { byPath[path] = id } }
        let victim = urls[1]
        let victimId = try #require(byPath[victim.path])
        // when one is deleted, then Flotsam relaunches
        #expect(try await rig.database.delete(ids: [victimId]).get() == [victimId])
        #expect(try await rig.itemCount() == 2)
        try await rig.relaunch()
        rig.clock.advance(by: 60)
        await rig.watcher.start()
        await letItSettle()
        // then the count is unchanged (2), the deleted one is absent, the survivors keep their identity, the file remains
        let after = try await rig.itemCount()
        let afterIds = try await rig.itemIds()
        let afterPaths = try await storedPaths(rig)
        #expect(after == 2, "count after relaunch equals count after delete")
        #expect(!afterPaths.contains(victim.path))
        #expect(afterIds.isSuperset(of: ids.subtracting([victimId])), "the two survivors keep their identity")
        #expect(FileManager.default.fileExists(atPath: victim.path), "the original file is still on disk")
    }

    @Test("TASK-218 OC-2040: twenty imported, relaunch with no new files adds nothing (watermark persisted)")
    func twentyImportedRelaunchAddsNothing() async throws {
        // given 20 imported screenshots
        let (rig, mark) = try await makeRig()
        defer { rig.cleanUp() }
        for _ in 0..<20 { try rig.shot(in: rig.desktop, born: mark.addingTimeInterval(30)) }
        rig.clock.advance(by: 60)
        await rig.watcher.start()
        #expect(await rig.waitForItems(20))
        let before = try await rig.itemIds()
        let mark1 = try #require(try await rig.watermark())
        let copiesBefore = try await rig.copyCounts()
        #expect(copiesBefore.count == 20 && copiesBefore.values.allSatisfy { $0 == 1 })
        #expect(mark1 > mark, "the launch advanced the persisted watermark")
        // when Flotsam relaunches with no new files
        // TASK-501 (OC-2040 flake): a relaunch is a new process, so the first launch has to be gone first. Its last imports
        // are still settling at this point, and a settle reads the clock when it runs: one that ran after the clock step
        // below wrote the later time over the watermark under test (the persisted value was then 60 s past mark1).
        // Switching pickup off ends the first launch (its settles stop at the `active` guard); it is back on for the next.
        rig.settings.set(false, for: SettingKeys.screenshotsEnabled)
        await rig.watcher.settingsDidChange()
        rig.settings.set(true, for: SettingKeys.screenshotsEnabled)
        try await rig.relaunch()
        rig.clock.advance(by: 60)
        #expect(try await rig.watermark() == mark1, "the fresh handle reads back the watermark the first launch persisted")
        await rig.watcher.start()
        await letItSettle()
        // then the count and identities are unchanged, and no file was even re-detected (no copyCount bump)
        #expect(try await rig.itemCount() == 20)
        #expect(try await rig.itemIds() == before)
        #expect(try await rig.copyCounts() == copiesBefore, "a re-scan would bump copyCount through dedupe")
    }

    @Test("TASK-218 FR-002-08: a new library imports nothing at first launch and only seeds the watermark; the next shot imports")
    func firstLaunchSeedsWatermarkOnly() async throws {
        // given no watermark and 2 screenshots already in the folder
        let rig = try await RealIngestRig.make(watermark: nil)
        defer { rig.cleanUp() }
        try rig.shot(in: rig.desktop, born: rig.clock.now().addingTimeInterval(-20))
        try rig.shot(in: rig.desktop, born: rig.clock.now().addingTimeInterval(-5))
        #expect(try await rig.watermark() == nil)
        // when Flotsam launches
        await rig.watcher.start()
        await letItSettle()
        // then nothing is imported
        #expect(try await rig.itemCount() == 0)
        // and liveness: a shot taken after launch is picked up
        rig.clock.advance(by: 10)
        let later = try rig.shot(in: rig.desktop).url
        rig.event(later)
        #expect(await rig.waitForItems(1))
        #expect(try await storedPaths(rig) == [later.path])
        // and the watermark was persisted, visible to a fresh handle that still holds only the one item
        try await rig.relaunch()
        #expect(try await rig.watermark() != nil)
        #expect(try await rig.itemCount() == 1)
    }
}

@Suite("FRD-002 gap: stored copy of an imported screenshot (TASK-219)")
struct StoredCopyGapTests {
    private struct Imported { let rig: RealIngestRig; let id: UUID; let url: URL; let image: GapImage; let born: Date }

    private func importOne() async throws -> Imported {
        let mark = Date().addingTimeInterval(-100)
        let rig = try await RealIngestRig.make(watermark: mark)
        let born = Date(timeIntervalSince1970: (mark.timeIntervalSince1970 + 30).rounded())
        let shot = try rig.shot(in: rig.desktop, born: born)
        rig.clock.advance(by: 60)
        await rig.watcher.start()
        guard await rig.waitForItems(1), let id = try await rig.itemIds().first else {
            rig.cleanUp()
            throw GapSetupError.noItem
        }
        return Imported(rig: rig, id: id, url: shot.url, image: shot.image, born: born)
    }

    private enum GapSetupError: Error { case noItem }

    private func inode(_ url: URL) throws -> Int {
        (try FileManager.default.attributesOfItem(atPath: url.path)[.systemFileNumber] as? Int) ?? -1
    }

    @Test("TASK-219 FR-002-09: an imported screenshot is kind screenshot, source Screenshot, original path and birth date recorded")
    func rowFacts() async throws {
        // given a screenshot born at a known second, imported by the real pipeline
        let shot = try await importOne()
        defer { shot.rig.cleanUp() }
        // when the item row is read back
        let row = try #require(try await shot.rig.itemRow(shot.id))
        // then it carries the screenshot facts
        #expect(row.kind == screenshotKind)
        #expect(row.sourceName == "Screenshot")
        #expect(row.sourceBundleId == "com.apple.screencaptureui")
        #expect(row.originalPath == shot.url.path)
        #expect(row.createdAtMillis == Int64(shot.born.timeIntervalSince1970) * 1000, "item date is the file's birth date")
        #expect(row.pixelWidth == 16 && row.pixelHeight == 12)
    }

    @Test("TASK-219 AC-002-08: the item owns a blob under the data folder, a separate file from the original (own path, own inode)")
    func blobIsSeparateCopy() async throws {
        // given an imported screenshot
        let shot = try await importOne()
        defer { shot.rig.cleanUp() }
        // when the blob files of the item are listed
        let blobs = try await shot.rig.blobURLs(of: shot.id)
        // then one blob exists at blobs/<first two of id>/<id>.<n>, distinct from the original, not a hard link
        let blob = try #require(blobs.first)
        #expect(blobs.count == 1)
        let relative = blob.path.replacingOccurrences(of: shot.rig.dataFolder.appendingPathComponent("blobs").path + "/", with: "")
        let id = shot.id.uuidString
        #expect(relative.hasPrefix("\(id.prefix(2))/\(id)."), "blobs/<first two of itemId>/<itemId>.<n>, got \(relative)")
        #expect(Int(relative.split(separator: ".").last ?? "") != nil)
        #expect(blob.path != shot.url.path)
        #expect(try inode(blob) != inode(shot.url))
        #expect(try FileManager.default.attributesOfItem(atPath: shot.url.path)[.referenceCount] as? Int == 1, "the original has no second link")
        #expect(FileManager.default.fileExists(atPath: blob.path))
    }

    @Test("TASK-219 AC-002-08: the blob survives the original being overwritten, then deleted; content and size unchanged")
    func blobSurvivesOriginalChange() async throws {
        // given an imported screenshot whose stored bytes decode to its pixel size
        let shot = try await importOne()
        defer { shot.rig.cleanUp() }
        let blob = try #require(try await shot.rig.blobURLs(of: shot.id).first)
        let stored = try Data(contentsOf: blob)
        let size = try #require(GapImage.pixelSize(of: stored))
        #expect(size.width == 16 && size.height == 12)
        // when the original is overwritten in place with other bytes
        try Data("overwritten".utf8).write(to: shot.url)
        // then the blob bytes are unchanged
        #expect(try Data(contentsOf: blob) == stored)
        // when the original is then deleted
        try FileManager.default.removeItem(at: shot.url)
        // then the blob and the item are still there with the same bytes, read through a fresh handle
        try await shot.rig.relaunch()
        #expect(try await shot.rig.itemCount() == 1)
        #expect(try Data(contentsOf: blob) == stored)
        #expect(try await shot.rig.blobURLs(of: shot.id) == [blob])
    }
}
