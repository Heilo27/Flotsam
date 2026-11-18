import Foundation
import GRDB
import Testing
import FlotsamBase
@testable import FlotsamStorage

// FRD-007 8T batch 2, the ingest pipeline (FR-007-03 to FR-007-07). Every test ingests through the real IngestActor
// and reads the result back through a separate read-only connection and the files on disk. Expected values are
// literals. Limits are driven at their exact ceiling and one byte over.
//
// Gap noted for the report: the Notice text ("10 MB", "501 files") is rendered above this layer and no formatter
// exists in this package yet, so the limit and the count are asserted where Storage hands them over: the error code
// and its `byteSize` / `count` context.

@Suite(.timeLimit(.minutes(1))) struct IngestPipelineTests {
    private let t0: Int64 = 1_700_000_000_000

    private func failure(_ result: FlotsamResult<IngestResult>) -> FlotsamError? {
        if case .failure(let error) = result { return error }
        return nil
    }

    /// Columns the shared `ItemRow` does not carry, read through the separate connection.
    private func nullables(_ rig: Rig, _ id: UUID) throws -> [String: Int64?] {
        try rig.store.reader().read { db in
            let r = try #require(try Row.fetchOne(
                db, sql: """
                    SELECT hotkeyCode, hotkeyModifiers, exemptReleasedAt, (\"trigger\" IS NULL) AS noTrigger,
                           (note IS NULL) AS noNote, (originalPath IS NULL) AS noOriginal
                    FROM item WHERE id = ?
                    """, arguments: [id.uuidString]))
            return [
                "hotkeyCode": r["hotkeyCode"], "hotkeyModifiers": r["hotkeyModifiers"], "exemptReleasedAt": r["exemptReleasedAt"],
                "noTrigger": r["noTrigger"], "noNote": r["noNote"], "noOriginal": r["noOriginal"],
            ]
        }
    }

    private func exec(_ rig: Rig, _ sql: String, _ arguments: StatementArguments = []) async throws {
        try await rig.store.database.pool.write { try $0.execute(sql: sql, arguments: arguments) }
    }

    private func utf8Length(_ rig: Rig, _ id: UUID) throws -> Int {
        try rig.store.reader().read {
            try Int.fetchOne($0, sql: "SELECT length(CAST(plainText AS BLOB)) FROM item WHERE id = ?", arguments: [id.uuidString])!
        }
    }

    // MARK: FR-007-03 row shape

    /// OC-7017. Given a known time T, when a plain text is copied, then the row carries T as UTC ms, copyCount 1,
    /// pasteCount 0, every optional column null, and no representation row.
    @Test("OC-7017 a copied plain text lands with the documented defaults and no representation")
    func oc7017_plainTextRow() async throws {
        let rig = try await Rig.make()
        defer { rig.cleanUp() }

        let id = try await rig.create(rig.text("k-7017", "hello 7017", at: t0))

        let row = try rig.row(id)
        #expect(row.kind == "text")
        #expect(row.createdAt == 1_700_000_000_000)
        #expect(row.lastCopiedAt == 1_700_000_000_000)
        #expect(row.copyCount == 1)
        #expect(row.pasteCount == 0)
        #expect(row.lastUsedAt == nil)
        #expect(row.pinned == 0)
        #expect(row.note == nil)
        #expect(row.plainText == "hello 7017")
        #expect(row.byteSize == 0)
        let n = try nullables(rig, id)
        #expect(n["hotkeyCode"] == .some(nil))
        #expect(n["hotkeyModifiers"] == .some(nil))
        #expect(n["exemptReleasedAt"] == .some(nil))
        #expect(n["noTrigger"] == 1)
        #expect(n["noNote"] == 1)
        #expect(try rig.reps(id).isEmpty)
        #expect(rig.blobFiles().isEmpty)
        #expect(try rig.itemCount() == 1)
    }

    /// OC-7018. Given an RTF clip with plain fallback then a PNG, then the RTF item has plainText and one public.rtf
    /// blob, the image has pixel size and no plainText or originalPath, and byteSize of each equals the sum of its
    /// blob files (plain text excluded) and does not change once the thumbnail exists.
    @Test("OC-7018 byteSize is the sum of blob file sizes, stable across thumbnail generation")
    func oc7018_byteSize() async throws {
        let rig = try await Rig.make()
        defer { rig.cleanUp() }
        let rtf = Data("{\\rtf1\\ansi rich body}".utf8)

        let rtfId = try await rig.create(rig.rich("k-7018-rtf", plain: "a plain fallback that is long", rtf: rtf))
        let imageId = try await rig.create(rig.image("k-7018-img", TestImage.make(width: 64, height: 48, format: .png)))

        let rtfReps = try rig.reps(rtfId)
        #expect(rtfReps.count == 1)
        #expect(rtfReps.first?.uti == "public.rtf")
        let rtfBlob = try #require(rtfReps.first.flatMap { rig.blobData($0) })
        let rtfRow = try rig.row(rtfId)
        #expect(rtfRow.plainText == "a plain fallback that is long")
        #expect(rtfRow.byteSize == Int64(rtfBlob.count))
        #expect(rtfRow.byteSize == 22)

        let imageRow = try rig.row(imageId)
        let imageReps = try rig.reps(imageId)
        let imageBlobBytes = imageReps.compactMap { rig.blobData($0)?.count }.reduce(0, +)
        #expect(imageRow.plainText == nil)
        #expect(imageRow.pixelWidth == 64)
        #expect(imageRow.pixelHeight == 48)
        #expect(try nullables(rig, imageId)["noOriginal"] == 1)
        #expect(imageRow.byteSize == Int64(imageBlobBytes))
        #expect(imageBlobBytes > 0)

        let thumbsBuilt = await rig.awaitThumbnails(imageId)
        #expect(thumbsBuilt)
        #expect(try rig.row(imageId).byteSize == imageRow.byteSize)
        #expect(try rig.row(rtfId).byteSize == rtfRow.byteSize)
    }

    // MARK: FR-007-04 blob layout

    /// OC-7020. Given an item with two rich representations, when blobs/ is listed, then exactly two files exist,
    /// both named <first two chars of id>/<id>.<n>, and nothing for this id lives elsewhere.
    @Test("OC-7020 two representations are exactly two sharded blob files")
    func oc7020_blobLayout() async throws {
        let rig = try await Rig.make()
        defer { rig.cleanUp() }
        let candidate = IngestCandidate(
            kind: .richText, contentKey: "k-7020", plainText: "two reps",
            representations: [
                PasteboardRepresentation(uti: "public.rtf", data: Data("{\\rtf1 a}".utf8)),
                PasteboardRepresentation(uti: "public.html", data: Data("<b>a</b>".utf8)),
            ],
            origin: .pasteboard, occurredAt: Date(timeIntervalSince1970: Double(t0) / 1000))
        let other = try await rig.create(rig.text("k-7020-other", "no blobs"))

        let id = try await rig.create(candidate)

        let files = rig.blobFiles()
        let prefix = String(id.uuidString.prefix(2))
        #expect(files.count == 2)
        let pattern = try Regex("^\(prefix)/\(id.uuidString)\\.[0-9]+$")
        #expect(files.allSatisfy { $0.wholeMatch(of: pattern) != nil })
        #expect(files == Set(try rig.reps(id).map(\.blobName)))
        #expect(try rig.reps(id).map(\.uti) == ["public.rtf", "public.html"])
        #expect(try rig.reps(other).isEmpty)
        // Nothing outside blobs/ belongs to this id.
        let everywhere = FileManager.default.enumerator(atPath: rig.store.root.path)?.allObjects as? [String] ?? []
        #expect(everywhere.filter { $0.contains(id.uuidString) && !$0.hasPrefix("blobs/") && !$0.hasPrefix("thumbs/") }.isEmpty)
    }

    /// OC-7021. Given several items including dedupe bumps and an edited duplicate with identical bytes, when all
    /// blobNames are read, then distinct blobNames = representation rows = 5, and 5 files exist.
    @Test("OC-7021 no blob is shared between items, even across bumps and edited duplicates")
    func oc7021_noSharedBlob() async throws {
        let rig = try await Rig.make()
        defer { rig.cleanUp() }
        let rtf = Data("{\\rtf1 same bytes}".utf8)

        _ = try await rig.create(rig.rich("k-A", plain: "A", rtf: rtf))
        let twoRep = IngestCandidate(
            kind: .richText, contentKey: "k-B", plainText: "B",
            representations: [
                PasteboardRepresentation(uti: "public.rtf", data: rtf),
                PasteboardRepresentation(uti: "public.html", data: Data("<i>B</i>".utf8)),
            ], origin: .pasteboard, occurredAt: Date(timeIntervalSince1970: Double(t0) / 1000))
        _ = try await rig.create(twoRep)
        _ = try await rig.create(rig.image("k-C", TestImage.make(width: 32, height: 32, format: .png)))
        // Two dedupe bumps of A, then an edited duplicate: same bytes, new key (FR-004-08).
        for _ in 0..<2 {
            let bump = try await rig.ingest.ingest(rig.rich("k-A", plain: "A", rtf: rtf)).get()
            guard case .bumped = bump.outcome else { Issue.record("expected a bump"); return }
        }
        _ = try await rig.create(rig.rich("k-A-edited", plain: "A", rtf: rtf))

        let (distinct, total) = try await rig.store.reader().read { db -> (Int, Int) in
            (try Int.fetchOne(db, sql: "SELECT COUNT(DISTINCT blobName) FROM representation")!,
             try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM representation")!)
        }
        #expect(try rig.itemCount() == 4)
        #expect(total == 5)
        #expect(distinct == 5)
        #expect(rig.blobFiles().count == 5)
    }

    // MARK: FR-007-05 dedupe

    /// OC-7027. Given N items, when the same text is submitted concurrently (repeated over ten keys so the
    /// interleaving actually happens), then each key has exactly one item with copyCount 2, one call reported
    /// created and one bumped, and the loser left no blob behind.
    @Test("OC-7027 concurrent identical payloads create one item with copyCount 2 and leak no blob")
    func oc7027_concurrentDedupe() async throws {
        let rig = try await Rig.make()
        defer { rig.cleanUp() }
        _ = try await rig.create(rig.text("k-existing", "existing"))
        let ingest = rig.ingest

        var created = 0
        var bumped = 0
        for round in 0..<10 {
            let candidate = rig.rich("MARK-D1-\(round)", plain: "MARK-D1", rtf: Data("{\\rtf1 d\(round)}".utf8))
            let outcomes = await withTaskGroup(of: IngestOutcome?.self) { group in
                group.addTask { try? await ingest.ingest(candidate).get().outcome }
                group.addTask { try? await ingest.ingest(candidate).get().outcome }
                var all: [IngestOutcome?] = []
                for await outcome in group { all.append(outcome) }
                return all
            }
            for case .some(let outcome) in outcomes {
                if case .created = outcome { created += 1 } else { bumped += 1 }
            }
        }

        #expect(created == 10)
        #expect(bumped == 10)
        #expect(try rig.itemCount() == 11)
        let copyCounts = try await rig.store.reader().read {
            try Int.fetchAll($0, sql: "SELECT copyCount FROM item WHERE contentKey LIKE 'MARK-D1-%' ORDER BY contentKey")
        }
        #expect(copyCounts == [Int](repeating: 2, count: 10))
        #expect(rig.blobFiles().count == 10)
        #expect(try rig.store.count("representation") == 10)
    }

    /// OC-7027. Given a subscriber on the event bus, when one new text is copied, then exactly one `.itemsChanged` is
    /// published and nothing else, and a second new text makes it exactly two. Goes red if a created ingest stops
    /// publishing (Library and Shelf would never refresh).
    @Test("OC-7027 a created item publishes exactly one itemsChanged")
    func oc7027_createPublishesOneItemsChanged() async throws {
        // given a store with a subscriber and no events yet
        let rig = try await Rig.make()
        defer { rig.cleanUp() }
        let events = EventCollector(rig.store.database.events)
        #expect(events.events.isEmpty)

        // when one new text is copied
        _ = try await rig.create(rig.text("k-7027-event-a", "first"))

        // then exactly one itemsChanged was published
        #expect(events.events == [.itemsChanged])

        // and a second distinct copy adds exactly one more
        _ = try await rig.create(rig.text("k-7027-event-b", "second"))
        #expect(events.events == [.itemsChanged, .itemsChanged])
        #expect(try rig.itemCount() == 2)
    }

    /// OC-7033, OC-7015. Given a store that holds no row for a key, when four identical copies of that key race
    /// through ingest at once (repeated over eight keys so the interleaving actually happens), then each key ends with
    /// exactly one row whose copyCount is 4, exactly one call reported created and three bumped, and no second row
    /// is written even though contentKey has no unique constraint (OC-7015). Goes red if the in-transaction re-check
    /// before the insert is removed: every racer that passed step 1 inserts its own row.
    @Test("OC-7033 OC-7015 racing identical copies leave one row per key with every copy counted")
    func oc7033_racingCopiesLeaveOneRowPerKey() async throws {
        let rig = try await Rig.make()
        defer { rig.cleanUp() }
        let ingest = rig.ingest

        var created = 0
        var bumped = 0
        for round in 0..<8 {
            let candidate = rig.text("MARK-R7033-\(round)", "race \(round)")
            let outcomes = await withTaskGroup(of: IngestOutcome?.self) { group in
                for _ in 0..<4 { group.addTask { try? await ingest.ingest(candidate).get().outcome } }
                var all: [IngestOutcome?] = []
                for await outcome in group { all.append(outcome) }
                return all
            }
            #expect(outcomes.compactMap { $0 }.count == 4)
            for case .some(let outcome) in outcomes {
                if case .created = outcome { created += 1 } else { bumped += 1 }
            }
        }

        #expect(created == 8)
        #expect(bumped == 24)
        let keys = try await rig.store.reader().read {
            try String.fetchAll($0, sql: "SELECT contentKey FROM item WHERE contentKey LIKE 'MARK-R7033-%' ORDER BY contentKey")
        }
        let counts = try await rig.store.reader().read {
            try Int.fetchAll($0, sql: "SELECT copyCount FROM item WHERE contentKey LIKE 'MARK-R7033-%' ORDER BY contentKey")
        }
        #expect(keys == (0..<8).map { "MARK-R7033-\($0)" })
        #expect(counts == [Int](repeating: 4, count: 8))
        #expect(try rig.itemCount() == 8)
    }

    /// OC-7028. Given item I (copyCount 3, pinned, tag, note, pasteCount 2, lastUsedAt U) and a newer item, when
    /// I's text is copied again, then no item is added, lastCopiedAt is now, copyCount 4, everything else is
    /// unchanged, and I is first in Recent.
    @Test("OC-7028 a re-copy bumps only lastCopiedAt and copyCount and floats the item to the top of Recent")
    func oc7028_bumpKeepsUserState() async throws {
        let rig = try await Rig.make()
        defer { rig.cleanUp() }
        let now = rig.store.clock.millis
        let created = now - 10 * dayMs
        let used = now - 3 * dayMs
        let id = try await rig.create(rig.text("k-7028", "MARK-B1", at: created))
        let newer = try await rig.create(rig.text("k-7028-newer", "newer item", at: now - dayMs))
        try await exec(rig, "UPDATE item SET copyCount = 3, pinned = 1, note = 'keep me', pasteCount = 2, lastUsedAt = ? WHERE id = ?",
                       [used, id.uuidString])
        try await exec(rig, "INSERT INTO tag (name, color, createdAt) VALUES ('Work', 'red', 0)")
        try await exec(rig, "INSERT INTO itemTag (itemId, tagId) SELECT ?, id FROM tag WHERE name = 'Work'", [id.uuidString])
        let page = try await rig.store.database.items(matching: LibraryQuery()).get()
        #expect(page.rows.first?.id == newer)

        let outcome = try await rig.ingest.ingest(rig.text("k-7028", "MARK-B1")).get().outcome

        #expect(outcome == .bumped(id))
        #expect(try rig.itemCount() == 2)
        let row = try rig.row(id)
        #expect(abs(row.lastCopiedAt - now) <= 2000)
        #expect(row.copyCount == 4)
        #expect(row.createdAt == created)
        #expect(row.pinned == 1)
        #expect(row.note == "keep me")
        #expect(row.pasteCount == 2)
        #expect(row.lastUsedAt == used)
        #expect(row.plainText == "MARK-B1")
        let after = try await rig.store.database.items(matching: LibraryQuery()).get()
        #expect(after.rows.map(\.id) == [id, newer])
        #expect(after.rows.first?.tagNames == ["Work"])
    }

    /// OC-7029. Given an item copied and pinned 60 days ago, when the same content is copied again, then no item
    /// is created, lastCopiedAt is now, and it is still pinned.
    @Test("OC-7029 re-copying a 60-day-old pinned item revives it instead of duplicating it")
    func oc7029_oldPinnedBump() async throws {
        let rig = try await Rig.make()
        defer { rig.cleanUp() }
        let now = rig.store.clock.millis
        let id = try await rig.create(rig.text("k-7029", "old pinned", at: now - 60 * dayMs))
        try await exec(rig, "UPDATE item SET pinned = 1 WHERE id = ?", [id.uuidString])

        let outcome = try await rig.ingest.ingest(rig.text("k-7029", "old pinned")).get().outcome

        #expect(outcome == .bumped(id))
        #expect(try rig.itemCount() == 1)
        let row = try rig.row(id)
        #expect(abs(row.lastCopiedAt - now) <= 2000)
        #expect(row.pinned == 1)
        #expect(row.copyCount == 2)
    }

    /// OC-7030. Given screenshot S imported at L and then copied by the user at L+1h, when pickup re-supplies the
    /// same bytes dated L, then lastCopiedAt stays L+1h (never moves back) and no item is added.
    @Test("OC-7030 a late screenshot pickup never moves lastCopiedAt backwards")
    func oc7030_lastCopiedNeverBackwards() async throws {
        let rig = try await Rig.make()
        defer { rig.cleanUp() }
        let l: Int64 = 1_700_000_000_000
        let png = TestImage.make(width: 40, height: 30, format: .png)
        let id = try await rig.create(rig.image("k-7030", png, kind: .screenshot, origin: .screenshotFile, at: l))
        #expect(try rig.row(id).lastCopiedAt == 1_700_000_000_000)

        let copied = try await rig.ingest.ingest(rig.image("k-7030", png, kind: .screenshot, origin: .pasteboard, at: l + hourMs)).get().outcome
        #expect(copied == .bumped(id))
        #expect(try rig.row(id).lastCopiedAt == 1_700_003_600_000)

        let pickup = try await rig.ingest.ingest(rig.image("k-7030", png, kind: .screenshot, origin: .screenshotFile, at: l)).get().outcome

        #expect(pickup == .bumped(id))
        #expect(try rig.itemCount() == 1)
        let row = try rig.row(id)
        #expect(row.lastCopiedAt == 1_700_003_600_000)
        #expect(row.copyCount == 3)
    }

    // MARK: FR-007-06 ceilings

    /// OC-7036. Text of 10 MiB + 1 byte is refused with CAP-LIM-001 carrying the 10 MiB limit; exactly 10 MiB is
    /// stored whole.
    @Test("OC-7036 text over 10 MiB is refused, exactly 10 MiB is stored in full")
    func oc7036_textCeiling() async throws {
        let rig = try await Rig.make()
        defer { rig.cleanUp() }

        let over = await rig.ingest.ingest(rig.text("k-over", String(repeating: "a", count: 10_485_761)))

        let error = try #require(failure(over))
        #expect(error.code == .capLim001)
        #expect(error.context[.limitBytes] == .bytes(10_485_760))
        #expect(try rig.itemCount() == 0)

        let id = try await rig.create(rig.text("k-exact", String(repeating: "a", count: 10_485_760)))
        #expect(try rig.itemCount() == 1)
        #expect(try utf8Length(rig, id) == 10_485_760)
    }

    /// OC-7037. A 5 MiB + 1 byte RTF is dropped (item kept with its plain text, CAP-LIM-002, Info so no Notice);
    /// exactly 5 MiB keeps its public.rtf blob.
    @Test("OC-7037 an RTF over 5 MiB is dropped quietly, exactly 5 MiB is kept")
    func oc7037_richCeiling() async throws {
        let rig = try await Rig.make()
        defer { rig.cleanUp() }

        let over = try await rig.ingest.ingest(rig.rich("k-rtf-over", plain: "fallback text", rtf: Data(count: 5_242_881))).get()

        guard case .created(let overId) = over.outcome else { Issue.record("expected created"); return }
        #expect(try rig.itemCount() == 1)
        #expect(try rig.row(overId).plainText == "fallback text")
        #expect(try rig.reps(overId).isEmpty)
        #expect(over.warnings.map(\.code) == [.capLim002])
        #expect(over.warnings.first?.severity == .info)
        #expect(rig.blobFiles().isEmpty)

        let exact = try await rig.ingest.ingest(rig.rich("k-rtf-exact", plain: "fallback two", rtf: Data(count: 5_242_880))).get()

        guard case .created(let exactId) = exact.outcome else { Issue.record("expected created"); return }
        #expect(try rig.itemCount() == 2)
        let reps = try rig.reps(exactId)
        #expect(reps.map(\.uti) == ["public.rtf"])
        #expect(reps.first?.byteSize == 5_242_880)
        #expect(exact.warnings.isEmpty)
        #expect(rig.blobFiles().count == 1)
    }

    /// TASK-405 / FR-007-05. A re-copy of a payload whose RTF was dropped over the ceiling bumps the existing item
    /// (step 1) and raises no new CAP-LIM-002; only the copy that created the item carried it.
    @Test("OC-405-1 re-copying an oversized-RTF payload bumps the item and raises no new notice")
    func oc405_recopyRaisesNoNotice() async throws {
        let rig = try await Rig.make()
        defer { rig.cleanUp() }
        let candidate = rig.rich("k-405-recopy", plain: "fallback", rtf: Data(count: 5_242_881))

        let first = try await rig.ingest.ingest(candidate).get()
        guard case .created(let id) = first.outcome else { Issue.record("expected created"); return }
        #expect(first.warnings.map(\.code) == [.capLim002])

        let second = try await rig.ingest.ingest(candidate).get()

        guard case .bumped(let bumpedId) = second.outcome else { Issue.record("expected bumped"); return }
        #expect(bumpedId == id)
        #expect(second.warnings.isEmpty)
        #expect(try rig.row(id).copyCount == 2)
        #expect(try rig.itemCount() == 1)
    }

    /// TASK-405 / FR-007-05. Two identical oversized-RTF payloads submitted together: whichever path the loser takes
    /// (step 1 or the in-transaction re-check) it raises nothing, so each round produces exactly one CAP-LIM-002, the
    /// creator's. Repeated over ten keys so the re-check path is actually taken.
    @Test("OC-405-2 concurrent identical oversized-RTF payloads raise one notice in total, never two")
    func oc405_concurrentRaisesOneNotice() async throws {
        let rig = try await Rig.make()
        defer { rig.cleanUp() }
        let ingest = rig.ingest

        for round in 0..<10 {
            let candidate = rig.rich("k-405-race-\(round)", plain: "fallback", rtf: Data(count: 5_242_881))
            let results = await withTaskGroup(of: IngestResult?.self) { group in
                group.addTask { try? await ingest.ingest(candidate).get() }
                group.addTask { try? await ingest.ingest(candidate).get() }
                var all: [IngestResult] = []
                for await result in group { if let result { all.append(result) } }
                return all
            }
            #expect(results.count == 2)
            for result in results {
                switch result.outcome {
                case .created: #expect(result.warnings.map(\.code) == [.capLim002])
                case .bumped, .unchanged: #expect(result.warnings.isEmpty)
                }
            }
            #expect(results.flatMap(\.warnings).count == 1)
        }
        #expect(try rig.itemCount() == 10)
    }

    /// OC-7038. An image whose source is 100 MiB + 1 byte is refused with CAP-LIM-001; one of exactly 100 MiB is
    /// accepted. The exact-size source is a real PNG padded with trailing zero bytes to the ceiling.
    @Test("OC-7038 image source over 100 MiB is refused, exactly 100 MiB is stored")
    func oc7038_imageCeiling() async throws {
        let rig = try await Rig.make()
        defer { rig.cleanUp() }

        let over = await rig.ingest.ingest(rig.image("k-img-over", Data(count: 104_857_601)))

        let error = try #require(failure(over))
        #expect(error.code == .capLim001)
        #expect(error.context[.limitBytes] == .bytes(104_857_600))
        #expect(try rig.itemCount() == 0)
        #expect(rig.blobFiles().isEmpty)

        var exact = TestImage.make(width: 16, height: 16, format: .png)
        exact.append(Data(count: 104_857_600 - exact.count))
        #expect(exact.count == 104_857_600)
        let id = try await rig.create(rig.image("k-img-exact", exact))
        #expect(try rig.itemCount() == 1)
        #expect(try rig.row(id).pixelWidth == 16)
    }

    /// OC-7039. 501 files in one copy are trimmed to 500 members with CAP-LIM-003 carrying 501; exactly 500 files
    /// keep 500 members and raise nothing.
    @Test("OC-7039 501 files are trimmed to 500 with the count reported, 500 files are untouched")
    func oc7039_bundleCeiling() async throws {
        let rig = try await Rig.make()
        defer { rig.cleanUp() }

        let over = try await rig.ingest.ingest(rig.files("k-501", count: 501)).get()

        guard case .created(let overId) = over.outcome else { Issue.record("expected created"); return }
        #expect(try rig.itemCount() == 1)
        #expect(try rig.memberCount(overId) == 500)
        #expect(over.warnings.map(\.code) == [.capLim003])
        #expect(over.warnings.first?.context[.count] == .int(501))

        let exact = try await rig.ingest.ingest(rig.files("k-500", count: 500)).get()

        guard case .created(let exactId) = exact.outcome else { Issue.record("expected created"); return }
        #expect(try rig.itemCount() == 2)
        #expect(try rig.memberCount(exactId) == 500)
        #expect(exact.warnings.isEmpty)
        // Trimming keeps the first 500 in order.
        let lastPath = try await rig.store.reader().read {
            try String.fetchOne($0, sql: "SELECT path FROM bundleMember WHERE itemId = ? ORDER BY ordinal DESC LIMIT 1", arguments: [overId.uuidString])
        }
        #expect(lastPath == "/tmp/flotsam-8t/file-499.txt")
    }

    /// OC-7040. A screenshot over 100 MiB is refused with SSP-LIM-001 and a Shelf text over 10 MiB with
    /// SHF-LIM-001 (never the clipboard code); nothing is stored for either.
    @Test("OC-7040 the skip code follows the origin: screenshot SSP-LIM-001, Shelf SHF-LIM-001")
    func oc7040_originSpecificCodes() async throws {
        let rig = try await Rig.make()
        defer { rig.cleanUp() }

        let shot = await rig.ingest.ingest(rig.image("k-shot", Data(count: 104_857_601), kind: .screenshot, origin: .screenshotFile))
        let drop = await rig.ingest.ingest(rig.text("k-drop", String(repeating: "b", count: 10_485_761), origin: .shelfDrop))

        let shotError = try #require(failure(shot))
        #expect(shotError.code == .sspLim001)
        #expect(shotError.context[.limitBytes] == .bytes(104_857_600))
        let dropError = try #require(failure(drop))
        #expect(dropError.code == .shfLim001)
        #expect(dropError.context[.limitBytes] == .bytes(10_485_760))
        #expect(try rig.itemCount() == 0)
        #expect(rig.blobFiles().isEmpty)
    }

    // MARK: FR-007-07 undecodable

    /// OC-7046. Bytes declared public.png that are not an image are refused with CAP-VAL-001 (Info)
    /// from a copy and SSP-VAL-001 (Info) from the screenshot folder; nothing is stored and no blob remains.
    @Test("OC-7046 undecodable image bytes are refused with the origin's VAL code and leave no blob")
    func oc7046_undecodable() async throws {
        let rig = try await Rig.make()
        defer { rig.cleanUp() }
        let garbage = Data("this is not a png at all".utf8)

        let copy = await rig.ingest.ingest(rig.image("k-bad-copy", garbage))
        let shot = await rig.ingest.ingest(rig.image("k-bad-shot", garbage, kind: .screenshot, origin: .screenshotFile))

        let copyError = try #require(failure(copy))
        #expect(copyError.code == .capVal001)
        #expect(copyError.severity == .info)
        let shotError = try #require(failure(shot))
        #expect(shotError.code == .sspVal001)
        #expect(shotError.severity == .info)
        #expect(try rig.itemCount() == 0)
        #expect(try rig.store.count("representation") == 0)
        #expect(rig.blobFiles().isEmpty)
    }
}
