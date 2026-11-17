import CoreGraphics
import Foundation
import GRDB
import ImageIO
import Testing
import FlotsamBase
@testable import FlotsamStorage

// FRD-007 8T remediation, Worf B: the ingest, blob, folder, database and image survivors of the 8V gate
// (M19, M21, M27, M30, M32, M39). Each test names the one code change that turns it red. Arrangement comes from
// IngestSupport.swift and DestructiveFixture.swift; results are read back through a separate connection or the disk.

// MARK: Ingest dedupe picks the newest of several rows sharing a contentKey

@Suite struct IngestDedupeEdgeTests {
    /// OC-7028, OC-7015. Given three rows that share one contentKey (an edited copy may duplicate the key, FRD-004), made
    /// in the order middle, newest, oldest, when the same content is copied again, then the NEWEST row is the one bumped
    /// (copyCount 1 to 2, lastCopiedAt moves to the copy time), the other two are untouched and the row count is still 3.
    /// Goes red if the lookup orders oldest-first (bumps the oldest) or has no order (bumps the first inserted, the
    /// middle one).
    @Test("OC-7028 a repeated copy bumps the newest of several same-key rows")
    func oc7028_bumpsNewestOfSeveralSameKeyRows() async throws {
        let rig = try await Rig.make()
        defer { rig.cleanUp() }
        let base: Int64 = 1_700_000_000_000
        let middle = try await rig.create(rig.text("K-mid", "same words", at: base + 2_000))
        let newest = try await rig.create(rig.text("K-new", "same words", at: base + 3_000))
        let oldest = try await rig.create(rig.text("K-old", "same words", at: base + 1_000))
        try await rig.store.database.pool.write { db in
            try db.execute(sql: "UPDATE item SET contentKey = 'SHARED' WHERE contentKey LIKE 'K-%'")
        }
        let sharing = try await rig.store.reader().read {
            try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM item WHERE contentKey = 'SHARED'")!
        }
        #expect(sharing == 3)

        let result = try await rig.ingest.ingest(rig.text("SHARED", "same words", at: base + 9_000)).get()

        #expect(result.outcome == .bumped(newest))
        #expect(try rig.itemCount() == 3)
        let newestRow = try rig.row(newest)
        #expect(newestRow.copyCount == 2)
        #expect(newestRow.lastCopiedAt == base + 9_000)
        let middleRow = try rig.row(middle)
        #expect(middleRow.copyCount == 1)
        #expect(middleRow.lastCopiedAt == base + 2_000)
        let oldestRow = try rig.row(oldest)
        #expect(oldestRow.copyCount == 1)
        #expect(oldestRow.lastCopiedAt == base + 1_000)
    }

    /// OC-7028 (single-row control). Given exactly one row with the key, when the content is copied again, then that row
    /// is bumped and no row is added. Pins the plain case next to the several-row case above.
    @Test("OC-7028 a repeated copy of a unique key bumps that row and adds none")
    func oc7028_singleRowIsBumped() async throws {
        let rig = try await Rig.make()
        defer { rig.cleanUp() }
        let base: Int64 = 1_700_000_000_000
        let only = try await rig.create(rig.text("K-only", "just one", at: base))
        let other = try await rig.create(rig.text("K-other", "different", at: base + 500))

        let result = try await rig.ingest.ingest(rig.text("K-only", "just one", at: base + 4_000)).get()

        #expect(result.outcome == .bumped(only))
        #expect(try rig.itemCount() == 2)
        #expect(try rig.row(only).copyCount == 2)
        #expect(try rig.row(only).lastCopiedAt == base + 4_000)
        #expect(try rig.row(other).copyCount == 1)
    }
}

// MARK: Reconcile and the generated-file-name test

@Suite struct ReconcileFileNameEdgeTests {
    /// OC-7113, OC-7114. Given old unreferenced files in a blob shard named `<uuid>.bak`, `<uuid>.` and `<uuid>.1x`
    /// (a UUID with a non-integer extension, which Flotsam never writes) plus one genuine orphan `<uuid>.2`, when
    /// reconcile runs, then only the genuine orphan is removed (count 1) and every foreign name survives with its bytes.
    /// Goes red if the ordinal test accepts any text after the dot (`Int(parts[1]) != nil` made always true).
    @Test("OC-7114 reconcile never deletes a uuid file whose extension is not an integer")
    func oc7114_nonIntegerExtensionSurvives() async throws {
        let s = try await Store.make()
        defer { s.cleanUp() }
        try await s.insert(Spec(n: 1, ageMs: hourMs, blobs: 1, repBytes: 10))
        let old = 3 * hourMs
        let shard = "blobs/00"
        let foreign = [
            try s.plant("\(shard)/\(Store.id(210).uuidString).bak", ageMs: old),
            try s.plant("\(shard)/\(Store.id(211).uuidString).", ageMs: old),
            try s.plant("\(shard)/\(Store.id(212).uuidString).1x", ageMs: old),
        ]
        let genuine = try s.plantOrphanBlob(213, ordinal: 2, ageMs: old)

        let outcome = try await s.database.reconcile().get()

        #expect(outcome.orphanBlobsRemoved == 1)
        #expect(!s.exists(genuine))
        #expect(foreign.allSatisfy { s.exists($0) })
        #expect(foreign.allSatisfy { s.contents($0) == "foreign" })
        #expect(s.exists(s.blobURL(1, 1)))
        #expect(try s.presentIds() == [1])
    }
}

// MARK: Pre-migration pruning and the WAL-resident copy

@Suite struct PreMigrationEdgeTests {
    private let addProbe = Migration(version: 2) { db in try db.execute(sql: "CREATE TABLE probe (id INTEGER)") }

    private func tempRoot() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("flotsam-8t-edge-\(UUID().uuidString)")
    }

    /// OC-7137. Given names with no digits between `flotsam-v` and `.sqlite` (and the -wal and -shm forms of them) in
    /// pre-migration/, plus an older Flotsam-named copy, when a migration copy is taken, then the older copy is pruned,
    /// the digit-less names survive with their bytes, and the folder holds exactly the new copy plus those names.
    /// Goes red if the name test starts accepting an empty version number (the empty string must not count as an int).
    @Test("OC-7137 pruning never deletes a flotsam-v.sqlite with no version digits")
    func oc7137_digitlessNamesSurviveMigrationPruning() async throws {
        let root = tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let first = try await Store.make(root: root)
        try await first.insert((1...3).map { Spec(n: $0, ageMs: hourMs) })
        let folder = root.appendingPathComponent("pre-migration")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let pruned = ["flotsam-v0.sqlite", "flotsam-v0.sqlite-wal"]
        let digitless = ["flotsam-v.sqlite", "flotsam-v.sqlite-wal", "flotsam-v.sqlite-shm"]
        for name in pruned + digitless { try Data(name.utf8).write(to: folder.appendingPathComponent(name)) }

        _ = try await FlotsamDatabase.open(
            folder: root, fileSystem: LocalFileSystem(), migrations: Migrations.all + [addProbe]).get()

        let remaining = Set(try FileManager.default.contentsOfDirectory(atPath: folder.path))
        #expect(remaining == Set(["flotsam-v1.sqlite"] + digitless))
        #expect(digitless.allSatisfy { (try? String(contentsOf: folder.appendingPathComponent($0), encoding: .utf8)) == $0 })
    }

    /// OC-7137 at the name test itself. Given Flotsam's own copy names and digit-less look-alikes, when each is asked
    /// whether it is a pre-migration copy, then only `flotsam-v<digits>.sqlite` and its -wal/-shm forms are.
    @Test("OC-7137 name test accepts flotsam-v<int>.sqlite[-wal|-shm] and nothing else", arguments: [
        ("flotsam-v0.sqlite", true), ("flotsam-v12.sqlite", true), ("flotsam-v3.sqlite-wal", true),
        ("flotsam-v3.sqlite-shm", true),
        ("flotsam-v.sqlite", false), ("flotsam-v.sqlite-wal", false), ("flotsam-v.sqlite-shm", false),
        ("flotsam-v1.sqlite.bak", false), ("flotsam-vx.sqlite", false), ("flotsam-v-1.sqlite", false),
    ])
    func oc7137_nameTest(name: String, expected: Bool) {
        #expect(DataFolder.isPreMigrationCopyFile(named: name) == expected)
    }

    private func readOnlyCopy(of url: URL) throws -> (version: Int, tableCount: Int, itemIds: Set<Int>) {
        // A private copy of the file alone (no -wal), so what is read is exactly what is inside that one file.
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("flotsam-8t-edge-snap-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }
        let copy = scratch.appendingPathComponent("only.sqlite")
        try FileManager.default.copyItem(at: url, to: copy)
        let queue = try DatabaseQueue(path: copy.path)
        return try queue.read { db in
            let version = try Int.fetchOne(db, sql: "PRAGMA user_version") ?? -1
            let tables = try String.fetchAll(db, sql: "SELECT name FROM sqlite_master WHERE type = 'table'")
            let ids = tables.contains("item") ? try String.fetchAll(db, sql: "SELECT id FROM item") : []
            return (version, tables.count, Set(ids.map { Int(String($0.suffix(12)))! }))
        }
    }

    /// OC-7134. Given a version-1 database whose three committed items are still only in `flotsam.sqlite-wal` (the app
    /// was killed before a checkpoint), when a release adds migration 2 and the database opens, then
    /// pre-migration/flotsam-v1.sqlite on its own holds all three items at user_version 1, and the live database still
    /// has the three items at version 2. The fixture is proven WAL-resident: the main file alone does not hold the items.
    /// Goes red if the copy is taken without first checkpointing the WAL into the main file (the copy would be missing
    /// every row that lives only in the WAL).
    @Test("OC-7134 the pre-migration copy contains committed rows that were still only in the WAL")
    func oc7134_copyIncludesWalResidentRows() async throws {
        let source = tempRoot()
        let destination = tempRoot()
        defer {
            try? FileManager.default.removeItem(at: source)
            try? FileManager.default.removeItem(at: destination)
        }
        let live = try await Store.make(root: source)
        try await live.insert((1...3).map { Spec(n: $0, ageMs: hourMs) })
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        let sourceWal = source.appendingPathComponent("flotsam.sqlite-wal")
        // Copy the files as a killed app would have left them: main file plus WAL, taken while the writer is still open.
        try withExtendedLifetime(live) {
            let walBytes = (try? FileManager.default.attributesOfItem(atPath: sourceWal.path)[.size] as? Int) ?? 0
            #expect(walBytes > 0)
            for suffix in ["", "-wal"] {
                try FileManager.default.copyItem(
                    at: source.appendingPathComponent("flotsam.sqlite" + suffix),
                    to: destination.appendingPathComponent("flotsam.sqlite" + suffix))
            }
        }
        let mainOnly = try readOnlyCopy(of: destination.appendingPathComponent("flotsam.sqlite"))
        try #require(mainOnly.itemIds != [1, 2, 3], "fixture is not WAL-resident: the main file already holds the items")

        let upgraded = try await FlotsamDatabase.open(
            folder: destination, fileSystem: LocalFileSystem(), migrations: Migrations.all + [addProbe]).get()

        let copy = try readOnlyCopy(of: destination.appendingPathComponent("pre-migration/flotsam-v1.sqlite"))
        #expect(copy.version == 1)
        #expect(copy.itemIds == [1, 2, 3])
        let diagnostics = try await upgraded.diagnostics().get()
        #expect(diagnostics.userVersion == 2)
        let liveStore = Store(root: destination, clock: ManualClock(), database: upgraded)
        #expect(try liveStore.presentIds() == [1, 2, 3])
    }
}

// MARK: Image pipeline edges

@Suite struct ImagePipelineEdgeTests {
    // MARK: Complete-JPEG check

    private func validJPEG() -> Data { TestImage.encode(TestImage.makeCGImage(width: 256, height: 171), as: .jpeg) }

    /// Offset of the start-of-scan marker (FF DA), where the entropy-coded data begins.
    private func startOfScan(_ bytes: [UInt8]) -> Int {
        (0..<(bytes.count - 1)).first { bytes[$0] == 0xFF && bytes[$0 + 1] == 0xDA } ?? 0
    }

    private func randomBytes(_ count: Int, seed: UInt64) -> [UInt8] {
        var state = seed
        return (0..<count).map { _ in
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return UInt8(truncatingIfNeeded: state >> 33) & 0xFE  // never 0xFF, so no stray marker
        }
    }

    enum Damage: String, CaseIterable, Sendable {
        case cutInsideHeaderThenEndMarker, headerBytesCorruptEndMarkerIntact, startMarkerRandomBodyEndMarker
    }

    /// OC-7044. Given a JPEG that still starts with the start marker and still ends with the end marker (FF D9) but is
    /// cut inside its header, has its header tables corrupted, or is random bytes between the two markers, when it is
    /// checked as a thumbnail file, then it is rejected. Goes red if the decode check is dropped and the end-marker
    /// check alone is trusted. (A JPEG cut inside its entropy data and given a closing FF D9 DOES decode in ImageIO, as
    /// a partial picture, so that shape is not asserted here.)
    @Test("OC-7044 a JPEG with an end marker but a broken body is not a complete JPEG", arguments: Damage.allCases)
    func oc7044_endMarkerWithBrokenBodyIsRejected(_ damage: Damage) async {
        let valid = [UInt8](validJPEG())
        var damaged: [UInt8]
        switch damage {
        case .cutInsideHeaderThenEndMarker:
            damaged = Array(valid.prefix(200)) + [0xFF, 0xD9]
        case .headerBytesCorruptEndMarkerIntact:
            damaged = valid
            let scan = startOfScan(valid)
            for index in stride(from: 4, to: scan, by: 7) { damaged[index] = 0 }
        case .startMarkerRandomBodyEndMarker:
            damaged = [0xFF, 0xD8, 0xFF, 0xE0] + randomBytes(500, seed: 7) + [0xFF, 0xD9]
        }
        #expect(damaged.suffix(2) == [0xFF, 0xD9], "fixture must keep its end marker")

        let accepted = await ImageWorker().isCompleteJPEG(Data(damaged))

        #expect(accepted == false)
    }

    /// OC-7044 (controls). Given a valid JPEG, the same JPEG without its last two bytes, and an empty file, when each is
    /// checked, then only the intact JPEG is accepted. Pins the accept side so a check that rejects everything also fails.
    @Test("OC-7044 only an intact JPEG is a complete JPEG")
    func oc7044_intactJPEGIsAcceptedAndMissingEndMarkerRejected() async {
        let valid = validJPEG()
        let worker = ImageWorker()

        #expect(await worker.isCompleteJPEG(valid) == true)
        #expect(await worker.isCompleteJPEG(valid.dropLast(2)) == false)
        #expect(await worker.isCompleteJPEG(Data()) == false)
        #expect(await worker.isCompleteJPEG(TestImage.make(width: 64, height: 64, format: .png)) == false)
    }

    /// OC-7044 end to end. Given an image item whose 256 thumbnail file was replaced by an end-marked but broken JPEG,
    /// when a fresh database instance is asked for the thumbnail, then the broken bytes are not served and a valid
    /// 256-wide JPEG is, and the file on disk is valid again.
    @Test("OC-7044 a thumbnail file with an end marker but a broken body is regenerated")
    func oc7044_brokenThumbnailFileIsRegenerated() async throws {
        let rig = try await Rig.make()
        defer { rig.cleanUp() }
        let id = try await rig.create(rig.image("img", TestImage.make(width: 1200, height: 800, format: .png)))
        let url = rig.store.thumbsDir.appendingPathComponent("\(id.uuidString)-256.jpg")
        let warmed = await waitUntil { rig.store.exists(url) }
        try #require(warmed, "warm-up never wrote the thumbnail")
        let valid = try Data(contentsOf: url)
        let broken = valid.prefix(200) + Data([0xFF, 0xD9])
        try broken.write(to: url)
        let fresh = try await FlotsamDatabase.open(
            folder: rig.store.root, fileSystem: LocalFileSystem(), clock: rig.store.clock).get()

        let served = await fresh.thumbnail(itemId: id, size: .grid)

        #expect(served != broken)
        let info = served.flatMap(TestImage.inspect)
        #expect(info?.type == "public.jpeg")
        #expect(info?.width == 256)
        let onDisk = try Data(contentsOf: url)
        #expect(onDisk != broken)
        #expect(TestImage.inspect(onDisk)?.width == 256)
        #expect(try rig.itemCount() == 1)
    }

    // MARK: Stored JPEG quality

    /// Deterministic noise, so JPEG size moves clearly with quality (a flat picture is nearly the same size at every
    /// quality).
    private func noisePNG(width: Int, height: Int) -> Data {
        let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        let pixels = context.data!.assumingMemoryBound(to: UInt8.self)
        var state: UInt64 = 42
        for row in 0..<height {
            for column in 0..<width {
                let offset = row * context.bytesPerRow + column * 4
                for channel in 0..<3 {
                    state = state &* 6364136223846793005 &+ 1442695040888963407
                    pixels[offset + channel] = UInt8(truncatingIfNeeded: state >> 56)
                }
                pixels[offset + 3] = 255
            }
        }
        return TestImage.encode(context.makeImage()!, as: .png)
    }

    /// An independent encode of `png`'s pixels as JPEG at `quality`, straight through ImageIO.
    private func referenceJPEGSize(of png: Data, quality: Double) -> Int {
        let source = CGImageSourceCreateWithData(png as CFData, nil)!
        let image = CGImageSourceCreateImageAtIndex(source, 0, nil)!
        let output = NSMutableData()
        let destination = CGImageDestinationCreateWithData(output, "public.jpeg" as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        precondition(CGImageDestinationFinalize(destination))
        return output.length
    }

    /// OC-7048. Given the Efficient preset and an opaque noisy PNG, when it is copied, then the stored blob is a JPEG whose
    /// size is within 2% of the same pixels encoded at quality 0.85, and the neighbouring qualities 0.80 and 0.90 would
    /// each be more than 4% away (checked first, so the comparison can tell them apart). Goes red if the stored quality
    /// constant changes from 0.85 to anything the size can distinguish (0.3, 0.80, 0.90).
    @Test("OC-7048 the stored JPEG is encoded at quality 0.85")
    func oc7048_storedJPEGQualityIsPointEightFive() async throws {
        let rig = try await Rig.make(quality: .efficient)
        defer { rig.cleanUp() }
        let png = noisePNG(width: 640, height: 480)
        let at85 = referenceJPEGSize(of: png, quality: 0.85)
        let at80 = referenceJPEGSize(of: png, quality: 0.80)
        let at90 = referenceJPEGSize(of: png, quality: 0.90)
        try #require(abs(Double(at80 - at85)) / Double(at85) > 0.04, "fixture cannot tell 0.80 from 0.85")
        try #require(abs(Double(at90 - at85)) / Double(at85) > 0.04, "fixture cannot tell 0.90 from 0.85")

        let id = try await rig.create(rig.image("noise", png))

        let rep = try #require(try rig.reps(id).first)
        let blob = try #require(rig.blobData(rep))
        let info = TestImage.inspect(blob)
        #expect(info?.type == "public.jpeg")
        #expect(info?.width == 640)
        #expect(info?.height == 480)
        let deviation = abs(Double(blob.count - at85)) / Double(at85)
        #expect(deviation <= 0.02, "stored \(blob.count) bytes vs \(at85) at 0.85")
        #expect(try rig.reps(id).count == 1)
        #expect(try rig.itemCount() == 1)
    }
}

extension TestImage {
    /// The CGImage behind `make`'s blue-field picture, for tests that encode it themselves.
    static func makeCGImage(width: Int, height: Int) -> CGImage {
        CGImageSourceCreateImageAtIndex(CGImageSourceCreateWithData(make(width: width, height: height, format: .png) as CFData, nil)!, 0, nil)!
    }
}
