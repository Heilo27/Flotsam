import Foundation
import GRDB
import Testing
import FlotsamBase
@testable import FlotsamStorage

// TASK-498 steps 2-3, FRD-001 FR-001-25 (AC-001-25, AC-001-26, AC-001-27), FRD-007 FR-007-03 (schema v2), FRD-004
// FR-004-07 (edit refusal), FRD-005 FR-005-09 (no shortcut or trigger), FRD-003 FR-003-07 and FR-003-09 (mask, search,
// unavailable). Expected values are literals. Each test names the line it guards in its comment, so a mutation of that
// line (break it, see red, restore) has an obvious target; the proofs are recorded on the ticket.
//
// The capture half of AC-001-25 (a concealed copy through ClipboardCapture, the byte-grep of the database, the WAL and
// the log) is in FlotsamCaptureTests/Task498SecureCaptureTests.swift: Storage cannot see Capture.

/// What Storage asks of the vault: only whether the key can be read. Sealing and opening are not Storage's job.
private final class KeyOnlyVault: SecureClipVaulting, @unchecked Sendable {
    private let lock = NSLock()
    private var available: Bool
    init(keyAvailable: Bool = true) { available = keyAvailable }
    func setKeyAvailable(_ value: Bool) { lock.withLock { available = value } }
    var isKeyAvailable: Bool { lock.withLock { available } }
    func seal(_ text: String) -> FlotsamResult<SealedSecret> { .failure(FlotsamError(.libDat002, "not used by Storage")) }
    func open(_ ciphertext: Data) -> FlotsamResult<String> { .failure(FlotsamError(.libDat002, "not used by Storage")) }
}

/// Distinct, printable bytes, so a byte-grep of a file finds the ciphertext the way it would find any BLOB.
private func ciphertext(_ label: String) -> Data { Data("CIPHERTEXT-498-\(label)-0123456789ABCDEF".utf8) }

private let writer = SourceApp(bundleId: "com.example.writer", name: "Writer")

private let editClassifiers = ItemClassifiers(
    editedText: { text in ItemClassification(kind: .text, contentKey: "edit:" + text) },
    fileMember: { path, isDirectory in ItemClassification(kind: isDirectory ? .folder : .file, contentKey: "file:" + path) })

private extension Store {
    /// A store on the shipped schema (v2) with the vault Storage consults for "is the key there".
    static func makeSecure(vault: (any SecureClipVaulting)?) async throws -> Store {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("flotsam-498-\(UUID().uuidString)")
        let clock = ManualClock()
        let logs = RecordingLogSink()
        let database = try await FlotsamDatabase.open(
            folder: root, fileSystem: LocalFileSystem(), clock: clock, logSink: logs, secureVault: vault,
            migrations: Migrations.all).get()
        return Store(root: root, clock: clock, database: database, logs: logs)
    }

    /// One secure row through the real ingest path. `agoMs` ages it (it becomes the row's last-copied time).
    @discardableResult
    func ingestSecure(
        _ label: String, source: SourceApp? = writer, agoMs: Int64 = 0, actor: IngestActor
    ) async throws -> UUID {
        let candidate = IngestCandidate(
            secure: SealedSecret(ciphertext: ciphertext(label), fingerprint: "fingerprint-\(label)"), source: source,
            origin: .pasteboard, occurredAt: clock.now().addingTimeInterval(-Double(agoMs) / 1000))
        let result = try await actor.ingest(candidate).get()
        guard case .created(let id) = result.outcome else { throw SecureTestError.notCreated }
        return id
    }

    func ingestActor() -> IngestActor { IngestActor(database: database, settings: SettingsStore(store: MemoryKV())) }

    /// One read through a separate read-only connection. A synchronous wrapper, so the blocking `read` overload is chosen
    /// inside `#expect(try ...)` in an async test.
    func query<T>(_ body: (Database) throws -> T) throws -> T { try reader().read(body) }

    func fileBytes(_ name: String) -> Data { (try? Data(contentsOf: root.appendingPathComponent(name))) ?? Data() }

    /// True when `needle` appears in the database file or its WAL.
    func databaseFilesContain(_ needle: Data) -> Bool {
        ["flotsam.sqlite", "flotsam.sqlite-wal"].contains { fileBytes($0).range(of: needle) != nil }
    }

    /// Folds the WAL into the main file and empties it, the state a long-running app reaches by itself at its
    /// auto-checkpoint, so the file bytes can be compared before and after a deletion.
    func checkpoint() async throws {
        try await database.pool.writeWithoutTransaction { try $0.execute(sql: "PRAGMA wal_checkpoint(TRUNCATE)") }
    }

    func secureCiphertextCount() throws -> Int {
        try reader().read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM item WHERE secureCiphertext IS NOT NULL")! }
    }
}

private enum SecureTestError: Error { case notCreated }

private func failureCode<T>(_ result: FlotsamResult<T>) -> ErrorCode? {
    if case .failure(let error) = result { return error.code }
    return nil
}

// MARK: - Migration v2 (FR-007-03)

@Suite struct SecureClipMigrationTests {
    private func userVersion(_ s: Store) throws -> Int {
        try s.query { try Int.fetchOne($0, sql: "PRAGMA user_version")! }
    }

    private func itemColumns(_ s: Store) throws -> [String: String] {
        try s.query { db in
            Dictionary(uniqueKeysWithValues: try Row.fetchAll(db, sql: "PRAGMA table_info(item)").map { (($0["name"] as String), ($0["type"] as String)) })
        }
    }

    /// Guards `Migrations.all` listing version 2 (user_version 2) and `Schema.createVersion2` adding both columns.
    @Test("AC-001-25 / FR-007-03: a new database is at version 2 with isSecure and secureCiphertext on item")
    func newDatabaseIsVersion2() async throws {
        let s = try await Store.make()
        defer { s.cleanUp() }

        #expect(try userVersion(s) == 2)
        let columns = try itemColumns(s)
        #expect(columns["isSecure"] == "INTEGER")
        #expect(columns["secureCiphertext"] == "BLOB")
    }

    /// Guards the "Existing rows take the column defaults" contract and `Migrations.all` containing both versions.
    @Test("FR-007-03: a version 1 database upgrades to 2 and keeps every row, none of them secure")
    func versionOneUpgradesKeepingRows() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("flotsam-498-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        do {
            let old = try await Store.make(root: root, migrations: Migrations.baseline)
            try await old.insert([
                Spec(n: 1, ageMs: hourMs, text: "first"), Spec(n: 2, ageMs: 2 * hourMs, pinned: true, text: "second"),
                Spec(n: 3, ageMs: 3 * hourMs, trigger: ";three"),
            ])
            #expect(try userVersion(old) == 1)
            #expect(try itemColumns(old)["isSecure"] == nil)
        }

        let upgraded = try await Store.make(root: root)

        #expect(try userVersion(upgraded) == 2)
        #expect(try upgraded.presentIds() == [1, 2, 3])
        #expect(try upgraded.query { try String.fetchAll($0, sql: "SELECT plainText FROM item ORDER BY id") } == ["first", "second", "item 3"])
        #expect(try upgraded.query { try Int.fetchAll($0, sql: "SELECT isSecure FROM item") } == [0, 0, 0])
        #expect(try upgraded.secureCiphertextCount() == 0)
        #expect(try upgraded.query { try String?.fetchOne($0, sql: "SELECT \"trigger\" FROM item WHERE id = ?", arguments: [Store.id(3).uuidString]) ?? nil } == ";three")
        // The upgraded database takes a secure row.
        try await upgraded.ingestSecure("after-upgrade", actor: upgraded.ingestActor())
        #expect(try upgraded.secureCiphertextCount() == 1)
    }

    private func insertSQL(_ extra: String, values: String) -> String {
        """
        INSERT INTO item (id, kind, createdAt, lastCopiedAt, contentKey, byteSize, updatedAt, isSecure\(extra))
        VALUES ('11111111-1111-1111-1111-111111111111', 'text', 0, 0, 'k', 0, 0, 1\(values))
        """
    }

    private func failsWithInvariant(_ s: Store, _ sql: String) async -> Bool {
        do {
            try await s.database.pool.write { try $0.execute(sql: sql) }
            return false
        } catch {
            return String(describing: error).contains("secure item invariant violated")
        }
    }

    /// Guards each term of the `item_secure_insert` trigger condition, one write per term.
    @Test("FR-001-25: the insert trigger refuses a secure row with plain text, a hotkey, a trigger or no ciphertext")
    func insertTriggerRefusesInvariantViolations() async throws {
        let s = try await Store.make()
        defer { s.cleanUp() }

        #expect(await failsWithInvariant(s, insertSQL(", plainText, secureCiphertext", values: ", 'leak', x'0102'")))
        #expect(await failsWithInvariant(s, insertSQL(", hotkeyCode, secureCiphertext", values: ", 5, x'0102'")))
        #expect(await failsWithInvariant(s, insertSQL(", \"trigger\", secureCiphertext", values: ", ';t', x'0102'")))
        #expect(await failsWithInvariant(s, insertSQL("", values: "")))
        #expect(try s.count("item") == 0)

        // The same row with a ciphertext and nothing else is accepted: the triggers refuse only the violations.
        try await s.database.pool.write { try $0.execute(sql: insertSQL(", secureCiphertext", values: ", x'0102'")) }
        #expect(try s.count("item") == 1)
    }

    /// Guards each term of the `item_secure_update` trigger condition on an existing secure row.
    @Test("FR-001-25: the update trigger refuses giving a secure row plain text, a hotkey, a trigger or no ciphertext")
    func updateTriggerRefusesInvariantViolations() async throws {
        let s = try await Store.make()
        defer { s.cleanUp() }
        let id = try await s.ingestSecure("update-target", actor: s.ingestActor())
        let key = id.uuidString

        #expect(await failsWithInvariant(s, "UPDATE item SET plainText = 'leak' WHERE id = '\(key)'"))
        #expect(await failsWithInvariant(s, "UPDATE item SET hotkeyCode = 5 WHERE id = '\(key)'"))
        #expect(await failsWithInvariant(s, "UPDATE item SET \"trigger\" = ';t' WHERE id = '\(key)'"))
        #expect(await failsWithInvariant(s, "UPDATE item SET secureCiphertext = NULL WHERE id = '\(key)'"))
        #expect(try s.query { try Data.fetchOne($0, sql: "SELECT secureCiphertext FROM item WHERE id = ?", arguments: [key]) } == ciphertext("update-target"))
        #expect(try s.query { try String?.fetchOne($0, sql: "SELECT plainText FROM item WHERE id = ?", arguments: [key]) ?? nil } == nil)
    }

    /// Guards `CHECK (isSecure IN (0, 1))`.
    @Test("FR-007-03: isSecure only takes 0 or 1")
    func isSecureIsABoolean() async throws {
        let s = try await Store.make()
        defer { s.cleanUp() }

        let rejected: Bool
        do {
            try await s.database.pool.write {
                try $0.execute(sql: """
                    INSERT INTO item (id, kind, createdAt, lastCopiedAt, contentKey, byteSize, updatedAt, isSecure)
                    VALUES ('22222222-2222-2222-2222-222222222222', 'text', 0, 0, 'k2', 0, 0, 2)
                    """)
            }
            rejected = false
        } catch { rejected = true }

        #expect(rejected)
    }
}

// MARK: - Edit and exemption refusals (AC-001-26)

@Suite struct SecureClipRefusalTests {
    /// Guards the `isSecure` guard in `editText`. Without it the edit reaches the UPDATE and the schema trigger aborts it,
    /// so the caller would get `STO-DB-001` instead of `ORG-VAL-003`.
    @Test("AC-001-26: editing a secure item is ORG-VAL-003 and changes nothing")
    func editTextIsRefused() async throws {
        let s = try await Store.makeSecure(vault: KeyOnlyVault())
        defer { s.cleanUp() }
        let id = try await s.ingestSecure("edit-target", actor: s.ingestActor())
        let before = try s.query { try Row.fetchOne($0, sql: "SELECT updatedAt, contentKey, secureCiphertext FROM item WHERE id = ?", arguments: [id.uuidString])! }

        let result = await s.database.editText(id: id, to: "new text", classifiers: editClassifiers)

        #expect(failureCode(result) == .orgVal003)
        let after = try s.query { try Row.fetchOne($0, sql: "SELECT updatedAt, contentKey, secureCiphertext, plainText FROM item WHERE id = ?", arguments: [id.uuidString])! }
        #expect((after["updatedAt"] as Int64) == (before["updatedAt"] as Int64))
        #expect((after["contentKey"] as String) == "secure:fingerprint-edit-target")
        #expect((after["secureCiphertext"] as Data) == ciphertext("edit-target"))
        #expect((after["plainText"] as String?) == nil)
    }

    /// Guards `ExemptionEdit.setsBinding` and the `isSecure, edit.setsBinding` check in `applyExemptionEdit`.
    @Test("AC-001-26: giving a secure item a trigger or a hotkey is TRG-VAL-006 and changes nothing")
    func triggerAndHotkeyAreRefused() async throws {
        let s = try await Store.makeSecure(vault: KeyOnlyVault())
        defer { s.cleanUp() }
        let id = try await s.ingestSecure("binding-target", actor: s.ingestActor())

        let trigger = await s.database.applyExemptionEdit(.setTrigger(";pw"), to: id)
        let hotkey = await s.database.applyExemptionEdit(.setHotkey(Chord(keyCode: 5, modifiers: [])), to: id)

        #expect(failureCode(trigger) == .trgVal006)
        #expect(failureCode(hotkey) == .trgVal006)
        #expect(try s.query { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM item WHERE \"trigger\" IS NOT NULL OR hotkeyCode IS NOT NULL")! } == 0)
    }

    /// Guards the other direction of `setsBinding`: pinning and clearing a binding are not refused (a secure row can be
    /// pinned, and clearing the binding it does not have is a no-op, FR-005-09).
    @Test("AC-001-26: pinning a secure item and clearing its (absent) trigger or hotkey are allowed")
    func pinAndClearAreAllowed() async throws {
        let s = try await Store.makeSecure(vault: KeyOnlyVault())
        defer { s.cleanUp() }
        let id = try await s.ingestSecure("pin-target", actor: s.ingestActor())

        #expect(try await s.database.applyExemptionEdit(.setPinned(true), to: id).get() == true)
        #expect(try await s.database.applyExemptionEdit(.setTrigger(nil), to: id).get() == true)
        #expect(try await s.database.applyExemptionEdit(.setHotkey(nil), to: id).get() == true)
        #expect(try s.query { try Int.fetchOne($0, sql: "SELECT pinned FROM item WHERE id = ?", arguments: [id.uuidString])! } == 1)
    }
}

// MARK: - Reconcile (AC-001-26)

@Suite struct SecureClipReconcileTests {
    /// Guards `AND isSecure = 0` in `removeMissingBlobRows`. A secure row has no plain text and no representation, which
    /// is exactly what that query calls "emptied"; here a stray representation row whose blob is gone puts it in the
    /// query's path, beside an ordinary item in the same state that must be removed (so the test cannot pass vacuously).
    @Test("AC-001-26: reconcile never deletes a secure item for lacking plain text; it still removes an empty ordinary one")
    func reconcileKeepsSecureRows() async throws {
        let s = try await Store.makeSecure(vault: KeyOnlyVault())
        defer { s.cleanUp() }
        let secure = try await s.ingestSecure("reconcile-target", actor: s.ingestActor())
        try await s.insert(Spec(n: 7, ageMs: hourMs, blobs: 1, repBytes: 10, text: ""))
        try await s.database.pool.write { db in
            try db.execute(
                sql: "INSERT INTO representation (itemId, uti, byteSize, blobName) VALUES (?, 'public.rtf', 10, 'zz/missing.1')",
                arguments: [secure.uuidString])
        }
        try FileManager.default.removeItem(at: s.blobURL(7, 1))

        let outcome = try await s.database.reconcile().get()

        #expect(outcome.missingBlobRowsRemoved == 2)
        #expect(outcome.itemsRemoved == 1)
        #expect(try s.query { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM item WHERE id = ?", arguments: [Store.id(7).uuidString])! } == 0)
        #expect(try s.query { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM item WHERE id = ? AND isSecure = 1", arguments: [secure.uuidString])! } == 1)
        #expect(try s.secureCiphertextCount() == 1)
    }
}

// MARK: - Delete, retention, Clear History (AC-001-26)

@Suite struct SecureClipDeletionTests {
    private let marker = ciphertext("doomed")

    private func arrange() async throws -> (store: Store, doomed: UUID, kept: UUID) {
        let s = try await Store.makeSecure(vault: KeyOnlyVault())
        let actor = s.ingestActor()
        let doomed = try await s.ingestSecure("doomed", agoMs: 31 * dayMs, actor: actor)
        let kept = try await s.ingestSecure("kept", agoMs: hourMs, actor: actor)
        try await s.checkpoint()
        // The detector sees the ciphertext before anything is deleted, so "absent afterwards" is a real finding.
        #expect(s.databaseFilesContain(marker))
        return (s, doomed, kept)
    }

    /// Guards the row removal in `delete(ids:)` and `PRAGMA secure_delete = ON` (the ciphertext's bytes, not just its row).
    @Test("AC-001-26: delete removes the secure row and the ciphertext bytes, and leaves the other secure row")
    func deleteRemovesCiphertext() async throws {
        let (s, doomed, kept) = try await arrange()
        defer { s.cleanUp() }

        let deleted = try await s.database.delete(ids: [doomed]).get()
        try await s.checkpoint()

        #expect(deleted == [doomed])
        #expect(try s.secureCiphertextCount() == 1)
        #expect(try s.query { try String.fetchAll($0, sql: "SELECT id FROM item") } == [kept.uuidString])
        #expect(s.databaseFilesContain(marker) == false)
        #expect(s.databaseFilesContain(ciphertext("kept")))
    }

    /// Guards the retention sweep's selection treating a secure row like any other aged item.
    @Test("AC-001-26: the retention sweep removes an aged secure item with its ciphertext and keeps a recent one")
    func retentionSweepRemovesCiphertext() async throws {
        let (s, _, kept) = try await arrange()
        defer { s.cleanUp() }

        let outcome = try await s.database.runRetentionSweep(preset: .d30, budget: .unlimited).get()
        try await s.checkpoint()

        #expect(outcome.retentionDeleted == 1)
        #expect(try s.query { try String.fetchAll($0, sql: "SELECT id FROM item") } == [kept.uuidString])
        #expect(try s.secureCiphertextCount() == 1)
        #expect(s.databaseFilesContain(marker) == false)
    }

    /// Guards Clear History's scrub (`incremental_vacuum` then `wal_checkpoint(TRUNCATE)`): no checkpoint is run here by
    /// the test, so only Clear History itself can have emptied the WAL of the ciphertext.
    @Test("AC-001-26: Clear History removes every secure item and no ciphertext is left in the database file or its WAL")
    func clearHistoryRemovesCiphertext() async throws {
        let (s, _, _) = try await arrange()
        defer { s.cleanUp() }
        let events = EventCollector(s.database.events)
        try await s.ingestSecure("late", actor: s.ingestActor())

        let outcome = try await s.database.clearHistory(range: .allTime, includeExempt: false).get()

        #expect(outcome.deletedCount == 3)
        #expect(outcome.checkpointCompleted)
        #expect(try s.count("item") == 0)
        #expect(try s.secureCiphertextCount() == 0)
        #expect(events.deletedIds.count == 3)
        for label in ["doomed", "kept", "late"] { #expect(s.databaseFilesContain(ciphertext(label)) == false) }
    }
}

// MARK: - Search, mask, unavailable (AC-001-25, AC-001-27)

@Suite struct SecureClipQueryTests {
    private let secret = "SECRET-MARKER-498-hunter2"

    private func rows(_ s: Store, text: String = "") async throws -> [ItemRow] {
        try await s.database.items(matching: LibraryQuery(text: text)).get().rows
    }

    /// Guards `isSecure ? SecureClip.mask : PrimaryLine.text(...)` in the row builder, and `isSecure` reaching the row.
    @Test("AC-001-25: a secure row shows eight bullets and its source app, never anything of the text")
    func secureRowShowsTheMask() async throws {
        let s = try await Store.makeSecure(vault: KeyOnlyVault())
        defer { s.cleanUp() }
        try await s.ingestSecure("mask", actor: s.ingestActor())

        let page = try await rows(s)

        #expect(page.count == 1)
        #expect(page[0].primaryLine == "\u{2022}\u{2022}\u{2022}\u{2022}\u{2022}\u{2022}\u{2022}\u{2022}")
        #expect(page[0].isSecure)
        #expect(page[0].isUnavailable == false)
        #expect(page[0].sourceName == "Writer")
        #expect(page[0].kind == .text)
    }

    /// Guards the mask branch against a row that did get text (the schema forbids it; the query must not depend on that),
    /// and `!isSecure` in `SearchIndex.refresh`. The schema trigger is dropped on this scratch database only, to reach
    /// the state the two guards exist for.
    @Test("AC-001-25: even a secure row that somehow holds plain text is masked and never matched by search")
    func searchNeverMatchesSecureContent() async throws {
        let s = try await Store.makeSecure(vault: KeyOnlyVault())
        defer { s.cleanUp() }
        let id = try await s.ingestSecure("search", actor: s.ingestActor())
        try await s.database.pool.write { db in
            try db.execute(sql: "DROP TRIGGER item_secure_update")
            try db.execute(sql: "UPDATE item SET plainText = ? WHERE id = ?", arguments: [secret, id.uuidString])
            try SearchIndex.refresh(db, itemId: id.uuidString)
        }

        #expect(try await rows(s, text: "hunter2").isEmpty)
        #expect(try await rows(s, text: "SECRET-MARKER").isEmpty)
        #expect(try await s.database.count(filter: .all, text: "hunter2").get() == 0)
        let all = try await rows(s)
        #expect(all.map(\.primaryLine) == ["\u{2022}\u{2022}\u{2022}\u{2022}\u{2022}\u{2022}\u{2022}\u{2022}"])
    }

    /// Guards the source-app term still reaching the index for a secure row (FR-003-09: source app filters still work).
    @Test("AC-001-25: searching the source app name still finds the secure item")
    func sourceAppSearchStillWorks() async throws {
        let s = try await Store.makeSecure(vault: KeyOnlyVault())
        defer { s.cleanUp() }
        try await s.ingestSecure("source", source: SourceApp(bundleId: "com.example.vault", name: "VaultApp"), actor: s.ingestActor())

        #expect(try await rows(s, text: "VaultApp").count == 1)
        #expect(try await rows(s, text: "Nonexistent").isEmpty)
    }

    /// Guards `markingUnavailable`: the label replaces the mask, the flag is set, and the row stays (no crash, no error).
    @Test("AC-001-27: with the key gone the secure row reads Unavailable; with the key back it is masked again")
    func missingKeyGivesUnavailableRow() async throws {
        let vault = KeyOnlyVault()
        let s = try await Store.makeSecure(vault: vault)
        defer { s.cleanUp() }
        try await s.ingestSecure("unavailable", actor: s.ingestActor())
        try await s.insert(Spec(n: 9, ageMs: hourMs, text: "ordinary"))

        vault.setKeyAvailable(false)
        let without = try await rows(s)
        vault.setKeyAvailable(true)
        let with = try await rows(s)

        let secureWithout = try #require(without.first { $0.isSecure })
        #expect(secureWithout.isUnavailable)
        #expect(secureWithout.primaryLine == "Unavailable")
        #expect(without.first { !$0.isSecure }?.isUnavailable == false)
        #expect(without.first { !$0.isSecure }?.primaryLine == "ordinary")
        let secureWith = try #require(with.first { $0.isSecure })
        #expect(secureWith.isUnavailable == false)
        #expect(secureWith.primaryLine == "\u{2022}\u{2022}\u{2022}\u{2022}\u{2022}\u{2022}\u{2022}\u{2022}")
    }

    /// Guards the "nil vault reads the same way" contract: a database opened with no key source has no key.
    @Test("AC-001-27: a database opened without a vault shows its secure rows as Unavailable")
    func noVaultMeansUnavailable() async throws {
        let s = try await Store.makeSecure(vault: nil)
        defer { s.cleanUp() }
        try await s.ingestSecure("novault", actor: s.ingestActor())

        let page = try await rows(s)

        #expect(page.count == 1)
        #expect(page[0].isUnavailable)
        #expect(page[0].primaryLine == "Unavailable")
    }

    /// Guards `guard !isSecure` in `ItemContent.storedRepresentations`: nothing to drag or paste plainly from a secure item.
    @Test("AC-001-25: content(of:) carries the ciphertext and hands out no representation to paste or drag")
    func contentHasNoStoredRepresentation() async throws {
        let s = try await Store.makeSecure(vault: KeyOnlyVault())
        defer { s.cleanUp() }
        let id = try await s.ingestSecure("content", actor: s.ingestActor())

        let content = try await s.database.content(of: id).get()

        #expect(content.isSecure)
        #expect(content.secureCiphertext == ciphertext("content"))
        #expect(content.plainText == nil)
        #expect(content.storedRepresentations.isEmpty)
    }
}
