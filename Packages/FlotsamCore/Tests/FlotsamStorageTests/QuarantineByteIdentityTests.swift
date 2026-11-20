import CryptoKit
import Foundation
import GRDB
import Testing
import FlotsamBase
@testable import FlotsamStorage

// FR-007-13: the quarantined database is the file exactly as found. Opening a damaged file must not write to it before it
// is moved aside (TASK-370). Fixtures are built with DestructiveFixture's Store and judged by hashing the bytes on disk.

@Suite struct QuarantineByteIdentityTests {
    private func sha256(_ url: URL) throws -> String {
        SHA256.hash(data: try Data(contentsOf: url)).map { String(format: "%02x", $0) }.joined()
    }

    /// A real multi-page database, checkpointed and closed, then one table leaf page (not page 1) has its first two cell
    /// pointers swapped: the file still opens and reports a version, and only `PRAGMA quick_check` sees the damage.
    private func damagedDatabase() async throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("flotsam-8t-identity-\(UUID().uuidString)")
        let seeded = try await Store.make(root: root, migrations: Migrations.baseline)
        let padding = String(repeating: "x", count: 200)
        try await seeded.insert((1...400).map { Spec(n: $0, text: "identity-row-\($0)-\(padding)") })
        let pageSize = try await seeded.database.pool.read { try Int.fetchOne($0, sql: "PRAGMA page_size")! }
        try await seeded.database.pool.writeWithoutTransaction { try $0.execute(sql: "PRAGMA wal_checkpoint(TRUNCATE)") }
        try seeded.database.pool.close()

        let file = root.appendingPathComponent("flotsam.sqlite")
        var bytes = try Data(contentsOf: file)
        let marker = Data("identity-row-".utf8)
        let pageCount = bytes.count / pageSize
        let leaf = try #require((2...pageCount).first { page in
            let start = (page - 1) * pageSize
            return bytes[start] == 0x0D && bytes.subdata(in: start..<(start + pageSize)).range(of: marker) != nil
        })
        let pointers = (leaf - 1) * pageSize + 8
        let first = bytes.subdata(in: pointers..<(pointers + 2))
        let second = bytes.subdata(in: (pointers + 2)..<(pointers + 4))
        #expect(first != second)
        bytes.replaceSubrange(pointers..<(pointers + 2), with: second)
        bytes.replaceSubrange((pointers + 2)..<(pointers + 4), with: first)
        try bytes.write(to: file)
        return root
    }

    private func quarantineFolder(_ root: URL) throws -> URL {
        let names = try FileManager.default.contentsOfDirectory(atPath: root.path).filter { $0.hasPrefix("corrupt-") }
        #expect(names.count == 1)
        return root.appendingPathComponent(try #require(names.first))
    }

    /// Given a database that opens but fails quick_check, when it is opened, then the file in corrupt-<timestamp>/ has the
    /// same SHA-256 as the file that was there before the open, and a fresh database is live.
    @Test("FR-007-13 a damaged database is quarantined byte-identical to the input")
    func quarantinedDatabaseIsByteIdentical() async throws {
        let root = try await damagedDatabase()
        defer { try? FileManager.default.removeItem(at: root) }
        let before = try sha256(root.appendingPathComponent("flotsam.sqlite"))
        let sizeBefore = try Data(contentsOf: root.appendingPathComponent("flotsam.sqlite")).count

        let database = try await FlotsamDatabase.openBaseline(folder: root).get()

        let preserved = try quarantineFolder(root).appendingPathComponent("flotsam.sqlite")
        #expect(try Data(contentsOf: preserved).count == sizeBefore)
        #expect(try sha256(preserved) == before)
        #expect(database.openNotice?.code == .stoDb002)
        #expect(try await database.pragmaFacts().userVersion == 1)
    }

    /// Given the same damaged database with -wal and -shm files beside it, when it is opened, then the database and the -wal
    /// move into corrupt-<timestamp>/ with the SHA-256 they had before the open, and the -shm moves with them. The -shm is
    /// SQLite's wal-index, a cache rebuilt from the -wal that every connection, read-only ones too, updates in place, so
    /// its bytes are not part of the guarantee.
    @Test("FR-007-13 the -wal is quarantined byte-identical and the -shm moves with the database")
    func quarantinedSidecarsAreByteIdentical() async throws {
        let root = try await damagedDatabase()
        defer { try? FileManager.default.removeItem(at: root) }
        let names = ["flotsam.sqlite", "flotsam.sqlite-wal"]
        // SQLite treats a -wal with no valid header as empty and a -shm as rebuildable, so the bytes are arbitrary
        try Data(repeating: 0xAB, count: 64).write(to: root.appendingPathComponent("flotsam.sqlite-wal"))
        try Data(repeating: 0xCD, count: 32_768).write(to: root.appendingPathComponent("flotsam.sqlite-shm"))
        let before = try Dictionary(uniqueKeysWithValues: names.map { ($0, try sha256(root.appendingPathComponent($0))) })

        let database = try await FlotsamDatabase.openBaseline(folder: root).get()

        let folder = try quarantineFolder(root)
        for name in names {
            #expect(try sha256(folder.appendingPathComponent(name)) == before[name], "\(name) changed before it was moved")
        }
        #expect(FileManager.default.fileExists(atPath: folder.appendingPathComponent("flotsam.sqlite-shm").path))
        #expect(database.openNotice?.code == .stoDb002)
    }
}
