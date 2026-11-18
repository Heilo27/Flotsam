import Foundation
import Testing
import FlotsamBase
@testable import FlotsamStorage

/// FRD-003 FR-003-10 / AC-003-09 (TASK-177): with 10,000 items, keystroke-to-results p95 is at most 100 ms over 100
/// queries. The query layer (`items(matching:)`, the work a keystroke triggers) is what the test times; the SwiftUI
/// render step is outside the package and cannot be timed here.
@Suite struct SearchPerformanceWorfTests {
    private func percentile(_ sorted: [Double], _ p: Double) -> Double {
        sorted[min(sorted.count - 1, Int((p * Double(sorted.count)).rounded(.up)) - 1)]
    }

    private func seconds(_ d: Duration) -> Double {
        Double(d.components.seconds) + Double(d.components.attoseconds) / 1e18
    }

    /// Red if the search path regresses to a full scan per keystroke (e.g. `SearchIndex` token lookup replaced by an
    /// unindexed LIKE over `searchText`, or the page limit removed) so p95 exceeds 100 ms at 10,000 rows.
    @Test("AC-003-09 search p95 is at most 100 ms over 100 queries at 10,000 items")
    func searchP95At10kItems() async throws {
        // given 10,000 text items whose searchable text is drawn from a deterministic vocabulary
        let store = try await Store.make()
        defer { store.cleanUp() }
        let words = ["alpha", "bravo", "charlie", "delta", "echo", "foxtrot", "golf", "hotel", "india", "juliet",
                     "kilo", "lima", "mike", "november", "oscar", "papa", "quebec", "romeo", "sierra", "tango"]
        var specs: [Spec] = []
        for n in 1...10_000 {
            let a = words[n % words.count], b = words[(n / 7) % words.count], c = words[(n / 31) % words.count]
            specs.append(Spec(n: n, ageMs: Int64(n), text: "\(a) \(b) \(c) note \(n)"))
        }
        try await store.insert(specs)
        try await store.database.pool.write { db in
            for n in 1...10_000 { try SearchIndex.refresh(db, itemId: Store.id(n).uuidString) }
        }
        let total = try await store.database.pool.read { db in try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM item") }
        #expect(total == 10_000)

        // when 100 keystroke-style queries (growing prefixes of vocabulary words) run after a warm-up
        let queries = (0..<100).map { i -> String in
            let word = words[i % words.count]
            return String(word.prefix(2 + (i / words.count) % 4))
        }
        for q in queries.prefix(10) { _ = try await store.database.items(matching: LibraryQuery(text: q)).get() }
        var samples: [Double] = []
        var emptyResults = 0
        let clock = ContinuousClock()
        for q in queries {
            var rows = 0
            let elapsed = try await clock.measure {
                rows = try await store.database.items(matching: LibraryQuery(text: q)).get().rows.count
            }
            if rows == 0 { emptyResults += 1 }
            samples.append(seconds(elapsed))
        }
        samples.sort()

        // then 100 samples were taken, the queries found rows (not a vacuous empty scan), and p95 is within 100 ms
        #expect(samples.count == 100)
        #expect(emptyResults == 0)
        #expect(percentile(samples, 0.95) <= 0.100)
    }
}
