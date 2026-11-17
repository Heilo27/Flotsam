import Foundation
import Testing
import FlotsamBase
@testable import FlotsamStorage

// FRD-007 8T batch 2, the image pipeline and quality presets (FR-007-07, FR-007-08). Every test ingests through the
// real IngestActor and reads the stored blob back from disk and the row through a separate connection, so the
// asserted format and size are what the Library would later decode, not what the worker claimed to produce.

@Suite struct ImagePolicyTests {
    /// What ended up stored for one ingested image.
    private struct Stored {
        let row: Rig.ItemRow
        let rep: Rig.RepRow
        let blob: Data
        let info: TestImage.Info
    }

    private func ingest(_ rig: Rig, _ data: Data, uti: String = "public.png", key: String = "img") async throws -> (id: UUID, stored: Stored) {
        let id = try await rig.create(rig.image(key, data, uti: uti))
        return (id, try stored(rig, id))
    }

    private func stored(_ rig: Rig, _ id: UUID) throws -> Stored {
        let reps = try rig.reps(id)
        let rep = try #require(reps.first)
        let blob = try #require(rig.blobData(rep))
        return Stored(row: try rig.row(id), rep: rep, blob: blob, info: try #require(TestImage.inspect(blob)))
    }

    /// The invariant every case below also checks: the row's pixel size and the representation's byte size describe
    /// the blob that is actually on disk (FR-007-07 step 2).
    private func expectConsistent(_ s: Stored) {
        #expect(s.row.pixelWidth == s.info.width)
        #expect(s.row.pixelHeight == s.info.height)
        #expect(s.rep.byteSize == Int64(s.blob.count))
        #expect(s.rep.uti == s.info.type)
    }

    // MARK: Presets on a 5120x2880 opaque PNG

    /// OC-7048. Given Efficient and a 5120x2880 opaque PNG, when it is ingested, then the stored blob is a JPEG at
    /// 2560x1440 and the row says 2560x1440.
    @Test("OC-7048 Efficient downscales an opaque PNG to a 2560x1440 JPEG")
    func oc7048_efficientOpaquePNG() async throws {
        let rig = try await Rig.make(quality: .efficient)
        defer { rig.cleanUp() }

        let (_, s) = try await ingest(rig, TestImage.make(width: 5120, height: 2880, format: .png))

        #expect(s.info == TestImage.Info(type: "public.jpeg", width: 2560, height: 1440))
        #expect(s.row.pixelWidth == 2560)
        #expect(s.row.pixelHeight == 1440)
        expectConsistent(s)
    }

    /// OC-7049. Given Balanced and a 5120x2880 opaque PNG, then the stored blob is a JPEG at 3840x2160.
    @Test("OC-7049 Balanced downscales an opaque PNG to a 3840x2160 JPEG")
    func oc7049_balancedOpaquePNG() async throws {
        let rig = try await Rig.make(quality: .balanced)
        defer { rig.cleanUp() }

        let (_, s) = try await ingest(rig, TestImage.make(width: 5120, height: 2880, format: .png))

        #expect(s.info == TestImage.Info(type: "public.jpeg", width: 3840, height: 2160))
        expectConsistent(s)
    }

    /// OC-7050. Given Original and a 5120x2880 PNG, then the stored blob is byte-identical to the copied bytes.
    @Test("OC-7050 Original stores the copied bytes unchanged")
    func oc7050_originalIsByteIdentical() async throws {
        let rig = try await Rig.make(quality: .original)
        defer { rig.cleanUp() }
        let source = TestImage.make(width: 5120, height: 2880, format: .png)

        let (_, s) = try await ingest(rig, source)

        #expect(s.blob == source)
        #expect(s.info == TestImage.Info(type: "public.png", width: 5120, height: 2880))
        expectConsistent(s)
    }

    /// OC-7051. Given Efficient, when a 5120x2880 PNG with transparency is ingested it stays a PNG at 2560x1440 and
    /// keeps its transparent pixels; when a 5120x2880 JPEG is ingested it stays a JPEG at 2560x1440.
    @Test("OC-7051 Efficient keeps transparent PNG as PNG and JPEG as JPEG, both downscaled")
    func oc7051_efficientTransparentAndJPEG() async throws {
        let rig = try await Rig.make(quality: .efficient)
        defer { rig.cleanUp() }

        let (pngId, png) = try await ingest(rig, TestImage.make(width: 5120, height: 2880, format: .png, transparent: true), key: "png")
        let (jpegId, jpeg) = try await ingest(rig, TestImage.make(width: 5120, height: 2880, format: .jpeg), uti: "public.jpeg", key: "jpeg")

        #expect(png.info == TestImage.Info(type: "public.png", width: 2560, height: 1440))
        #expect(TestImage.hasTransparentPixel(png.blob))
        #expect(jpeg.info == TestImage.Info(type: "public.jpeg", width: 2560, height: 1440))
        #expect(pngId != jpegId)
        #expect(try rig.itemCount() == 2)
        expectConsistent(png)
        expectConsistent(jpeg)
    }

    // MARK: Efficient without a downscale (FR-007-08)

    /// OC-7052, per FRD-007 Decision 5 and FR-007-08: Efficient converts an opaque PNG to JPEG even when it is already
    /// under the ceiling. Given Efficient and a 2000x1000 opaque PNG, then the blob is a JPEG at 2000x1000.
    ///
    /// The oracle text for 7052 says "byte-identical". That contradicts the FRD, which the implementation follows, so
    /// this test asserts the FRD. Reported as an oracle/FRD conflict, not silently resolved.
    @Test("OC-7052 Efficient sends an opaque PNG to JPEG even without a downscale (FRD-007 Decision 5)")
    func oc7052_efficientOpaqueWithoutDownscale() async throws {
        let rig = try await Rig.make(quality: .efficient)
        defer { rig.cleanUp() }

        let (_, s) = try await ingest(rig, TestImage.make(width: 2000, height: 1000, format: .png))

        #expect(s.info == TestImage.Info(type: "public.jpeg", width: 2000, height: 1000))
        expectConsistent(s)
    }

    /// OC-7052 (alpha half). Given Efficient and a 2000x1000 PNG with transparency, then it stays PNG byte-identical.
    @Test("OC-7052 Efficient leaves a small transparent PNG untouched")
    func oc7052_efficientTransparentWithoutDownscale() async throws {
        let rig = try await Rig.make(quality: .efficient)
        defer { rig.cleanUp() }
        let source = TestImage.make(width: 2000, height: 1000, format: .png, transparent: true)

        let (_, s) = try await ingest(rig, source)

        #expect(s.blob == source)
        #expect(s.info.type == "public.png")
        expectConsistent(s)
    }

    /// OC-7052 / FR-007-08. Given Efficient and a PNG whose alpha channel is 255 everywhere (a macOS screenshot), then
    /// it becomes a JPEG: the channel's presence is not transparency.
    @Test("FR-007-08 an opaque PNG that carries an alpha channel still becomes JPEG under Efficient")
    func oc7052_opaqueAlphaChannelBecomesJPEG() async throws {
        let rig = try await Rig.make(quality: .efficient)
        defer { rig.cleanUp() }
        let source = TestImage.make(width: 1000, height: 500, format: .png, opaqueWithAlphaChannel: true)

        let (_, s) = try await ingest(rig, source)

        #expect(s.info == TestImage.Info(type: "public.jpeg", width: 1000, height: 500))
        expectConsistent(s)
    }

    /// OC-7050 / FR-007-08. Given Balanced and a 2000x1000 opaque PNG (under the 3840 ceiling), then it is stored
    /// byte-identical as PNG: only Efficient converts without a downscale.
    @Test("FR-007-08 Balanced leaves a PNG under the ceiling untouched")
    func oc7050_balancedUnderCeilingUntouched() async throws {
        let rig = try await Rig.make(quality: .balanced)
        defer { rig.cleanUp() }
        let source = TestImage.make(width: 2000, height: 1000, format: .png)

        let (_, s) = try await ingest(rig, source)

        #expect(s.blob == source)
        #expect(s.info.type == "public.png")
        expectConsistent(s)
    }

    // MARK: Ceiling boundaries (max, max+1)

    /// OC-7049 boundary. Given Balanced, a 3840-wide PNG is under the ceiling and stays PNG byte-identical; a
    /// 3841-wide PNG is over it and becomes a JPEG exactly 3840 wide.
    @Test("OC-7049 Balanced ceiling boundary: 3840 untouched, 3841 downscaled")
    func oc7049_balancedBoundary() async throws {
        let rig = try await Rig.make(quality: .balanced)
        defer { rig.cleanUp() }
        let atCeiling = TestImage.make(width: 3840, height: 100, format: .png)

        let (_, at) = try await ingest(rig, atCeiling, key: "at")
        let (_, over) = try await ingest(rig, TestImage.make(width: 3841, height: 100, format: .png), key: "over")

        #expect(at.blob == atCeiling)
        #expect(at.info == TestImage.Info(type: "public.png", width: 3840, height: 100))
        #expect(over.info.type == "public.jpeg")
        #expect(over.info.width == 3840)
        #expect(try rig.itemCount() == 2)
        expectConsistent(at)
        expectConsistent(over)
    }

    /// OC-7048 boundary. Given Efficient, a 2560-wide JPEG is under the ceiling and stays byte-identical (a JPEG is
    /// only re-encoded when downscaled); a 2561-wide JPEG is re-encoded to exactly 2560 wide.
    @Test("OC-7048 Efficient ceiling boundary for JPEG: 2560 untouched, 2561 downscaled")
    func oc7048_efficientBoundary() async throws {
        let rig = try await Rig.make(quality: .efficient)
        defer { rig.cleanUp() }
        let atCeiling = TestImage.make(width: 2560, height: 100, format: .jpeg)

        let (_, at) = try await ingest(rig, atCeiling, uti: "public.jpeg", key: "at")
        let (_, over) = try await ingest(rig, TestImage.make(width: 2561, height: 100, format: .jpeg), uti: "public.jpeg", key: "over")

        #expect(at.blob == atCeiling)
        #expect(at.info == TestImage.Info(type: "public.jpeg", width: 2560, height: 100))
        #expect(over.info.type == "public.jpeg")
        #expect(over.info.width == 2560)
        expectConsistent(at)
        expectConsistent(over)
    }

    // MARK: TIFF

    /// OC-7042. Given Balanced and an opaque 1600x900 TIFF, when it is ingested, then a lossless PNG is stored with
    /// pixels identical to the TIFF, the row says 1600x900, and a 256 JPEG thumbnail appears within one second.
    @Test("OC-7042 a TIFF is stored as a lossless PNG with identical pixels and a prompt thumbnail")
    func oc7042_tiffBecomesPNG() async throws {
        let rig = try await Rig.make(quality: .balanced)
        defer { rig.cleanUp() }
        let tiff = TestImage.make(width: 1600, height: 900, format: .tiff)

        let (id, s) = try await ingest(rig, tiff, uti: "public.tiff")

        #expect(s.info == TestImage.Info(type: "public.png", width: 1600, height: 900))
        #expect(s.rep.uti == "public.png")
        #expect(s.row.pixelWidth == 1600)
        #expect(s.row.pixelHeight == 900)
        #expect(TestImage.rgba(s.blob) == TestImage.rgba(tiff))
        let thumb = rig.store.thumbsDir.appendingPathComponent("\(id.uuidString)-256.jpg")
        let appeared = await waitUntil(seconds: 1) { rig.store.exists(thumb) }
        #expect(appeared, "no 256 thumbnail within 1 s")
        let thumbInfo = (try? Data(contentsOf: thumb)).flatMap(TestImage.inspect)
        #expect(thumbInfo?.type == "public.jpeg")
        #expect(thumbInfo?.width == 256)
        expectConsistent(s)
    }

    /// FR-007-07 step 3 / FR-007-08. Given Efficient, an opaque TIFF becomes PNG and then the Efficient rule sends it to
    /// JPEG; a TIFF with transparency stays PNG with its transparent pixels.
    @Test("FR-007-07 TIFF goes to PNG first, then the Efficient rule applies")
    func oc7042_tiffThenEfficientRule() async throws {
        let rig = try await Rig.make(quality: .efficient)
        defer { rig.cleanUp() }

        let (_, opaque) = try await ingest(rig, TestImage.make(width: 800, height: 400, format: .tiff), uti: "public.tiff", key: "opaque")
        let (_, clear) = try await ingest(
            rig, TestImage.make(width: 800, height: 400, format: .tiff, transparent: true), uti: "public.tiff", key: "clear")

        #expect(opaque.info == TestImage.Info(type: "public.jpeg", width: 800, height: 400))
        #expect(clear.info == TestImage.Info(type: "public.png", width: 800, height: 400))
        #expect(TestImage.hasTransparentPixel(clear.blob))
        #expect(try rig.itemCount() == 2)
        expectConsistent(opaque)
        expectConsistent(clear)
    }

    // MARK: Preset changes never touch what is stored

    /// OC-7043. Given a TIFF ingested under Balanced, when the preset changes to Efficient and the same TIFF is copied
    /// again, then it is a bump of the same item (copyCount 2, still one item) and the stored blob is unchanged.
    @Test("OC-7043 the same image copied after a preset change is a bump and leaves the blob alone")
    func oc7043_bumpAfterPresetChange() async throws {
        let rig = try await Rig.make(quality: .balanced)
        defer { rig.cleanUp() }
        let tiff = TestImage.make(width: 800, height: 400, format: .tiff)
        let (id, before) = try await ingest(rig, tiff, uti: "public.tiff", key: "same")
        rig.settings.set(.efficient, for: SettingKeys.storageImageQuality)

        let again = try await rig.ingest.ingest(rig.image("same", tiff, uti: "public.tiff")).get()

        #expect(again.outcome == .bumped(id))
        #expect(try rig.itemCount() == 1)
        #expect(try rig.row(id).copyCount == 2)
        let after = try stored(rig, id)
        #expect(after.blob == before.blob)
        #expect(after.rep == before.rep)
        #expect(rig.blobFiles().count == 1)
    }

    /// OC-7053. Given an item stored under Original, when the preset changes to Efficient and another image is
    /// ingested, then the first item's blob and pixel size are exactly what they were.
    @Test("OC-7053 existing items are never re-encoded when the preset changes")
    func oc7053_existingItemsNotReencoded() async throws {
        let rig = try await Rig.make(quality: .original)
        defer { rig.cleanUp() }
        let big = TestImage.make(width: 5120, height: 2880, format: .png)
        let (firstId, before) = try await ingest(rig, big, key: "first")
        rig.settings.set(.efficient, for: SettingKeys.storageImageQuality)

        let (secondId, second) = try await ingest(rig, TestImage.make(width: 5120, height: 2880, format: .png), key: "second")

        let after = try stored(rig, firstId)
        #expect(after.blob == big)
        #expect(after.blob == before.blob)
        #expect(after.info == TestImage.Info(type: "public.png", width: 5120, height: 2880))
        #expect(after.row.pixelWidth == 5120)
        #expect(second.info.type == "public.jpeg")
        #expect(second.info.width == 2560)
        #expect(firstId != secondId)
        #expect(try rig.itemCount() == 2)
    }
}
