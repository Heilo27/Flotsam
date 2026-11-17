import Foundation
import Testing
import FlotsamBase
@testable import FlotsamStorage

// FRD-007 8T gap batch, the query layer on an empty store (FR-007-05, FR-007-18). Read through the public query API.
// Gap: "Settings > Storage shows total items 0" is a view of the Settings FRD; no Storage usage API exists in this
// package yet, so only the item count behind it is asserted here (GAP-journey for the Settings view itself).

@Suite struct LibraryEmptyStoreTests {
    /// OC-7035. Given a fresh install, when the Library is queried, then it has 0 rows and 0 total under every filter,
    /// sort and a search, and the sidebar and item count are all zero; one inserted item then shows as exactly 1.
    @Test("OC-7035 a fresh store lists nothing and counts nothing")
    func oc7035_freshStoreIsEmpty() async throws {
        let s = try await Store.make()
        defer { s.cleanUp() }

        let page = try await s.database.items(matching: LibraryQuery()).get()
        #expect(page.rows.isEmpty)
        #expect(page.totalCount == 0)
        #expect(!page.hasMore)
        for sort in LibrarySort.allCases {
            let sorted = try await s.database.items(matching: LibraryQuery(sort: sort)).get()
            #expect(sorted.rows.isEmpty && sorted.totalCount == 0, "sort \(sort)")
        }
        for filter in [LibraryFilter.all, .pinned, .kind(.text), .kind(.image), .tag(1), .sourceApp(.unknown), .sourceApp(.anotherDevice)] {
            #expect(try await s.database.count(filter: filter).get() == 0, "filter \(filter)")
        }
        #expect(try await s.database.items(matching: LibraryQuery(text: "anything")).get().totalCount == 0)
        let sidebar = try await s.database.sidebarCounts().get()
        #expect(sidebar.all == 0)
        #expect(sidebar.pinned == 0)
        #expect(sidebar.kinds.isEmpty)
        #expect(sidebar.tags.isEmpty)
        #expect(sidebar.apps.isEmpty)
        #expect(try s.count("item") == 0)
        #expect(try s.count("representation") == 0)

        // The same queries do see a row once there is one, so the zeros above were not the queries' fixed answer.
        try await s.insert(Spec(n: 1, text: "first ever"))
        let after = try await s.database.items(matching: LibraryQuery()).get()
        #expect(after.rows.map(\.id) == [Store.id(1)])
        #expect(after.totalCount == 1)
        #expect(try await s.database.sidebarCounts().get().all == 1)
        #expect(try await s.database.sidebarCounts().get().kinds == [.text: 1])
        #expect(try s.count("item") == 1)
    }
}
