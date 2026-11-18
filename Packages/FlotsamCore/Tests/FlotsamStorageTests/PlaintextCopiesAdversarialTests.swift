import Foundation
import Testing
import FlotsamBase
@testable import FlotsamStorage

// TASK-422 QA (Worf): adversarial proof for the destructive paths of FR-007-11 / -13 / -17 (AC-007-17 to -19).
// Each test names the code change that turns it red. Temporary folders only.

@Suite struct PlaintextCopiesAdversarialTests {
    private func exists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path) }
    private func isLink(_ url: URL) -> Bool {
        (try? FileManager.default.destinationOfSymbolicLink(atPath: url.path)) != nil
    }

    private func age(_ url: URL, _ s: Store, ms: Int64) throws {
        let when = s.clock.now().addingTimeInterval(-Double(ms) / 1000)
        try FileManager.default.setAttributes([.creationDate: when, .modificationDate: when], ofItemAtPath: url.path)
    }

    /// A folder outside the data folder holding a file that must never be deleted.
    private func outsideVictim() throws -> (dir: URL, file: URL) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("flotsam-victim-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("precious.txt")
        try Data("precious".utf8).write(to: file)
        return (dir, file)
    }

    /// OC-422-W1. Given symlinks named like a quarantine and like a copy that point outside the data folder, when a
    /// later launch expires copies and then Clear History purges them, then the targets survive. Red if
    /// `existingQuarantineFolders` stops checking the entry kind or removal starts following links.
    @Test func linksNamedLikeCopiesNeverReachTheirTargets() async throws {
        let clock = ManualClock()
        let first = try await Store.make(clock: clock)
        let root = first.root
        defer { first.cleanUp() }
        let victim = try outsideVictim()
        defer { try? FileManager.default.removeItem(at: victim.dir) }
        let quarantineLink = root.appendingPathComponent("corrupt-\(first.clock.millis - 90 * dayMs)")
        try FileManager.default.createSymbolicLink(at: quarantineLink, withDestinationURL: victim.dir)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("pre-migration"), withIntermediateDirectories: true)
        let copyLink = root.appendingPathComponent("pre-migration/flotsam-v1.sqlite")
        try FileManager.default.createSymbolicLink(at: copyLink, withDestinationURL: victim.file)

        let second = try await Store.make(root: root, clock: clock)
        #expect(exists(victim.file), "launch expiry followed a link")
        #expect(isLink(quarantineLink), "a link named corrupt-<digits> is not a folder Flotsam made")

        try await second.insert([Spec(n: 1, ageMs: 60_000)])
        let outcome = try await second.database.clearHistory(range: .allTime, includeExempt: true).get()
        #expect(outcome.deletedCount == 1)
        #expect(exists(victim.file), "Clear History followed a link")
        #expect(isLink(quarantineLink))
        #expect(exists(victim.dir))
    }

    /// OC-422-W2. Given a DIRECTORY named exactly like a copy file (with contents) in pre-migration/, when Clear History
    /// runs, then it is left alone: only files Flotsam wrote are removed. Red if the purge drops the regular-file check
    /// (`DataFolder.preMigrationCopyInfo`) and removeItem deletes the directory tree.
    @Test func aFolderNamedLikeACopyIsNotRemovedByClearHistory() async throws {
        let s = try await Store.make()
        defer { s.cleanUp() }
        try await s.insert([Spec(n: 1, ageMs: 60_000)])
        let inner = try s.plant("pre-migration/flotsam-v1.sqlite/user-notes.txt")
        let folder = inner.deletingLastPathComponent()

        _ = try await s.database.clearHistory(range: .allTime, includeExempt: true).get()

        #expect(exists(folder) && exists(inner))
    }

    /// OC-422-W3. Same, at launch expiry, for an old directory named like a copy.
    @Test func aFolderNamedLikeACopyIsNotRemovedByLaunchExpiry() async throws {
        let clock = ManualClock()
        let first = try await Store.make(clock: clock)
        let root = first.root
        defer { first.cleanUp() }
        let inner = try first.plant("pre-migration/flotsam-v1.sqlite/user-notes.txt")
        let folder = inner.deletingLastPathComponent()
        try age(folder, first, ms: 90 * dayMs)

        _ = try await Store.make(root: root, clock: clock)

        #expect(exists(folder) && exists(inner))
    }

    /// OC-422-W4. Given a launch that quarantines a damaged database, when it opens the fresh one, then an old
    /// pre-migration copy and an old quarantine from before are both kept (a failed/quarantined launch deletes
    /// nothing). Red if the expiry hook runs on the second attempt.
    @Test func aQuarantinedLaunchDeletesNothing() async throws {
        let clock = ManualClock()
        let first = try await Store.make(clock: clock)
        let root = first.root
        defer { first.cleanUp() }
        let oldCopy = try first.plant("pre-migration/flotsam-v1.sqlite", contents: "old-copy")
        try age(oldCopy, first, ms: 90 * dayMs)
        let oldQuarantine = root.appendingPathComponent("corrupt-\(first.clock.millis - 90 * dayMs)")
        try FileManager.default.createDirectory(at: oldQuarantine, withIntermediateDirectories: true)
        try Data("q".utf8).write(to: oldQuarantine.appendingPathComponent("flotsam.sqlite"))
        // Damage the live database: not a SQLite file.
        for url in DataFolder(root: root).databaseFileURLs { try? FileManager.default.removeItem(at: url) }
        try Data(repeating: 0xAB, count: 8192).write(to: root.appendingPathComponent("flotsam.sqlite"))
        let before = first.names(in: root)

        let reopened = try await Store.make(root: root, clock: clock)

        let fresh = reopened.names(in: root).subtracting(before)
        #expect(fresh.filter { $0.hasPrefix("corrupt-") }.count == 1, "the damaged file must have been quarantined: \(fresh)")
        #expect(exists(oldCopy) && exists(oldQuarantine))
    }

    /// OC-422-W5. Given a copy dated in the future (clock skew), when a later launch runs, then it is kept. Red if the
    /// age test uses an absolute difference.
    @Test func aFutureDatedCopyIsKept() async throws {
        let clock = ManualClock()
        let first = try await Store.make(clock: clock)
        let root = first.root
        defer { first.cleanUp() }
        let copy = try first.plant("pre-migration/flotsam-v1.sqlite")
        try age(copy, first, ms: -400 * dayMs)

        _ = try await Store.make(root: root, clock: clock)

        #expect(exists(copy))
    }

    /// OC-422-W6. Given a quarantine named with a stamp too large for Int64 or a far-future stamp, when a launch runs,
    /// then nothing is removed and nothing traps.
    @Test func hugeQuarantineStampsAreNotJudged() async throws {
        let clock = ManualClock()
        let first = try await Store.make(clock: clock)
        let root = first.root
        defer { first.cleanUp() }
        let huge = try first.plant("corrupt-99999999999999999999999/keep.txt")
        let future = try first.plant("corrupt-\(first.clock.millis + 400 * dayMs)/keep.txt")

        _ = try await Store.make(root: root, clock: clock)

        #expect(exists(huge) && exists(future))
    }

    /// OC-422-W7. Given pre-migration/ is itself a link to a folder holding a file named like a copy, when Clear History
    /// runs, then the target is left alone. Red if the purge starts listing through a link.
    @Test func aLinkedPreMigrationFolderIsNotPurgedThrough() async throws {
        let s = try await Store.make()
        defer { s.cleanUp() }
        try await s.insert([Spec(n: 1, ageMs: 60_000)])
        let victim = try outsideVictim()
        defer { try? FileManager.default.removeItem(at: victim.dir) }
        let target = victim.dir.appendingPathComponent("flotsam-v1.sqlite")
        try Data("not ours".utf8).write(to: target)
        try? FileManager.default.removeItem(at: s.root.appendingPathComponent("pre-migration"))
        try FileManager.default.createSymbolicLink(at: s.root.appendingPathComponent("pre-migration"), withDestinationURL: victim.dir)

        _ = try await s.database.clearHistory(range: .allTime, includeExempt: true).get()

        #expect(exists(target))
    }

    /// OC-422-W8. Given a copy whose modification date is old but whose creation date is recent (and the reverse), when
    /// a later launch runs, then it is kept: the NEWEST of the two dates ages it (FR-007-17). Red if the age uses the
    /// older date.
    @Test func theNewerOfTheTwoDatesAgesACopy() async throws {
        let clock = ManualClock()
        let first = try await Store.make(clock: clock)
        let root = first.root
        defer { first.cleanUp() }
        let old = first.clock.now().addingTimeInterval(-90 * 86_400)
        let recent = first.clock.now().addingTimeInterval(-3600)
        let oldMtime = try first.plant("pre-migration/flotsam-v1.sqlite")
        // The filesystem lowers the birth date to an older mtime set with it, so set the birth date second.
        try FileManager.default.setAttributes([.modificationDate: old], ofItemAtPath: oldMtime.path)
        try FileManager.default.setAttributes([.creationDate: recent], ofItemAtPath: oldMtime.path)
        let info = try #require(LocalFileSystem().fileInfo(at: oldMtime))
        try #require(info.modifiedAt < info.createdAt!, "arrange: old mtime with a newer birth date")
        let oldBirth = try first.plant("pre-migration/flotsam-v2.sqlite")
        try FileManager.default.setAttributes([.creationDate: old, .modificationDate: recent], ofItemAtPath: oldBirth.path)
        let bothOld = try first.plant("pre-migration/flotsam-v3.sqlite")
        try FileManager.default.setAttributes([.creationDate: old, .modificationDate: old], ofItemAtPath: bothOld.path)

        _ = try await Store.make(root: root, clock: clock)

        #expect(exists(oldMtime) && exists(oldBirth))
        #expect(!exists(bothOld), "arrange check: a copy old on both dates must expire")
    }
}
