import Foundation
import FlotsamBase
@testable import FlotsamStorage

// Shared reading helpers for the FRD-007 8T gap suites (search, library query, ingest fault, deletion). Arrangement
// lives in IngestSupport.swift and DestructiveFixture.swift; this file only walks the public query API the way the
// Library does, so a test sees every row a user could scroll to.

struct Listing {
    /// Every row id across every page, in the order the pages returned them (duplicates kept so a test can see them).
    let ids: [UUID]
    /// `totalCount` reported by the first page.
    let total: Int
    /// Rows returned per page, first page first.
    let pageSizes: [Int]

    var unique: Set<UUID> { Set(ids) }
}

extension FlotsamDatabase {
    /// Pages through `query` from page 0 until the page says there is nothing more, like the Library's scroll.
    func listing(_ query: LibraryQuery) async throws -> Listing {
        var ids: [UUID] = []
        var sizes: [Int] = []
        var total = 0
        var page = 0
        while true {
            var next = query
            next.page = page
            let result = try await items(matching: next).get()
            if page == 0 { total = result.totalCount }
            ids += result.rows.map(\.id)
            sizes.append(result.rows.count)
            guard result.hasMore, page < 1_000 else { break }
            page += 1
        }
        return Listing(ids: ids, total: total, pageSizes: sizes)
    }

    func matches(_ text: String, filter: LibraryFilter = .all) async throws -> Listing {
        try await listing(LibraryQuery(filter: filter, text: text))
    }
}
