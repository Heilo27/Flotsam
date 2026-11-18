import Foundation
import GRDB
import Testing
import FlotsamBase
@testable import FlotsamStorage

// FRD-007 8T contract tests, slice S1: the confirm/cancel halves of the destructive Settings > Storage changes
// (OC-7062, OC-7063, OC-7080, OC-7081), the Clear History sheet's core half (OC-7088), screenshot originals (OC-7125)
// and the storage usage figures (OC-7151). The popup, alert and sheet widgets are App-target SwiftUI (no test
// target); each of those halves is a disabled stub in FRD007ContractTestsGaps.swift. What is asserted here is what
// the widgets are built from: the preview count, the settings value, the rows and files that remain, read back
// through a FRESH read-only connection and a FRESH SettingsStore over the same key-value store. Expected values are
// literals.

@Suite struct FRD007ContractRetentionTests {
    /// What `StoragePane.confirm` does for a reducing change: write the setting, then sweep with the settings' values.
    /// It lives in the App target, so this mirror is the seam gap recorded in the Gaps file; everything it calls is the
    /// real core.
    private func confirmChange(_ store: Store, _ settings: SettingsStore) async throws -> SweepOutcome {
        try await store.database.runRetentionSweep(
            preset: settings.value(SettingKeys.storageRetention), budget: settings.value(SettingKeys.storageImageBudget)
        ).get()
    }

    /// 30 non-exempt 100 MiB images aged 1...30 days, one 100 MiB image aged 40 days that is pinned, and a recent text.
    private func budgetLibrary(_ store: Store) async throws {
        var specs = (1...30).map { Spec(n: $0, kind: .image, ageMs: Int64($0) * dayMs, blobs: 1, repBytes: 100 * mib) }
        specs.append(Spec(n: 31, kind: .image, ageMs: 40 * dayMs, pinned: true, blobs: 1, repBytes: 100 * mib))
        specs.append(Spec(n: 32, ageMs: 5 * dayMs))
        try await store.insert(specs)
    }

    // MARK: Lower image budget (FR-007-08, FR-007-09)

    /// OC-7062. Budget 10 GB, 3.1 GB of images, user picks 2 GB: the alert shows a count; Cancel.
    /// Red if the preview deletes anything or writes the setting, if the count the alert shows is not the count the
    /// sweep would remove, or if a cancelled change leaves the budget at 2 GB after relaunch.
    @Test("OC-7062 cancelling the lower-budget confirmation leaves the budget at 10 GB and every item in place")
    func oc7062_cancelLowerBudget() async throws {
        // given budget 10 GB stored, the 32-item library, and a recorder on deletions
        let store = try await Store.make()
        defer { store.cleanUp() }
        let kv = MemoryKV()
        let settings = SettingsStore(store: kv)
        settings.set(ImageBudget.gib10, for: SettingKeys.storageImageBudget)
        try await budgetLibrary(store)
        let events = EventCollector(store.database.events)
        #expect(try store.count("item") == 32, "precondition")

        // when the user picks 2 GB: the flow asks for a preview and the alert would show its count
        #expect(StorageChangeFlow.needsPreview(budget: .gib2, from: settings.value(SettingKeys.storageImageBudget)))
        let preview = try await store.database.imageBudgetEvictionPreview(.gib2).get()
        #expect(StorageChangeFlow.after(previewCount: preview.count) == .confirm(count: 13))

        // and the user clicks Cancel: nothing further is called

        // then, as a relaunch would see it, the budget still reads 10 GB, all 32 items and their blobs are there, and
        // no deletion was announced
        #expect(SettingsStore(store: kv).value(SettingKeys.storageImageBudget) == .gib10)
        #expect(try store.presentIds() == Set(1...32))
        #expect(try store.count("representation") == 31)
        #expect(store.exists(store.blobURL(30, 1)))
        #expect(events.deletedIds.isEmpty)
    }

    /// OC-7063. Same library; the user confirms the 2 GB confirmation that showed 13.
    /// Red if the sweep deletes a different number than the preview showed, deletes a non-image or the pinned image,
    /// evicts newest-first, or the setting is not persisted as 2 GB.
    @Test("OC-7063 confirming the lower-budget alert deletes exactly the 13 previewed non-exempt images")
    func oc7063_confirmLowerBudget() async throws {
        // given budget 10 GB stored and the 32-item library (3.1 GB of images, one of them pinned)
        let store = try await Store.make()
        defer { store.cleanUp() }
        let kv = MemoryKV()
        let settings = SettingsStore(store: kv)
        settings.set(ImageBudget.gib10, for: SettingKeys.storageImageBudget)
        settings.set(RetentionPreset.forever, for: SettingKeys.storageRetention)
        try await budgetLibrary(store)
        let preview = try await store.database.imageBudgetEvictionPreview(.gib2).get()
        #expect(StorageChangeFlow.after(previewCount: preview.count) == .confirm(count: 13), "the alert shows 13")

        // when the user confirms
        settings.set(ImageBudget.gib2, for: SettingKeys.storageImageBudget)
        let outcome = try await confirmChange(store, settings)

        // then exactly 13 are gone (count delta -13): the 13 oldest non-exempt images 18...30; the pinned image 31, the
        // text 32 and the 17 newest images stay
        #expect(outcome.budget.evictedCount == 13)
        #expect(try store.count("item") == 19)
        #expect(try store.presentIds() == Set(1...17).union([31, 32]))
        #expect(!store.exists(store.blobURL(18, 1)) && store.exists(store.blobURL(17, 1)) && store.exists(store.blobURL(31, 1)))
        // and the popup would read 2 GB after a relaunch
        #expect(SettingsStore(store: kv).value(SettingKeys.storageImageBudget) == .gib2)
    }

    // MARK: Shorten retention (FR-007-09)

    /// 60 items older than 7 days (non-exempt), 5 recent, and 4 exempt old ones (two pinned, a trigger, a hotkey).
    private func retentionLibrary(_ store: Store) async throws {
        var specs: [Spec] = (1...60).map { Spec(n: $0, ageMs: Int64(7 + $0) * dayMs, blobs: 1, repBytes: 1000) }
        specs += (61...65).map { Spec(n: $0, ageMs: Int64($0 - 60) * dayMs, blobs: 1, repBytes: 1000) }
        specs += [
            Spec(n: 66, ageMs: 300 * dayMs, pinned: true, blobs: 1, repBytes: 1000),
            Spec(n: 67, ageMs: 301 * dayMs, pinned: true, blobs: 1, repBytes: 1000),
            Spec(n: 68, ageMs: 302 * dayMs, trigger: ";old", blobs: 1, repBytes: 1000),
            Spec(n: 69, ageMs: 303 * dayMs, hotkey: 12, blobs: 1, repBytes: 1000),
        ]
        try await store.insert(specs)
    }

    /// OC-7080. Retention Forever, the user picks 7 days, the alert shows k = 60; Cancel.
    /// Red if choosing 7 days writes the setting before confirmation, if the preview deletes, or if a sweep for 7 days
    /// runs on cancel.
    @Test("OC-7080 cancelling the shorten alert keeps Forever, deletes nothing and runs no 7-day sweep")
    func oc7080_cancelShorten() async throws {
        // given retention Forever stored and the 69-item library
        let store = try await Store.make()
        defer { store.cleanUp() }
        let kv = MemoryKV()
        let settings = SettingsStore(store: kv)
        settings.set(RetentionPreset.forever, for: SettingKeys.storageRetention)
        try await retentionLibrary(store)
        let events = EventCollector(store.database.events)

        // when the user picks 7 days and the alert shows the count
        #expect(StorageChangeFlow.needsPreview(retention: .d7, from: settings.value(SettingKeys.storageRetention)))
        let preview = try await store.database.retentionPreview(.d7).get()
        #expect(StorageChangeFlow.after(previewCount: preview.count) == .confirm(count: 60))

        // and the user clicks Cancel

        // then after a relaunch the setting is still Forever, all 69 items and blobs remain, nothing was deleted
        #expect(SettingsStore(store: kv).value(SettingKeys.storageRetention) == .forever)
        #expect(try store.presentIds() == Set(1...69))
        #expect(store.exists(store.blobURL(60, 1)))
        #expect(events.deletedIds.isEmpty)
    }

    /// OC-7081. Same library; the user clicks Delete on the alert that showed 60.
    /// Red if the sweep deletes more or fewer than the previewed 60, deletes any of the 4 exempt old items or the 5
    /// recent ones, or the setting is not 7 days afterwards.
    @Test("OC-7081 confirming the shorten alert deletes exactly the 60 previewed items and keeps the 4 exempt old ones")
    func oc7081_confirmShorten() async throws {
        // given retention Forever stored and the 69-item library
        let store = try await Store.make()
        defer { store.cleanUp() }
        let kv = MemoryKV()
        let settings = SettingsStore(store: kv)
        settings.set(RetentionPreset.forever, for: SettingKeys.storageRetention)
        settings.set(ImageBudget.unlimited, for: SettingKeys.storageImageBudget)
        try await retentionLibrary(store)
        let preview = try await store.database.retentionPreview(.d7).get()
        #expect(preview.count == 60, "the alert shows 60")

        // when the user confirms
        settings.set(RetentionPreset.d7, for: SettingKeys.storageRetention)
        let outcome = try await confirmChange(store, settings)

        // then exactly 60 are gone (delta -60); the 4 exempt old items (66...69) and the 5 recent (61...65) remain
        #expect(outcome.retentionDeleted == 60)
        #expect(try store.count("item") == 9)
        #expect(try store.presentIds() == Set(61...69))
        #expect(store.exists(store.blobURL(66, 1)) && store.exists(store.blobURL(69, 1)) && !store.exists(store.blobURL(1, 1)))
        #expect(SettingsStore(store: kv).value(SettingKeys.storageRetention) == .d7)
    }

    // MARK: Clear History sheet (FR-007-11)

    /// OC-7088 (core half). The sheet's range popup is `ClearRange.allCases`; its count label is
    /// `clearHistoryPreview`, which leaves out pinned and shortcut items until the option is on (the option starts off,
    /// App `@State`, see Gaps).
    /// Red if a range is added or dropped, a range's label changes, or the preview counts exempt items while the option
    /// is off.
    @Test("OC-7088 Clear History offers Last hour, Last 24 hours and All time, and counts exempt items only with the option")
    func oc7088_clearSheetCore() async throws {
        // given 7 items: 3 plain (1h, 2h and 3 days old), a pinned one, a trigger one, a hotkey one, all within the hour...
        // and one more plain item 2 days old
        let store = try await Store.make()
        defer { store.cleanUp() }
        try await store.insert([
            Spec(n: 1, ageMs: hourMs / 2), Spec(n: 2, ageMs: 2 * hourMs), Spec(n: 3, ageMs: 3 * dayMs),
            Spec(n: 4, ageMs: hourMs / 4, pinned: true), Spec(n: 5, ageMs: hourMs / 3, trigger: ";x"),
            Spec(n: 6, ageMs: hourMs / 5, hotkey: 4), Spec(n: 7, ageMs: 2 * dayMs),
        ])

        // then the popup offers exactly three ranges, in order, with these labels
        #expect(ClearRange.allCases == [.lastHour, .last24Hours, .allTime])
        #expect(
            [SettingsString.rangeLastHour, .rangeLast24Hours, .rangeAllTime].map(\.text) == ["Last hour", "Last 24 hours", "All time"])
        #expect(SettingsString.clearHistory.text == "Clear History…")

        // and the count label per range with the option off excludes the three exempt items (4, 5, 6)
        #expect(try await store.database.clearHistoryPreview(range: .lastHour, includeExempt: false).get().count == 1)
        #expect(try await store.database.clearHistoryPreview(range: .last24Hours, includeExempt: false).get().count == 2)
        #expect(try await store.database.clearHistoryPreview(range: .allTime, includeExempt: false).get().count == 4)
        // and with the option on, all seven in All time and the three exempt plus item 1 in the last hour
        #expect(try await store.database.clearHistoryPreview(range: .allTime, includeExempt: true).get().count == 7)
        #expect(try await store.database.clearHistoryPreview(range: .lastHour, includeExempt: true).get().count == 4)
        // and the preview deleted nothing
        #expect(try store.presentIds() == Set(1...7))
    }

    /// OC-7088 (strings). FR-007-11 names the destructive button "Delete {n} Items" and the option "Also delete pinned
    /// and shortcut items"; the shipped catalogue has "Delete" (the count sits in the sentence above it) and "Also
    /// delete pinned items and items with a shortcut". FRD-008 FR-008-08 hands both to FRD-007, so FRD-007 is the
    /// owner and the product differs from it.
    /// Product defect, Minor. Repro: Settings > Storage > Clear History..., read the button and the checkbox.
    @Test("OC-7088 the Delete button reads 'Delete {n} Items' and the option reads 'Also delete pinned and shortcut items'")
    func oc7088_clearSheetStrings() {
        // Red if the catalogue gains the count placeholder and the option wording (then this known issue must go).
        withKnownIssue("OC-7088 product defect: ui.settings.clearDelete is 'Delete' and clearIncludeExempt is reworded vs FR-007-11") {
            // given the sheet shows 12 items
            // when the button and checkbox text are built
            // then they read as FR-007-11 states
            #expect(SettingsString.clearDelete.text([.count(12)]) == "Delete 12 Items")
            #expect(SettingsString.clearIncludeExempt.text == "Also delete pinned and shortcut items")
        }
    }

    // MARK: Screenshot originals (FR-007-15)

    /// OC-7125. Two screenshot items whose originals are real files with non-text bytes. S1 is deleted by the user
    /// (the Library delete), S2 is old and removed by the 7-day sweep. Both originals stay, byte for byte and with the
    /// same modification time, and the rows and blobs go.
    /// Red if any deletion path follows `originalPath` and removes or rewrites the file.
    @Test("OC-7125 deleting a screenshot item, by hand or by retention, leaves its original file byte-identical")
    func oc7125_screenshotOriginalSurvives() async throws {
        // given two screenshot items and a survivor, with real originals outside the data folder
        let store = try await Store.make()
        let refs = References()
        defer { store.cleanUp(); refs.cleanUp() }
        let bytes1 = Data([0x89, 0x50, 0x4E, 0x47, 0x00, 0xFF, 0x10, 0x80])
        let bytes2 = Data([0x00, 0x01, 0xFE, 0xFF, 0x89, 0x50])
        let o1 = refs.directory.appendingPathComponent("shot1.png")
        let o2 = refs.directory.appendingPathComponent("shot2.png")
        try FileManager.default.createDirectory(at: refs.directory, withIntermediateDirectories: true)
        try bytes1.write(to: o1)
        try bytes2.write(to: o2)
        let modified1 = try FileManager.default.attributesOfItem(atPath: o1.path)[.modificationDate] as? Date
        let modified2 = try FileManager.default.attributesOfItem(atPath: o2.path)[.modificationDate] as? Date
        var s1 = Spec(n: 1, kind: .screenshot, ageMs: hourMs, blobs: 1, repBytes: 10)
        s1.originalPath = o1.path
        var s2 = Spec(n: 2, kind: .screenshot, ageMs: 20 * dayMs, blobs: 1, repBytes: 10)
        s2.originalPath = o2.path
        try await store.insert([s1, s2, Spec(n: 3, kind: .screenshot, ageMs: 2 * hourMs, blobs: 1, repBytes: 10)])
        #expect(try store.presentIds() == [1, 2, 3], "precondition")

        // when S1 is deleted from the Library and the 7-day sweep removes S2
        #expect(try await store.database.delete(ids: [Store.id(1)]).get() == [Store.id(1)])
        let outcome = try await store.database.runRetentionSweep(preset: .d7, budget: .unlimited).get()

        // then both items and their blobs are gone, the survivor remains (delta -2, identity {3})
        #expect(outcome.retentionDeleted == 1)
        #expect(try store.presentIds() == [3])
        #expect(!store.exists(store.blobURL(1, 1)) && !store.exists(store.blobURL(2, 1)) && store.exists(store.blobURL(3, 1)))
        // and both originals are byte-identical and untouched
        #expect(try Data(contentsOf: o1) == bytes1)
        #expect(try Data(contentsOf: o2) == bytes2)
        #expect(try FileManager.default.attributesOfItem(atPath: o1.path)[.modificationDate] as? Date == modified1)
        #expect(try FileManager.default.attributesOfItem(atPath: o2.path)[.modificationDate] as? Date == modified2)
    }

    // MARK: Storage usage (FR-007 section 8)

    /// OC-7151. An empty library reads 0 items and 0 image bytes. Then 5 items arrive (4 texts of 3 KB, one 2 MiB
    /// image); reopening Storage (a new `storageUsage` call) reads total + 5, image bytes 2 MiB, and a database size
    /// that grew. The database size is the page counters, so it grows while the rows are still in the WAL.
    /// Red if the total is cached, image bytes counts non-images, or the size is the length of `flotsam.sqlite` (it
    /// does not move until a checkpoint).
    @Test("OC-7151 reopening Storage after 5 new items (one an image) reads total +5 and larger image and database sizes")
    func oc7151_usageGrows() async throws {
        // given a library of 3 small texts, and its usage
        let store = try await Store.make()
        defer { store.cleanUp() }
        try await store.insert((1...3).map { Spec(n: $0, ageMs: Int64($0) * hourMs) })
        let before = try await store.database.storageUsage().get()
        #expect(before.totalItems == 3)
        #expect(before.imageBytes == 0)

        // when 5 items are copied: 4 texts of about 3 KB and an image of 2 MiB
        let long = String(repeating: "lorem ipsum dolor ", count: 170)
        try await store.insert((4...7).map { Spec(n: $0, ageMs: Int64($0) * 1000, text: long + "\($0)") })
        try await store.insert(Spec(n: 8, kind: .image, ageMs: 500, blobs: 1, repBytes: 2 * mib))
        let after = try await store.database.storageUsage().get()

        // then the total is 8, the image size is 2 MiB, and the database size (page counters) grew
        #expect(after.totalItems == 8)
        #expect(after.imageBytes == 2 * mib)
        #expect(after.databaseBytes > before.databaseBytes)
    }
}
