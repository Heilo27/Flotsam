import FlotsamBase
import Foundation
import GRDB

extension FlotsamDatabase {
    /// FR-004-01: with a multi-selection, if any selected item is unpinned all become pinned, otherwise all become
    /// unpinned. Decided inside the transaction so a racing change cannot make the result mixed. Returns the state
    /// the items now have (true = pinned); ids that no longer exist are skipped.
    public func togglePinned(ids: [UUID]) async -> FlotsamResult<Bool> {
        await writePinned(ids: ids) { states in !states.allSatisfy { $0 } }
    }

    /// Sets every listed item to `pinned`. Returns the state applied.
    @discardableResult
    public func setPinned(ids: [UUID], pinned: Bool) async -> FlotsamResult<Bool> {
        await writePinned(ids: ids) { _ in pinned }
    }

    /// `decide` sees the current pinned state of every existing item and returns the state to apply to all of them.
    private func writePinned(ids: [UUID], decide: @escaping @Sendable ([Bool]) -> Bool) async -> FlotsamResult<Bool> {
        var seen = Set<UUID>()
        let unique = ids.filter { seen.insert($0).inserted }
        let now = clock.now().epochMillis
        let result: FlotsamResult<(pinned: Bool, touched: Bool)> = await organizeWrite { db in
            var existing: [UUID] = []
            var states: [Bool] = []
            for id in unique {
                guard let pinned = try Bool.fetchOne(
                    db, sql: "SELECT pinned FROM item WHERE id = ?", arguments: [id.uuidString]) else { continue }
                existing.append(id)
                states.append(pinned)
            }
            let target = decide(states)
            for id in existing {
                _ = try Self.applyExemptionEdit(db, edit: .setPinned(target), id: id, now: now)
            }
            return (target, !existing.isEmpty)
        }
        switch result {
        case .failure(let error): return .failure(error)
        case .success(let outcome):
            if outcome.touched { publishOrganizeChange() }
            return .success(outcome.pinned)
        }
    }
}
