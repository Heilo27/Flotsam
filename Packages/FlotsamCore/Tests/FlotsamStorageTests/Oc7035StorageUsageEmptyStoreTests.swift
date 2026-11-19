import Foundation
import Testing
import FlotsamBase
@testable import FlotsamStorage

// OC-7035, the Storage half. LibraryEmptyStoreTests asserts the Library side of the oracle entry ("Library shows 0
// items"); this asserts the other half the entry names: "Storage usage shows total items 0", read through the public
// `storageUsage()` API that Settings > Storage calls (FRD-007 section 8).

@Suite struct Oc7035StorageUsageEmptyStoreTests {
    /// OC-7035 (Storage half). Given a fresh install, when Settings > Storage reads the usage, then total items is 0 and
    /// image bytes is 0 and the database already has a size (the schema's pages); one text then reads as 1 item with
    /// still 0 image bytes, and a 2 MiB image reads as 2 items and exactly 2,097,152 image bytes.
    /// Red if: `storageUsage()` returns a nonzero total or image figure for an empty store, a fixed 0 regardless of the
    /// store (the later reads would stay 0), a database size of 0 (the page counters not read), or an image counted in
    /// the wrong unit.
    @Test("OC-7035 a fresh store's storage usage reads 0 items and 0 image bytes, then follows the store")
    func oc7035_freshStoreUsageIsZero() async throws {
        // given: a fresh store
        let store = try await Store.make()
        defer { store.cleanUp() }

        // when: the Storage pane reads the usage
        let fresh = try await store.database.storageUsage().get()

        // then: nothing is stored, and the figures are the empty ones
        #expect(fresh.totalItems == 0)
        #expect(fresh.imageBytes == 0)
        #expect(fresh.databaseBytes > 0, "a migrated database still occupies pages; saw \(fresh.databaseBytes)")

        // and: the same call sees what arrives, so the zeros were not a fixed answer
        try await store.insert(Spec(n: 1, text: "first ever"))
        let withText = try await store.database.storageUsage().get()
        #expect(withText.totalItems == 1)
        #expect(withText.imageBytes == 0, "a text is not an image")
        try await store.insert(Spec(n: 2, kind: .image, blobs: 1, repBytes: 2_097_152))
        let withImage = try await store.database.storageUsage().get()
        #expect(withImage.totalItems == 2)
        #expect(withImage.imageBytes == 2_097_152)
    }
}
