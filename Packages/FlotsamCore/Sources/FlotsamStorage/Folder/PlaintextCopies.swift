import FlotsamBase
import Foundation

/// What a purge of plaintext database copies did. `failed` counts entries that could not be removed.
struct PlaintextCopyPurge: Equatable {
    var removed = 0
    var failed = 0
    var isComplete: Bool { failed == 0 }
}

/// The two places the data folder keeps full copies of the database beside the live one (every ordinary clip's text in
/// the clear; a secure clip only as its ciphertext, and its key is in the Keychain, never in a copy): the
/// pre-migration backup (FR-007-17) and the corrupt-database quarantine (FR-007-13). Both outlive item deletion, so
/// the rules that end their life live here, in one place: Clear History purges both (FR-007-11); at launch a
/// pre-migration copy ends when a later launch confirms the migrated database is healthy (FR-007-17), and a quarantine
/// expires on its own 30-day clock (FR-007-13).
extension DataFolder {
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

    /// Written into a quarantine folder when moving the database aside failed partway (FR-007-13), because that launch
    /// fails closed before it can raise `STO-DB-002`. The next launch that opens cleanly raises the notice and removes it.
    static let noticePendingMarkerName = "notice-pending"

    func markNoticePending(in quarantine: URL, fileSystem: any FileSystemPort) {
        _ = fileSystem.writeFile(Data(), to: quarantine.appendingPathComponent(Self.noticePendingMarkerName), permissions: 0o600)
    }

    /// True when a quarantine folder carries the marker; the markers are removed so the notice is raised once. A marker
    /// that cannot be removed is still reported, and is retried at the next launch.
    func consumePendingNotices(fileSystem: any FileSystemPort) -> Bool {
        var found = false
        for folder in existingQuarantineFolders(fileSystem: fileSystem) {
            let marker = folder.appendingPathComponent(Self.noticePendingMarkerName)
            guard fileSystem.fileInfo(at: marker)?.kind == .regular else { continue }
            found = true
            _ = fileSystem.removeItem(at: marker)
        }
        return found
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

    /// Launch cleanup (FR-007-17, FR-007-13). Call only after a clean open on a launch that ran no migration: the
    /// database opened, passed its integrity check and is at the schema version the previous launch migrated to. That
    /// is the confirmation, so:
    /// - every pre-migration copy is deleted at once, with its `-wal` and `-shm`, however young it is; and
    /// - a quarantine is deleted once it is 30 days old by its name.
    /// A launch that failed, quarantined or migrated never reaches here, so the copy stays until a launch confirms.
    /// A pre-migration copy is also kept while any quarantine made after it still stands: that quarantine means a
    /// database was set aside as damaged after the copy was taken, so the live library is not the one the copy led to,
    /// and the copy may be the last good version of the data.
    @discardableResult
    func expirePlaintextCopies(fileSystem: any FileSystemPort, now: Date) -> PlaintextCopyPurge {
        let nowMillis = Int64((now.timeIntervalSince1970 * 1000).rounded())
        var result = PlaintextCopyPurge()
        for folder in existingQuarantineFolders(fileSystem: fileSystem) {
            guard let stamp = Self.quarantineStamp(named: folder.lastPathComponent),
                nowMillis - stamp >= Self.quarantineRetentionMillis
            else { continue }
            record(fileSystem.removeItem(at: folder), into: &result)
        }
        let newestQuarantine = existingQuarantineFolders(fileSystem: fileSystem)
            .compactMap { Self.quarantineStamp(named: $0.lastPathComponent) }.max()
        let copies = purgePreMigrationCopies(fileSystem: fileSystem) { info in
            guard let newestQuarantine else { return true }
            // Newest of the two dates is when the copy was taken (a copy can keep an old mtime). No readable date, or a
            // quarantine at least as new: keep it.
            guard let taken = [info.createdAt, info.modifiedAt].compactMap({ $0 }).max() else { return false }
            return Int64((taken.timeIntervalSince1970 * 1000).rounded()) > newestQuarantine
        }
        result.removed += copies.removed
        result.failed += copies.failed
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
