import Foundation
import GRDB
import Testing
import FlotsamBase
@testable import FlotsamStorage

// FRD-007 8T gap suite for search (FR-007-18, FR-003-09), driven through the public query API
// (`FlotsamDatabase.items(matching:)`), never through SearchIndex directly except where a test needs the same call a
// note or tag writer makes. Expected values are literals or come from a reference written here with Foundation only.
//
// Layer note, OC-7144: no Storage writer for notes or tag renames exists yet (FRD-003 / FRD-004 own them). The test
// edits the source column with SQL and then calls `SearchIndex.refresh`, which is the one call the contract says every
// writer makes in its transaction. It proves the refresh half, not that a future writer remembers to call it.
// Layer note, OC-7146 and OC-7147: the "History unavailable" and empty-search screens are UI. Storage's half (the
// failure code, the empty result, the retry) is asserted; the screens are GAP-journey.

@Suite struct SearchGapTests {
    // MARK: OC-7139

    /// Deterministic pseudo-random numbers, so the 50 queries are the same on every run and a failure can be replayed.
    private struct Lcg {
        var state: UInt64
        mutating func next(_ bound: Int) -> Int {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return Int((state >> 33) % UInt64(bound))
        }
    }

    /// Words with accents, capitals and shared prefixes, so folding and substring matching both have work to do.
    private static let vocabulary = [
        "Café", "cafe", "RÉSUMÉ", "resume", "École", "ecole", "naïve", "naive", "Zürich", "zurich", "alpha", "Alphabet",
        "beta", "gamma", "Delta", "delta-force", "invoice", "Invoice-2024", "password", "pass", "report", "REPORT",
        "meeting", "notes", "Señor", "senor", "über", "uber", "Crème", "creme", "brûlée", "brulee", "swift", "SwiftUI",
        "clipboard", "paste", "shelf", "library", "token", "ÅNGSTRÖM", "angstrom", "foo", "bar", "baz",
    ]

    /// Query fragments: whole words and prefixes in both accented and plain spelling.
    private static func queryToken(_ lcg: inout Lcg) -> String {
        let word = vocabulary[lcg.next(vocabulary.count)]
        let chars = Array(word)
        switch lcg.next(3) {
        case 0: return word
        case 1: return String(chars.prefix(max(2, chars.count / 2)))
        default: return String(chars.suffix(max(2, chars.count - 1)))
        }
    }

    /// The reference of the contract: case and diacritic folding with Foundation's own comparison, AND over tokens, over
    /// the plain text (first 10,000 characters) plus the kind label every text item carries as a searchable field.
    private static func referenceMatches(_ text: String, tokens: [String]) -> Bool {
        let haystack = String(text.prefix(10_000)) + "\ntext"
        return tokens.allSatisfy { haystack.range(of: $0, options: [.caseInsensitive, .diacriticInsensitive]) != nil }
    }

    /// OC-7139. Given 10,000 items, when 50 random 1-3 token queries run, then each returns exactly the reference set.
    /// Red if tokens are ORed instead of ANDed, folding is dropped, or paging loses or repeats an id.
    @Test("OC-7139 50 random queries over 10,000 items return exactly the reference set")
    func oc7139_randomQueriesMatchReference() async throws {
        // given 10,000 text items made of 3-8 random vocabulary words, indexed the way ingest indexes them
        let store = try await Store.make()
        defer { store.cleanUp() }
        var lcg = Lcg(state: 7139)
        var texts: [Int: String] = [:]
        var specs: [Spec] = []
        for n in 1...10_000 {
            let words = (0..<(3 + lcg.next(6))).map { _ in Self.vocabulary[lcg.next(Self.vocabulary.count)] }
            let text = words.joined(separator: " ")
            texts[n] = text
            specs.append(Spec(n: n, ageMs: Int64(n), text: text))
        }
        try await store.insert(specs)
        try await store.database.pool.write { db in
            for n in 1...10_000 { try SearchIndex.refresh(db, itemId: Store.id(n).uuidString) }
        }
        #expect(try store.count("item") == 10_000)

        // when 50 queries of 1-3 tokens run through the public search
        var nonTrivial = 0
        var emptyResults = 0
        for _ in 0..<50 {
            let tokens = (0..<(1 + lcg.next(3))).map { _ in Self.queryToken(&lcg) }
            let expected = Set(texts.filter { Self.referenceMatches($0.value, tokens: tokens) }.keys.map(Store.id))
            let listing = try await store.database.matches(tokens.joined(separator: " "))

            // then the ids returned (all pages) equal the reference set, with no duplicates and the same count
            #expect(listing.unique == expected, "query \(tokens)")
            #expect(listing.ids.count == expected.count, "query \(tokens)")
            #expect(listing.total == expected.count, "query \(tokens)")
            if !expected.isEmpty && expected.count < 10_000 { nonTrivial += 1 }
            if expected.isEmpty { emptyResults += 1 }
        }
        // the run is not vacuous: most queries select a proper non-empty subset, and the multi-token ones narrow it
        #expect(nonTrivial >= 30)
        #expect(emptyResults < 20)
    }

    // MARK: OC-7143

    /// OC-7143. Given 'Café Résumé ÉCOLE' (and a decoy with only 'cafe'), when 'cafe', 'RESUME', 'ecole cafe' and
    /// 'cafe zzz' run, then the first three return the item and 'cafe zzz' does not.
    /// Red if diacritic or case folding is dropped, or token matches are ORed instead of ANDed.
    @Test("OC-7143 case and diacritic folding, AND over tokens")
    func oc7143_foldingAndAnd() async throws {
        // given the target item and a decoy that has only one of the words, both stored through real ingest
        let rig = try await Rig.make()
        defer { rig.cleanUp() }
        let target = try await rig.create(rig.text("k-target", "Café Résumé ÉCOLE"))
        let decoy = try await rig.create(rig.text("k-decoy", "cafe latte"))
        let db = rig.store.database

        // when each query runs, then the exact id sets are
        #expect(try await db.matches("cafe").unique == [target, decoy])
        #expect(try await db.matches("RESUME").unique == [target])
        #expect(try await db.matches("ecole cafe").unique == [target])
        #expect(try await db.matches("cafe zzz").unique == [])
        // the accented spelling of the query matches the accented text too (the query is folded the same way)
        #expect(try await db.matches("CAFÉ RÉSUMÉ").unique == [target])
        // and the counts agree with the rows
        #expect(try await db.matches("ecole cafe").total == 1)
        #expect(try await db.matches("cafe zzz").total == 0)
    }

    // MARK: OC-7144

    /// OC-7144. Given an item with tag 'alpha' and note 'beta', when the tag is renamed to 'gamma' and the note set to
    /// 'delta', then 'gamma' and 'delta' find it and 'alpha' and 'beta' no longer do. Partial: see the layer note.
    /// Red if `refresh` stops including tag names or the note, or keeps reading a stale copy.
    @Test("OC-7144 a tag rename and a note edit are searchable at once and the old words stop matching")
    func oc7144_tagRenameAndNoteEditReindex() async throws {
        // given item I tagged 'alpha' with note 'beta', and another item that has neither
        let rig = try await Rig.make()
        defer { rig.cleanUp() }
        let id = try await rig.create(rig.text("k-i", "plain body"))
        let other = try await rig.create(rig.text("k-other", "unrelated"))
        let db = rig.store.database
        try await db.pool.write { dbw in
            try dbw.execute(sql: "INSERT INTO tag (name, color, createdAt) VALUES ('alpha', 'red', 0)")
            try dbw.execute(
                sql: "INSERT INTO itemTag (itemId, tagId) VALUES (?, last_insert_rowid())", arguments: [id.uuidString])
            try dbw.execute(sql: "UPDATE item SET note = 'beta' WHERE id = ?", arguments: [id.uuidString])
            try SearchIndex.refresh(dbw, itemId: id.uuidString)
        }
        #expect(try await db.matches("alpha").unique == [id])
        #expect(try await db.matches("beta").unique == [id])

        // when the tag is renamed and the note replaced, each followed by the refresh a writer performs
        try await db.pool.write { dbw in
            try dbw.execute(sql: "UPDATE tag SET name = 'gamma' WHERE name = 'alpha'")
            try SearchIndex.refresh(dbw, itemId: id.uuidString)
        }
        #expect(try await db.matches("gamma").unique == [id])
        try await db.pool.write { dbw in
            try dbw.execute(sql: "UPDATE item SET note = 'delta' WHERE id = ?", arguments: [id.uuidString])
            try SearchIndex.refresh(dbw, itemId: id.uuidString)
        }

        // then the new words find exactly I, the old words find nothing, and the other item is untouched
        #expect(try await db.matches("gamma").unique == [id])
        #expect(try await db.matches("delta").unique == [id])
        #expect(try await db.matches("alpha").unique == [])
        #expect(try await db.matches("beta").unique == [])
        #expect(try await db.matches("unrelated").unique == [other])
        #expect(try await db.matches("plain").unique == [id])
    }

    // MARK: OC-7145

    /// OC-7145. Given a 12,000 character text with MARK-EARLY at 100 and MARK-LATE at 11,000, when both are searched,
    /// then MARK-EARLY finds the item and MARK-LATE finds nothing. Also the 0/1/max/max+1 edge of the 10,000 limit.
    /// Red if the limit is removed or raised, or counted in bytes or lines.
    @Test("OC-7145 only the first 10,000 characters of plain text are searchable")
    func oc7145_plainTextLimit() async throws {
        // given the 12,000 character item and two items whose marker ends at, and starts after, character 10,000
        let rig = try await Rig.make()
        defer { rig.cleanUp() }
        let long =
            String(repeating: "a", count: 99) + " MARK-EARLY " + String(repeating: "b", count: 10_889) + " MARK-LATE "
            + String(repeating: "c", count: 12_000 - 99 - 12 - 10_889 - 11)
        #expect(long.count == 12_000)
        #expect((long as NSString).range(of: "MARK-EARLY").location == 100)
        #expect((long as NSString).range(of: "MARK-LATE").location == 11_001)
        // the marker occupies characters 9,994...9,999 (last searchable) vs 10,000... (first unsearchable)
        let atLimit = String(repeating: "x", count: 9_994) + "EDGEIN" + String(repeating: "y", count: 2_000)
        let pastLimit = String(repeating: "x", count: 10_000) + "EDGEOUT" + String(repeating: "y", count: 2_000)
        #expect((atLimit as NSString).range(of: "EDGEIN").location + 6 == 10_000)
        #expect((pastLimit as NSString).range(of: "EDGEOUT").location == 10_000)
        let longId = try await rig.create(rig.text("k-long", long))
        let atId = try await rig.create(rig.text("k-at", atLimit))
        let pastId = try await rig.create(rig.text("k-past", pastLimit))
        let db = rig.store.database

        // when the markers are searched, then
        #expect(try await db.matches("MARK-EARLY").unique == [longId])
        #expect(try await db.matches("MARK-LATE").unique == [])
        #expect(try await db.matches("MARK-LATE").total == 0)
        #expect(try await db.matches("EDGEIN").unique == [atId])
        #expect(try await db.matches("EDGEOUT").unique == [])
        // the full text is still stored whole: the limit is a search limit, not a storage limit
        #expect(try rig.row(longId).plainText?.count == 12_000)
        #expect(try rig.row(pastId).plainText?.count == 10_007 + 2_000)
    }

    // MARK: OC-7147

    /// OC-7147. Given any library, when a query matching nothing runs, then 0 rows, count 0, and no error.
    /// The empty search screen itself is UI (GAP-journey). Red if no-match returns an error or a stale/total count, or
    /// if a whitespace-only query stops meaning "no filter".
    @Test("OC-7147 a query matching nothing is a success with 0 rows and count 0")
    func oc7147_noMatchIsEmptyNotError() async throws {
        // given a library of three items
        let rig = try await Rig.make()
        defer { rig.cleanUp() }
        _ = try await rig.create(rig.text("k1", "one"))
        _ = try await rig.create(rig.text("k2", "two"))
        _ = try await rig.create(rig.text("k3", "three"))
        let db = rig.store.database

        // when a query matches nothing, then it is a success whose page is empty and whose counts are 0
        let page = try await db.items(matching: LibraryQuery(text: "zzqqxx-none")).get()
        #expect(page.rows.isEmpty)
        #expect(page.totalCount == 0)
        #expect(!page.hasMore)
        #expect(try await db.count(filter: .all, text: "zzqqxx-none").get() == 0)
        // contrast: the library itself is not empty, and a whitespace-only query selects all of it
        #expect(try await db.count(filter: .all).get() == 3)
        #expect(try await db.matches("   ").total == 3)
        // and an empty database answers the same way
        let empty = try await Rig.make()
        defer { empty.cleanUp() }
        let none = try await empty.store.database.items(matching: LibraryQuery(text: "zzqqxx-none")).get()
        #expect(none.rows.isEmpty && none.totalCount == 0)
    }
}
