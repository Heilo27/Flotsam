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

    /// The source to store with an item. A Shelf drop is an explicit user action (FRD-006 FR-006-13), so a drop whose
    /// source application is on the ignored list is stored with no source bundle identifier: the hide rule above can
    /// never match it, and the drop stays visible (FR-008-42). The name is kept, so the row still says where it came
    /// from. Every other origin keeps its source as captured, and an ignored app's clipboard copy never reaches here
    /// (capture gate 4). The list is read at drop time, as at capture.
    static func sourceToStore(origin: CaptureOrigin, source: SourceApp?, ignoredApps: Set<String>) -> SourceApp? {
        guard origin == .shelfDrop, let source, let bundleId = source.bundleId, ignoredApps.contains(bundleId)
        else { return source }
        return SourceApp(bundleId: nil, name: source.name)
    }

    static func sourceToStore(for candidate: IngestCandidate, ignoredApps: Set<String>) -> SourceApp? {
        sourceToStore(origin: candidate.origin, source: candidate.source, ignoredApps: ignoredApps)
    }

    /// A Shelf drop that dedupes onto an existing item wins over the hide (FR-008-42): when the item's stored source is
    /// on the ignored list, its bundle identifier is cleared by the same `sourceToStore` rule, so the item the drop
    /// just bumped is listed and the Shelf can highlight it. The name and everything else stay. Any other origin, and
    /// an item whose source is not ignored, is left exactly as it was.
    static func applyDropSource(_ db: Database, itemId: String, origin: CaptureOrigin, ignoredApps: Set<String>) throws {
        guard origin == .shelfDrop, !ignoredApps.isEmpty,
            let row = try Row.fetchOne(db, sql: "SELECT sourceBundleId, sourceName FROM item WHERE id = ?", arguments: [itemId])
        else { return }
        let existing = SourceApp(bundleId: row["sourceBundleId"], name: row["sourceName"])
        let stored = sourceToStore(origin: origin, source: existing, ignoredApps: ignoredApps)
        guard stored?.bundleId != existing.bundleId else { return }
        try db.execute(sql: "UPDATE item SET sourceBundleId = NULL WHERE id = ?", arguments: [itemId])
    }
}
