import FlotsamBase
import Foundation

/// What a purge of plaintext database copies did. `failed` counts entries that could not be removed.
struct PlaintextCopyPurge: Equatable {
    var removed = 0
    var failed = 0
    var isComplete: Bool { failed == 0 }
}

/// The two places the data folder keeps full, unencrypted copies of the database beside the live one: the
/// pre-migration backup (FR-007-17) and the corrupt-database quarantine (FR-007-13). Both outlive item deletion, so
/// the rules that end their life live here, in one place: Clear History purges both (FR-007-11), and each expires on
/// its own clock at launch.
extension DataFolder {
    /// A pre-migration copy is deleted at a later launch that did not migrate and opened the database cleanly, but
    /// not before it is this old (FR-007-17). The age floor is the conservative part: it keeps the rollback copy
    /// through at least a week of real use of the new schema.
    static let preMigrationRetentionMillis: Int64 = 7 * TimeSpan.dayMillis
    /// A corrupt-database quarantine is kept this long for recovery, counted from its `corrupt-<ms>` name (FR-007-13).
    static let quarantineRetentionMillis: Int64 = 30 * TimeSpan.dayMillis

    private static let quarantinePrefix = "corrupt-"

    func quarantineURL(stamp: Int64) -> URL { root.appendingPathComponent("\(Self.quarantinePrefix)\(stamp)") }

    /// The creation time encoded in a quarantine folder name; nil for any name Flotsam did not give one (those are
    /// never touched). Digits are ASCII-only and must parse as an `Int64`.
    static func quarantineStamp(named name: String) -> Int64? {
        guard name.hasPrefix(quarantinePrefix) else { return nil }
        let digits = name.dropFirst(quarantinePrefix.count)
        guard !digits.isEmpty, digits.allSatisfy({ ("0"..."9").contains($0) }) else { return nil }
        return Int64(digits)
    }

    /// Quarantine folders Flotsam made: real directories (not links) named exactly `corrupt-<digits>`.
    func existingQuarantineFolders(fileSystem: any FileSystemPort) -> [URL] {
        guard case .success(let entries) = fileSystem.contentsOfDirectory(at: root) else { return [] }
        return entries.filter {
            Self.quarantineStamp(named: $0.lastPathComponent) != nil && fileSystem.fileInfo(at: $0)?.kind == .directory
        }
    }

    /// Clear History: removes every pre-migration copy and every quarantine, whatever the range. A copy made at time T
    /// holds the items as of T, and an item the user clears from "the last hour" may have been in a copy made days ago
    /// (a re-copy only bumps `lastCopiedAt`), so no range can be proven safe to skip. Files in `pre-migration/` that
    /// Flotsam did not name (or that are not regular files), and anything else in the data folder, are never touched.
    func purgePlaintextCopies(fileSystem: any FileSystemPort) -> PlaintextCopyPurge {
        var result = purgePreMigrationCopies(fileSystem: fileSystem) { _ in true }
        for folder in existingQuarantineFolders(fileSystem: fileSystem) {
            record(fileSystem.removeItem(at: folder), into: &result)
        }
        return result
    }

    /// Launch expiry (FR-007-17, FR-007-13). Call only after a clean open on a launch that ran no migration.
    @discardableResult
    func expirePlaintextCopies(fileSystem: any FileSystemPort, now: Date) -> PlaintextCopyPurge {
        let nowMillis = Int64((now.timeIntervalSince1970 * 1000).rounded())
        var result = purgePreMigrationCopies(fileSystem: fileSystem) { info in
            // No readable date: keep it. Newest of the two dates, so a copy that preserved an old mtime is not
            // aged early.
            guard let stamp = [info.createdAt, info.modifiedAt].compactMap({ $0 }).max() else { return false }
            return nowMillis - Int64((stamp.timeIntervalSince1970 * 1000).rounded()) >= Self.preMigrationRetentionMillis
        }
        for folder in existingQuarantineFolders(fileSystem: fileSystem) {
            guard let stamp = Self.quarantineStamp(named: folder.lastPathComponent),
                nowMillis - stamp >= Self.quarantineRetentionMillis
            else { continue }
            record(fileSystem.removeItem(at: folder), into: &result)
        }
        return result
    }

    private func purgePreMigrationCopies(
        fileSystem: any FileSystemPort, where isExpired: (FileInfo) -> Bool
    ) -> PlaintextCopyPurge {
        var result = PlaintextCopyPurge()
        guard case .success(let entries) = fileSystem.contentsOfDirectory(at: preMigrationURL) else { return result }
        for url in entries {
            guard let info = Self.preMigrationCopyInfo(at: url, fileSystem: fileSystem), isExpired(info) else { continue }
            record(fileSystem.removeItem(at: url), into: &result)
        }
        return result
    }

    private func record(_ outcome: FlotsamResult<Void>, into result: inout PlaintextCopyPurge) {
        if case .success = outcome { result.removed += 1 } else { result.failed += 1 }
    }
}
