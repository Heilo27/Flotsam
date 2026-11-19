import Foundation
import GRDB

/// The one read-time rule for ignored apps (FR-008-42). Ignored apps are dropped at capture (FRD-001 FR-001-04 gate 4),
/// but a copy stored before the user added its app to the list is still a row. This fragment hides such a row from
/// every read that lists or counts items, without touching it: take the app off the list and the row is back. It is a
/// WHERE fragment over `item`, defined here and nowhere else, so the Library and Shelf (through `Selection`), the
/// sidebar counts and any later reader (the MCP exposure gate, FRD-010) share one definition of "hidden".
extension FlotsamDatabase {
    /// `nil` when nothing is ignored (no clause to add). A row with no source bundle identifier (a remote clipboard copy,
    /// an unknown source) can never match the list (FRD-001 FR-001-14), so it is always visible. The match is exact, as
    /// at capture. Identifiers are bound as arguments, never spliced into the SQL.
    static func notFromIgnoredApps(_ ignoredApps: Set<String>) -> (sql: String, arguments: StatementArguments)? {
        guard !ignoredApps.isEmpty else { return nil }
        let ignored = ignoredApps.sorted()
        let placeholders = ignored.map { _ in "?" }.joined(separator: ",")
        return (
            "(NULLIF(sourceBundleId, '') IS NULL OR sourceBundleId NOT IN (\(placeholders)))",
            StatementArguments(ignored)
        )
    }
}
