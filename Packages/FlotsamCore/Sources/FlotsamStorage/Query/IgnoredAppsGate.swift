import FlotsamBase
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

    /// The source to store with a new item. A Shelf drop is an explicit user action (FRD-006 FR-006-13), so a drop whose
    /// source application is on the ignored list is stored with no source bundle identifier: the hide rule above can
    /// never match it, and the drop stays visible (FR-008-42). The name is kept, so the row still says where it came
    /// from. Every other origin keeps its source as captured, and an ignored app's clipboard copy never reaches here
    /// (capture gate 4). The list is read at drop time, as at capture.
    static func sourceToStore(for candidate: IngestCandidate, ignoredApps: Set<String>) -> SourceApp? {
        guard candidate.origin == .shelfDrop, let source = candidate.source, let bundleId = source.bundleId,
            ignoredApps.contains(bundleId)
        else { return candidate.source }
        return SourceApp(bundleId: nil, name: source.name)
    }
}
