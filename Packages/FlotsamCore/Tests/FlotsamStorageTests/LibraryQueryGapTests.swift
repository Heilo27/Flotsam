import Foundation
import GRDB
import Testing
import FlotsamBase
@testable import FlotsamStorage

// FRD-007 8T gap suite for the Library query layer (FR-007-18): paging and the sidebar counts, through the public
// `items(matching:)`, `count(filter:text:)` and `sidebarCounts()`. Expected values are literals.

@Suite struct LibraryQueryGapTests {
    /// 1...n of one kind, then `decoys` text items that must never appear under that kind's filter.
    private func arrange(_ store: Store, kind: ItemKind, count: Int, decoys: Int = 0, spreadMs: Int64 = 1_000) async throws {
        var specs = (1...count).map { Spec(n: $0, kind: kind, ageMs: Int64($0) * spreadMs) }
        specs += (0..<decoys).map { Spec(n: 10_000 + $0, ageMs: Int64($0) * spreadMs) }
        try await store.insert(specs)
    }

    // MARK: OC-7141

    /// OC-7141. Given 450 items matching filter F (and 30 that do not), when the Library pages through, then pages are
    /// 200, 200, 50, the union is exactly the 450 ids with no duplicate or gap, and the reported count is 450.
    /// Red if the page offset is mis-scaled, the page size changes, or the count is taken from another predicate.
    @Test("OC-7141 450 matches page as 200, 200, 50 with every id once and count 450")
    func oc7141_pagingCoversEveryMatchOnce() async throws {
        // given 450 images (oldest last) and 30 text decoys
        let store = try await Store.make()
        defer { store.cleanUp() }
        try await arrange(store, kind: .image, count: 450, decoys: 30)

        // when the Library pages through the image filter
        let listing = try await store.database.listing(LibraryQuery(filter: .kind(.image)))

        // then the page sizes, the union and the count are exact
        #expect(listing.pageSizes == [200, 200, 50])
        #expect(listing.ids.count == 450)
        #expect(listing.unique == Set((1...450).map(Store.id)))
        #expect(listing.total == 450)
        // boundaries: the first row of each page is the next one by recency, so nothing is skipped at a seam
        #expect(listing.ids[0] == Store.id(1))
        #expect(listing.ids[199] == Store.id(200))
        #expect(listing.ids[200] == Store.id(201))
        #expect(listing.ids[449] == Store.id(450))
        // and every page reports the same whole-set count, a page past the end is empty
        let beyond = try await store.database.items(matching: LibraryQuery(filter: .kind(.image), page: 3)).get()
        #expect(beyond.rows.isEmpty)
        #expect(beyond.totalCount == 450)
        #expect(!beyond.hasMore)
    }

    /// OC-7141, sort stability. All 450 rows share one timestamp and paste count, so only the id tie-break orders them.
    /// Red if a sort loses its `id ASC` tail: rows then repeat or vanish between pages.
    @Test("OC-7141 every sort pages stably when all sort keys tie")
    func oc7141_tiedKeysPageStably() async throws {
        // given 450 items with identical lastCopiedAt and pasteCount
        let store = try await Store.make()
        defer { store.cleanUp() }
        try await store.insert((1...450).map { Spec(n: $0, kind: .image, ageMs: 5_000) })

        for sort in LibrarySort.allCases {
            // when paged under each sort, then the ids are the 450 exactly once and the order is the id order
            let listing = try await store.database.listing(LibraryQuery(filter: .kind(.image), sort: sort))
            #expect(listing.ids.count == 450, "\(sort)")
            #expect(listing.unique == Set((1...450).map(Store.id)), "\(sort)")
            #expect(listing.ids == (1...450).map(Store.id), "\(sort)")
        }
    }

    /// OC-7141, tie-break independent of insertion order. Given five rows with identical sort keys inserted in the
    /// scrambled order 3, 5, 1, 4, 2 (so rowid order is NOT id order), when listed under each sort, then the order is
    /// the id order 1..5. Red if the `recent` sort loses its `id ASC` tail: tied rows then come back in storage order
    /// (3, 5, 1, 4, 2) and the page order depends on when each row happened to be written.
    @Test("OC-7141 tied rows list in id order whatever order they were stored in")
    func oc7141_tieBreakIgnoresInsertionOrder() async throws {
        // given five tied rows stored out of id order
        let store = try await Store.make()
        defer { store.cleanUp() }
        try await store.insert([3, 5, 1, 4, 2].map { Spec(n: $0, kind: .image, ageMs: 5_000) })

        for sort in LibrarySort.allCases {
            // when listed under each sort, then the ids are 1..5 in id order
            let listing = try await store.database.listing(LibraryQuery(filter: .kind(.image), sort: sort))
            #expect(listing.ids == (1...5).map(Store.id), "\(sort)")
        }
    }

    /// OC-7141, boundaries 0 / 1 / max / max+1 (200 per page). The `hasMore` flag and page count change exactly at 200.
    @Test("OC-7141 0, 1, 200 and 201 matches give 0, 1, 1 and 2 pages")
    func oc7141_pageSizeBoundaries() async throws {
        let cases: [(count: Int, pages: [Int], total: Int)] = [(0, [0], 0), (1, [1], 1), (200, [200], 200), (201, [200, 1], 201)]
        for c in cases {
            // given c.count items of the filtered kind and one decoy
            let store = try await Store.make()
            defer { store.cleanUp() }
            try await store.insert([Spec(n: 9_000)] + (0..<c.count).map { Spec(n: $0 + 1, kind: .color, ageMs: Int64($0)) })

            // when paged, then
            let listing = try await store.database.listing(LibraryQuery(filter: .kind(.color)))
            #expect(listing.pageSizes == c.pages, "\(c.count) matches")
            #expect(listing.total == c.total, "\(c.count) matches")
            #expect(listing.unique == Set((0..<c.count).map { Store.id($0 + 1) }), "\(c.count) matches")
        }
    }

    /// OC-7142, FR-003-12 app list cap (0 / 1 / max / max+1 around 15). Given 14, 15 and 16 distinct source apps with
    /// one item each, when the sidebar is read, then it lists 14, 15 and 15 apps, in key order, and the 16th (the last
    /// key) is the one left out. Red if the cap is 14 (the 15-app case then lists 14) or the cap is dropped.
    @Test("OC-7142 the sidebar lists at most 15 source apps")
    func oc7142_sidebarAppCap() async throws {
        let cases: [(apps: Int, listed: Int)] = [(14, 14), (15, 15), (16, 15)]
        for c in cases {
            // given c.apps items, each from its own app
            let store = try await Store.make()
            defer { store.cleanUp() }
            try await store.insert((1...c.apps).map { Spec(n: $0) })
            try await store.database.pool.write { db in
                for n in 1...c.apps {
                    let key = String(format: "com.test.app%02d", n)
                    try db.execute(
                        sql: "UPDATE item SET sourceBundleId = ?, sourceName = ? WHERE id = ?",
                        arguments: [key, "App \(n)", Store.id(n).uuidString])
                }
            }

            // when the sidebar is read, then exactly the first c.listed keys are listed
            let sidebar = try await store.database.sidebarCounts().get()
            let expected = (1...c.listed).map { String(format: "com.test.app%02d", $0) }
            #expect(sidebar.apps.map(\.identity) == expected.map { .bundle($0) }, "\(c.apps) apps")
            #expect(sidebar.apps.map(\.count) == [Int](repeating: 1, count: c.listed), "\(c.apps) apps")
        }
    }

    // MARK: OC-7142

    private func arrangeMixedLibrary(_ store: Store) async throws -> (work: Int64, home: Int64, unused: Int64) {
        // 12 items: 5 text, 3 image, 2 link, 1 color, 1 bundle; 3 pinned; sources: Xcode 4, Another device 2,
        // Safari 1, and 5 with no usable source (nil, and an empty bundle id)
        try await store.insert([
            Spec(n: 1), Spec(n: 2, pinned: true), Spec(n: 3), Spec(n: 4), Spec(n: 5, pinned: true),
            Spec(n: 6, kind: .image), Spec(n: 7, kind: .image, pinned: true), Spec(n: 8, kind: .image),
            Spec(n: 9, kind: .link, text: "https://example.com"), Spec(n: 10, kind: .link, text: "https://example.org"),
            Spec(n: 11, kind: .color, text: "#FF0000"),
            Spec(n: 12, kind: .bundle, members: [("/tmp/flotsam-8t/a.txt", false)]),
        ])
        try await store.addTags(["Work"], onItem: 1)
        try await store.addTags(["home"], onItem: 2)
        try await store.database.pool.write { db in
            for n in [4, 6, 9] {  // a second tag on three more items: Work covers 1, 4, 6, 9
                try db.execute(
                    sql: "INSERT INTO itemTag (itemId, tagId) SELECT ?, id FROM tag WHERE name = 'Work'",
                    arguments: [Store.id(n).uuidString])
            }
            try db.execute(sql: "INSERT INTO itemTag (itemId, tagId) SELECT ?, id FROM tag WHERE name = 'home'", arguments: [Store.id(7).uuidString])
            try db.execute(sql: "INSERT INTO tag (name, color, createdAt) VALUES ('Spare', 'red', 0)")
            for n in 1...4 {
                try db.execute(
                    sql: "UPDATE item SET sourceBundleId = 'com.apple.dt.Xcode', sourceName = 'Xcode' WHERE id = ?",
                    arguments: [Store.id(n).uuidString])
            }
            for n in 5...6 {
                try db.execute(
                    sql: "UPDATE item SET sourceBundleId = NULL, sourceName = 'Another device' WHERE id = ?",
                    arguments: [Store.id(n).uuidString])
            }
            try db.execute(
                sql: "UPDATE item SET sourceBundleId = 'com.apple.Safari', sourceName = 'Safari' WHERE id = ?",
                arguments: [Store.id(7).uuidString])
            try db.execute(sql: "UPDATE item SET sourceBundleId = '' WHERE id = ?", arguments: [Store.id(8).uuidString])
        }
        let ids = try await store.database.pool.read { db in
            (
                try Int64.fetchOne(db, sql: "SELECT id FROM tag WHERE name = 'Work'")!,
                try Int64.fetchOne(db, sql: "SELECT id FROM tag WHERE name = 'home'")!,
                try Int64.fetchOne(db, sql: "SELECT id FROM tag WHERE name = 'Spare'")!
            )
        }
        return ids
    }

    /// OC-7142. Given a mixed library, when every sidebar entry's count is compared with the rows selecting it returns,
    /// then each count equals its row count, and also equals the literal expected number.
    /// Red if any sidebar count is computed by a predicate that differs from the one the page uses.
    @Test("OC-7142 every sidebar count equals the rows that selecting it lists")
    func oc7142_sidebarCountsEqualRowCounts() async throws {
        // given the mixed library (tags Work x4, home x2, Spare x0)
        let store = try await Store.make()
        defer { store.cleanUp() }
        let tags = try await arrangeMixedLibrary(store)

        // when the sidebar is read and each entry is selected
        let sidebar = try await store.database.sidebarCounts().get()
        let rows: (LibraryFilter) async throws -> Int = { try await store.database.listing(LibraryQuery(filter: $0)).ids.count }

        // then each count is the literal number and the row count agrees
        #expect(sidebar.all == 12)
        #expect(try await rows(.all) == 12)
        #expect(sidebar.pinned == 3)
        #expect(try await rows(.pinned) == 3)
        #expect(sidebar.kinds == [.text: 5, .image: 3, .link: 2, .color: 1, .bundle: 1])
        for (kind, n) in sidebar.kinds { #expect(try await rows(.kind(kind)) == n, "\(kind)") }
        #expect(sidebar.kinds[.richText] == nil)
        #expect(try await rows(.kind(.richText)) == 0)

        #expect(sidebar.tags.map(\.name) == ["home", "Spare", "Work"])
        #expect(sidebar.tags.map(\.count) == [2, 0, 4])
        for tag in sidebar.tags { #expect(try await rows(.tag(tag.id)) == tag.count, "tag \(tag.name)") }
        #expect(sidebar.tags.map(\.id) == [tags.home, tags.unused, tags.work])

        let apps = Dictionary(uniqueKeysWithValues: sidebar.apps.map { ($0.identity, $0.count) })
        #expect(apps == [.bundle("com.apple.dt.Xcode"): 4, .anotherDevice: 2, .bundle("com.apple.Safari"): 1, .unknown: 5])
        for app in sidebar.apps { #expect(try await rows(.sourceApp(app.identity)) == app.count, "app \(app.identity)") }
        // the buckets partition the library: the app counts add up to everything
        #expect(sidebar.apps.map(\.count).reduce(0, +) == 12)
    }

    /// OC-7142, empty library: no entries other than zeros, nothing invented.
    @Test("OC-7142 an empty library has zero counts and no kind, tag or app rows")
    func oc7142_emptyLibrary() async throws {
        let store = try await Store.make()
        defer { store.cleanUp() }
        let sidebar = try await store.database.sidebarCounts().get()
        #expect(sidebar.all == 0)
        #expect(sidebar.pinned == 0)
        #expect(sidebar.kinds.isEmpty)
        #expect(sidebar.tags.isEmpty)
        #expect(sidebar.apps.isEmpty)
    }
}
