import FlotsamBase
import Foundation
import GRDB

/// FR-004-15: what a bundle's name may be, in one place.
enum BundleNameRule {
    /// The stored name: trimmed, 1 to 100 characters, no control characters. nil is `ORG-VAL-005`. An empty result is
    /// not a name: the caller clears the name instead (see `FlotsamDatabase.renameBundle`).
    static func validated(_ raw: String) -> String? {
        let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name.count <= OrganizeLimits.maxBundleNameCharacters else { return nil }
        guard !name.unicodeScalars.contains(where: { $0.properties.generalCategory == .control }) else { return nil }
        return name
    }
}

extension FlotsamDatabase {
    /// FR-004-15: names a bundle. The name replaces the member names in the row's primary line and is searchable.
    /// Blank after trimming clears the name (the row shows its member names again). Over 100 characters or with a
    /// control character is `ORG-VAL-005`. An item that is not a bundle is a caller bug (`SYS-INT-001`), as for Ungroup.
    ///
    /// Returns false when the bundle no longer exists.
    public func renameBundle(id: UUID, to raw: String) async -> FlotsamResult<Bool> {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let stored: String? = trimmed.isEmpty ? nil : BundleNameRule.validated(raw)
        if !trimmed.isEmpty, stored == nil {
            return .failure(FlotsamError(
                .orgVal005, "Bundle name is over the character ceiling or has control characters",
                context: [.count: .int(OrganizeLimits.maxBundleNameCharacters)]))
        }
        let now = clock.now().epochMillis
        let result: FlotsamResult<Bool> = await organizeWrite { db in
            let key = id.uuidString
            guard let kind = try String.fetchOne(db, sql: "SELECT kind FROM item WHERE id = ?", arguments: [key]) else { return false }
            guard kind == ItemKind.bundle.rawValue else {
                throw OrganizeRejection(error: FlotsamError(.sysInt001, "Rename was asked for an item that is not a bundle", context: [.itemId: .id(id)]))
            }
            try db.execute(sql: "UPDATE item SET name = ?, updatedAt = ? WHERE id = ?", arguments: [stored, now, key])
            try SearchIndex.refresh(db, itemId: key)
            return true
        }
        if case .success(true) = result { publishOrganizeChange() }
        return result
    }

    /// The bundle's own name for the rename field; nil when it has none or the item is gone.
    public func bundleName(of id: UUID) async -> FlotsamResult<String?> {
        do {
            let name = try await pool.read { db in
                try String.fetchOne(db, sql: "SELECT name FROM item WHERE id = ?", arguments: [id.uuidString])
            }
            return .success(name)
        } catch {
            return .failure(Self.readFailure(error))
        }
    }
}
