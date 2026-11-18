import Foundation
import Testing
import FlotsamBase
@testable import FlotsamStorage

// S2 harness (b): Library search latency on a seeded 50,000-item database. Measurement only.
//
// What is measured: the wall time of one `FlotsamDatabase.items(matching:)` call (the single query API the Library and
// the Shelf both use, FR-007-18): `LibraryQuery(filter: .all, text:, sort: .recent, page: 0)`. That is a read transaction
// that returns the first page (200 rows) and the total count. It includes the missing-file check for file rows (none
// are seeded). It excludes anything the view model or SwiftUI does with the page.
//
// Seeding reuses `Store` / `Spec` from the storage suite's DestructiveFixture.swift (symlinked into this target, which
// is the helper Unmapped007TimingTests OC-7131/7140 seed through), so there is one seeding implementation. The database
// is a temporary folder under the system temp directory and is removed at the end.

private let itemCount = 50_000

/// A vocabulary of ordinary clipboard words. All lowercase ASCII: the seed writes `searchText` directly, and the query
/// layer normalises the query to the same form, so what matches is exactly what a user's lowercase text would match.
private let words = [
    "the", "and", "meeting", "project", "invoice", "report", "budget", "review", "email", "notes", "draft", "update",
    "schedule", "client", "team", "today", "please", "send", "thanks", "order", "summary", "quarterly", "design", "code",
    "function", "error", "config", "release", "build", "table", "customer", "payment", "status", "ticket", "deploy",
    "server", "request", "response", "token", "session", "window", "folder", "document", "paragraph", "sentence",
]

/// The text of item `n`: 4 to 25 words, a unique `ref<n>` token, and a few injected shapes at fixed rates so every
/// query below has a known, non-trivial answer. About 4% of items are long (around 2 KB), the rest a line or two.
private func seedText(_ n: Int, _ rng: inout SplitMix64) -> String {
    let count = 4 + Int(rng.next() % 22)
    var parts = (0..<count).map { _ in words[Int(rng.next() % UInt64(words.count))] }
    parts.append("ref\(n)")
    if n % 10 == 3 { parts.append("https://example.com/p/\(n)") }
    if n % 20 == 7 { parts.append("name\(n)@example.com") }
    if n % 5_000 == 17 { parts.append("zephyrquartz") }
    var text = parts.joined(separator: " ")
    if n % 25 == 0 { text = String(repeating: text + " ", count: 40) }
    return text
}

/// The 20 queries: common word, mid-frequency word, rare word, prefixes, no-hit, multi-token, short, URL, email,
/// mixed case, mid-word, long phrase. `expect` pins the three whose answer is known exactly, so a seeding or query
/// regression cannot silently turn the measurement into timing of an empty result.
private let queries: [(label: String, text: String, expect: ClosedRange<Int>?)] = [
    ("common-word", "the", nil),
    ("mid-word", "meeting", nil),
    ("mid-word-2", "invoice", nil),
    ("rare-word", "zephyrquartz", 10...10),
    ("prefix-5", "quart", nil),
    ("prefix-3", "bud", nil),
    ("nohit-short", "qqqxxyy", 0...0),
    ("nohit-multi", "no such phrase anywhere", 0...0),
    ("two-token", "budget review", nil),
    ("common+rare", "meeting zephyrquartz", nil),
    ("one-char", "e", nil),
    ("two-char", "re", nil),
    ("ref-token", "ref4242", nil),
    ("url", "https://example.com", nil),
    ("email-domain", "@example.com", nil),
    ("mixed-case", "Quarterly Budget", nil),
    ("mid-word-sub", "eport", nil),
    ("five-token", "please send the quarterly report", nil),
    ("exact-email", "name1007@example.com", 1...1),
    ("nohit-long", "xyzzyplughabcdefghijklmnopqrstuvwxyz0123456789", 0...0),
]

@Suite(.serialized, .timeLimit(.minutes(10)))
struct SearchLatencyPerf {
    @Test("PERF search latency over 50,000 items, 20 queries", .enabled(if: perfEnabled))
    func searchLatency() async throws {
        #expect(queries.count == 20)

        // given 50,000 text items in a temporary database
        let s = try await Store.make()
        defer { s.cleanUp() }
        var rng = SplitMix64(seed: 0x5EA2C4)
        let seedStart = nowNs()
        try await s.insert((1...itemCount).map { n in Spec(n: n, ageMs: Int64(n) * 1_000, text: seedText(n, &rng)) })
        let seedMs = milliseconds(from: seedStart, to: nowNs())
        #expect(try await s.database.count(filter: .all).get() == itemCount)

        // when each query runs once (pass 1: the figure reported as the headline), then four more rounds for a steadier
        // figure; every call is a fresh `items(matching:)`
        func run(_ text: String) async throws -> (ms: Double, total: Int) {
            let start = nowNs()
            let page = try await s.database.items(matching: LibraryQuery(filter: .all, text: text, sort: .recent, page: 0)).get()
            return (milliseconds(from: start, to: nowNs()), page.totalCount)
        }
        var firstPass: [Double] = []
        var allRounds: [Double] = []
        var slowest = (label: "", ms: 0.0)
        for round in 1...5 {
            for query in queries {
                let result = try await run(query.text)
                if let expected = query.expect { #expect(expected.contains(result.total), "\(query.label): \(result.total) hits") }
                allRounds.append(result.ms)
                if round == 1 {
                    firstPass.append(result.ms)
                    if result.ms > slowest.ms { slowest = (query.label, result.ms) }
                    print("PERFQ search q=\(query.label) hits=\(result.total) ms=\(fixed(result.ms))")
                }
            }
        }

        // then one parseable line: pass 1 (n=20) first, then all 5 rounds (n=100)
        printPerfLine("search", [
            ("items", "\(itemCount)"), ("n", "\(firstPass.count)"),
            ("p50_ms", fixed(percentile(firstPass, 0.5))), ("p95_ms", fixed(percentile(firstPass, 0.95))),
            ("mean_ms", fixed(mean(firstPass))), ("max_ms", fixed(slowest.ms)), ("slowest", slowest.label),
            ("all_n", "\(allRounds.count)"), ("all_p50_ms", fixed(percentile(allRounds, 0.5))),
            ("all_p95_ms", fixed(percentile(allRounds, 0.95))), ("seed_ms", fixed(seedMs)),
        ])
    }
}
