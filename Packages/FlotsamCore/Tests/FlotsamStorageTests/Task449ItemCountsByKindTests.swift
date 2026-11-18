import Foundation
import GRDB
import Testing
import FlotsamBase
@testable import FlotsamStorage

// TASK-449: Copy Diagnostics reads per-kind item counts from one Storage query (FR-000-10).

@Suite struct ItemCountsByKindTests {
    @Test("an empty library has no counts")
    func emptyLibrary() async throws {
        let rig = try await Rig.make()
        defer { rig.cleanUp() }

        let counts = try await rig.store.database.itemCountsByKind().get()

        #expect(counts.isEmpty)
    }

    @Test("counts are grouped by kind, and kinds with no items are absent")
    func groupsByKind() async throws {
        let rig = try await Rig.make()
        defer { rig.cleanUp() }
        _ = try await rig.create(rig.text("K-1", "alpha"))
        _ = try await rig.create(rig.text("K-2", "beta"))
        let recolored = try await rig.create(rig.text("K-3", "gamma"))
        _ = try await rig.create(rig.files("K-4", count: 2))
        try await rig.store.database.pool.write { db in
            try db.execute(sql: "UPDATE item SET kind = 'color' WHERE id = ?", arguments: [recolored.uuidString])
        }

        let counts = try await rig.store.database.itemCountsByKind().get()

        #expect(counts == [.text: 2, .color: 1, .bundle: 1])
    }

    @Test("the diagnostics counts equal the sidebar's Type counts")
    func matchesSidebar() async throws {
        let rig = try await Rig.make()
        defer { rig.cleanUp() }
        _ = try await rig.create(rig.text("K-1", "alpha"))
        _ = try await rig.create(rig.files("K-2", count: 1))

        let counts = try await rig.store.database.itemCountsByKind().get()
        let sidebar = try await rig.store.database.sidebarCounts().get()

        #expect(counts == sidebar.kinds)
        #expect(counts == [.text: 1, .bundle: 1])
    }
}
