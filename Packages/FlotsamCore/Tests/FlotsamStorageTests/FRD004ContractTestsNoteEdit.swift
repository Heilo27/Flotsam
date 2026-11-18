import Foundation
import GRDB
import Testing
import FlotsamBase
@testable import FlotsamStorage

// FRD-004 8T contract tests, slice NoteEdit (oracle .claude/oracle/frd-004-contract.json): notes (FR-004-06) and text
// edit (FR-004-07, FR-004-08, BR-3). Package half of each OC: the Storage commands behind the note popover and the
// in-panel editor. The popover, the editor window, the Esc and keystroke handling and the pasteboard write are
// App-target UI, listed in FRD004ContractTestsGaps.swift. Expected values are literals; state is read back through a
// second read-only connection (Store.reader) or the public query API, never through the connection that wrote it.
//
// [Spec Drift] OC-4053: the contract names the notice key `organize.edit.formattingRemoved`; FRD-004 FR-004-07 and the
// catalogue name it `ui.organize.editFormattingRemoved`. The FRD is the spec, so the FRD key is asserted and the
// contract key is wrapped in withKnownIssue.

/// What Organize is handed by the composition root, faked the way the capture rules behave: a leading https:// is a
/// link, anything else is text, and the dedupe key is derived from the text alone.
private let editClassifiers = ItemClassifiers(
    editedText: { text in
        ItemClassification(kind: text.hasPrefix("https://") ? .link : .text, contentKey: "edit:" + text)
    },
    fileMember: { path, isDirectory in
        ItemClassification(kind: isDirectory ? .folder : .file, contentKey: "file:" + path)
    })

private func errorCode<T>(_ result: FlotsamResult<T>) -> ErrorCode? {
    if case .failure(let error) = result { return error.code }
    return nil
}

private func message(_ code: ErrorCode) -> String? { FlotsamStrings.text(forKey: code.catalogueKey) }

/// One stored item row, as a second connection sees it.
private struct Stored: Equatable {
    var kind: String
    var plainText: String?
    var note: String?
    var contentKey: String
    var lastCopiedAt: Int64
    var createdAt: Int64
    var updatedAt: Int64
}

private extension Store {
    func stored(_ n: Int) throws -> Stored? {
        try reader().read { db in
            guard let row = try Row.fetchOne(db, sql: "SELECT * FROM item WHERE id = ?", arguments: [Store.id(n).uuidString]) else {
                return nil
            }
            return Stored(
                kind: row["kind"], plainText: row["plainText"], note: row["note"], contentKey: row["contentKey"],
                lastCopiedAt: row["lastCopiedAt"], createdAt: row["createdAt"], updatedAt: row["updatedAt"])
        }
    }

    /// Item numbers (trailing digits of the fixture id) in the order the public listing returns them.
    func order(_ filter: LibraryFilter = .all, sort: LibrarySort = .recent, text: String = "") async throws -> [Int] {
        try await database.listing(LibraryQuery(filter: filter, text: text, sort: sort)).ids.map { Int(String($0.uuidString.suffix(12)))! }
    }

    func kindCount(_ kind: ItemKind) async throws -> Int {
        try await database.sidebarCounts().get().kinds[kind] ?? 0
    }
}

@Suite struct FRD004ContractTestsNoteEdit {

    // MARK: Notes (FR-004-06)

    // OC-4038. Red if the note ceiling stops being enforced (2,001 characters saved) or the rejection overwrites the old note.
    @Test("OC-4038 given an item with note 'kept', when a 2,001-character note is saved, then ORG-VAL-002 with its message and the stored note is still 'kept'")
    func noteOverCeilingRejectedAndStoredNoteUnchanged() async throws {
        let store = try await Store.make()
        defer { store.cleanUp() }
        try await store.insert([Spec(n: 1), Spec(n: 2)])
        _ = try await store.database.setNote("kept", for: Store.id(1)).get()

        let result = await store.database.setNote(String(repeating: "n", count: 2001), for: Store.id(1))

        #expect(errorCode(result) == .orgVal002)
        #expect(message(.orgVal002) == "Notes can be up to 2,000 characters.")
        #expect(try store.stored(1)?.note == "kept")
        #expect(try store.stored(2)?.note == nil)
        #expect(try store.count("item") == 2)
    }

    // OC-4039. Red if the ceiling check becomes `>=` (a 2,000-character note is refused) or the note is truncated.
    @Test("OC-4039 given an item, when exactly 2,000 characters are saved as its note, then the call succeeds and all 2,000 are stored")
    func noteAtCeilingSavedInFull() async throws {
        let store = try await Store.make()
        defer { store.cleanUp() }
        try await store.insert(Spec(n: 1))
        let full = String(repeating: "n", count: 2000)

        let result = await store.database.setNote(full, for: Store.id(1))

        #expect(errorCode(result) == nil)
        #expect(try result.get() == true)
        #expect(try store.stored(1)?.note == full)
        #expect(try await store.reader().read { try Int.fetchOne($0, sql: "SELECT length(note) FROM item WHERE id = ?", arguments: [Store.id(1).uuidString]) } == 2000)
    }

    // OC-4043. Red if saving a note does not refresh the search index (the word would never be findable).
    @Test("OC-4043 given items X and Y and no item holding 'qzxnote', when X gets the note 'staging qzxnote hint', then searching 'qzxnote' lists exactly X")
    func savedNoteIsSearchable() async throws {
        let store = try await Store.make()
        defer { store.cleanUp() }
        try await store.insert([Spec(n: 1, text: "xray"), Spec(n: 2, text: "yankee")])
        #expect(try await store.order(text: "qzxnote") == [])

        _ = try await store.database.setNote("staging qzxnote hint", for: Store.id(1)).get()

        #expect(try await store.order(text: "qzxnote") == [1])
        #expect(try store.stored(1)?.note == "staging qzxnote hint")
    }

    // OC-4044. Red if clearing leaves the note (or its search terms) behind, or deletes the item along with the note.
    @Test("OC-4044 given X with a note holding 'qzxnote', when the note is cleared with '' (and again with nil on a second item), then no note is stored, search finds nothing, and both items still exist")
    func clearingNoteRemovesItAndItsSearchTerms() async throws {
        let store = try await Store.make()
        defer { store.cleanUp() }
        try await store.insert([Spec(n: 1, text: "xray"), Spec(n: 2, text: "yankee")])
        _ = try await store.database.setNote("staging qzxnote hint", for: Store.id(1)).get()
        _ = try await store.database.setNote("also qzxnote", for: Store.id(2)).get()
        #expect(try await store.order(text: "qzxnote").sorted() == [1, 2])

        #expect(try await store.database.setNote("", for: Store.id(1)).get() == true)
        #expect(try await store.database.setNote(nil, for: Store.id(2)).get() == true)

        #expect(try store.stored(1)?.note == nil)
        #expect(try store.stored(2)?.note == nil)
        #expect(try await store.database.content(of: Store.id(1)).get().note == nil)
        #expect(try await store.order(text: "qzxnote") == [])
        #expect(try store.presentIds() == [1, 2])
        #expect(try store.stored(1)?.plainText == "xray")
    }

    // OC-4045. Red if a second save appends to the note, or the old text stays in the search index.
    @Test("OC-4045 given X with note 'first', when 'second' is saved, then the stored note is exactly 'second', 'first' finds nothing and 'second' finds X")
    func secondSaveReplacesTheNote() async throws {
        let store = try await Store.make()
        defer { store.cleanUp() }
        try await store.insert([Spec(n: 1, text: "xray"), Spec(n: 2, text: "yankee")])
        _ = try await store.database.setNote("first", for: Store.id(1)).get()
        #expect(try await store.order(text: "first") == [1])

        _ = try await store.database.setNote("second", for: Store.id(1)).get()

        #expect(try store.stored(1)?.note == "second")
        #expect(try await store.database.content(of: Store.id(1)).get().note == "second")
        #expect(try await store.order(text: "first") == [])
        #expect(try await store.order(text: "second") == [1])
        #expect(try store.count("item") == 2)
    }

    // MARK: Edit text (FR-004-07, FR-004-08)

    // OC-4048. Red if isTextEditable admits any of these kinds (the edit would be applied) or rejection mutates the row.
    @Test("OC-4048 given a non-text item, when it is edited to 'words', then ORG-VAL-003 with its message and the row is unchanged",
          arguments: [ItemKind.image, .screenshot, .file, .folder, .bundle])
    func nonTextKindsCannotBeEdited(kind: ItemKind) async throws {
        let store = try await Store.make()
        defer { store.cleanUp() }
        try await store.insert([Spec(n: 1, kind: kind, ageMs: hourMs), Spec(n: 2, text: "bystander")])
        let before = try #require(try store.stored(1))
        store.clock.advance(ms: 5_000)

        let result = await store.database.editText(id: Store.id(1), to: "words", classifiers: editClassifiers)

        #expect(errorCode(result) == .orgVal003)
        #expect(message(.orgVal003) == "Only text items can be edited, and they can't be empty.")
        #expect(try store.stored(1) == before)
        #expect(try store.stored(2)?.plainText == "bystander")
        #expect(try store.count("item") == 2)
    }

    // OC-4048 (complement). Red if an editable kind is refused: the six kinds FR-004-07 lists must all take an edit.
    @Test("OC-4048 given an item of each editable kind, when edited to 'fresh words', then each is accepted and holds that text",
          arguments: [ItemKind.text, .richText, .link, .color, .phone, .email])
    func editableKindsAreAccepted(kind: ItemKind) async throws {
        let store = try await Store.make()
        defer { store.cleanUp() }
        try await store.insert([Spec(n: 1, kind: kind, text: "before"), Spec(n: 2, text: "bystander")])

        let result = await store.database.editText(id: Store.id(1), to: "fresh words", classifiers: editClassifiers)

        #expect(try result.get() == .text)
        #expect(try store.stored(1)?.plainText == "fresh words")
        #expect(try store.stored(2)?.plainText == "bystander")
    }

    // OC-4049. Red if the non-empty check stops trimming newlines/tabs (a whitespace-only text would be stored).
    @Test("OC-4049 given text item 'hello', when it is edited to only spaces, tabs and newlines, then ORG-VAL-003 and the stored text is still 'hello'; one visible character is accepted")
    func whitespaceOnlyEditRejected() async throws {
        let store = try await Store.make()
        defer { store.cleanUp() }
        try await store.insert([Spec(n: 1, text: "hello"), Spec(n: 2, text: "bystander")])
        let before = try #require(try store.stored(1))

        let spaces = await store.database.editText(id: Store.id(1), to: "   ", classifiers: editClassifiers)
        let mixed = await store.database.editText(id: Store.id(1), to: " \n\t\n  ", classifiers: editClassifiers)

        #expect(errorCode(spaces) == .orgVal003)
        #expect(errorCode(mixed) == .orgVal003)
        #expect(try store.stored(1) == before)
        #expect(try store.stored(1)?.plainText == "hello")

        // Boundary: one visible character among whitespace is the smallest accepted edit.
        #expect(try await store.database.editText(id: Store.id(1), to: " \n x \n", classifiers: editClassifiers).get() == .text)
        #expect(try store.stored(1)?.plainText == " \n x \n")
        #expect(try store.stored(2)?.plainText == "bystander")
    }

    // OC-4050. Red if an empty replacement is accepted (the item's text would be blanked).
    @Test("OC-4050 given text item 'hello', when all its text is deleted and saved, then ORG-VAL-003 and the stored text is still 'hello'")
    func emptyEditRejected() async throws {
        let store = try await Store.make()
        defer { store.cleanUp() }
        try await store.insert([Spec(n: 1, text: "hello"), Spec(n: 2, text: "bystander")])
        let before = try #require(try store.stored(1))

        let result = await store.database.editText(id: Store.id(1), to: "", classifiers: editClassifiers)

        #expect(errorCode(result) == .orgVal003)
        #expect(message(.orgVal003) == "Only text items can be edited, and they can't be empty.")
        #expect(try store.stored(1) == before)
        #expect(try store.count("item") == 2)
    }

    // OC-4053. Red if a save leaves the RTF representation (row or blob) behind, or keeps the old plain text.
    @Test("OC-4053 given a richText item with an RTF representation and a blob, when saved as 'plain now', then no rich representation or blob remains and the content is plain text only; the formatting notice text exists")
    func savingRichTextDropsFormatting() async throws {
        let store = try await Store.make()
        defer { store.cleanUp() }
        var rich = Spec(n: 1, kind: .richText, text: "bold and link")
        rich.blobs = 1
        rich.repBytes = 9
        try await store.insert([rich, Spec(n: 2, text: "bystander")])
        #expect(try await store.database.content(of: Store.id(1)).get().representations.map(\.uti) == ["public.rtf"])
        #expect(store.exists(store.blobURL(1, 1)))

        _ = try await store.database.editText(id: Store.id(1), to: "plain now", classifiers: editClassifiers).get()

        let content = try await store.database.content(of: Store.id(1)).get()
        #expect(content.plainText == "plain now")
        #expect(content.representations.isEmpty)
        #expect(content.kind == .text)
        #expect(try store.representationCount(1) == 0)
        #expect(!store.exists(store.blobURL(1, 1)))
        #expect(try store.stored(2)?.plainText == "bystander")
        // The FRD's key for the editor notice (FR-004-07) resolves to the shipped copy.
        #expect(FlotsamStrings.text(forKey: "ui.organize.editFormattingRemoved") == "Saving removes the formatting. Only plain text is kept.")
        // [Spec Drift] the contract's key is not in the catalogue; the FRD's is.
        withKnownIssue("FRD-004 OC-4053: contract names notice key organize.edit.formattingRemoved; FRD-004 FR-004-07 and the catalogue use ui.organize.editFormattingRemoved") {
            #expect(FlotsamStrings.text(forKey: "organize.edit.formattingRemoved") != nil)
        }
    }

    // OC-4055. Red if the kind is not re-detected on save (the item would stay text and never reach Links).
    @Test("OC-4055 given text item 'hello', when edited to 'https://x.y', then its kind is link: Links count 0 to 1, Text count 1 to 0, and it is listed under Links only")
    func editToUrlBecomesLink() async throws {
        let store = try await Store.make()
        defer { store.cleanUp() }
        try await store.insert(Spec(n: 1, text: "hello"))
        #expect(try await store.kindCount(.link) == 0)
        #expect(try await store.kindCount(.text) == 1)

        _ = try await store.database.editText(id: Store.id(1), to: "https://x.y", classifiers: editClassifiers).get()

        #expect(try await store.kindCount(.link) == 1)
        #expect(try await store.kindCount(.text) == 0)
        #expect(try await store.order(.kind(.link)) == [1])
        #expect(try await store.order(.kind(.text)) == [])
        #expect(try store.stored(1)?.kind == "link")
    }

    // OC-4056. Red if a link edited to plain words keeps the link kind.
    @Test("OC-4056 given link item 'https://x.y', when edited to 'plain words', then it is re-detected as text: Links count 1 to 0, Text count 0 to 1")
    func editLinkToWordsBecomesText() async throws {
        let store = try await Store.make()
        defer { store.cleanUp() }
        try await store.insert(Spec(n: 1, kind: .link, text: "https://x.y"))
        #expect(try await store.kindCount(.link) == 1)
        #expect(try await store.kindCount(.text) == 0)

        _ = try await store.database.editText(id: Store.id(1), to: "plain words", classifiers: editClassifiers).get()

        #expect(try await store.kindCount(.link) == 0)
        #expect(try await store.kindCount(.text) == 1)
        #expect(try await store.order(.kind(.text)) == [1])
        #expect(try store.stored(1)?.kind == "text")
    }

    // OC-4058. Red if editText stores a contentKey the capture path would not compute (the copy would add a row, or
    // the old text would still bump the edited item).
    @Test("OC-4058 given A edited from 'old text' to 'new text', when 'new text' is copied then 'old text', then the first bumps A to the top of Recent with no new row and the second creates a new row (2 to 3)")
    func copyAfterEditDedupesOnTheNewTextOnly() async throws {
        let rig = try await Rig.make()
        defer { rig.cleanUp() }
        let clock = rig.store.clock
        let a = try await rig.create(rig.text("edit:old text", "old text"))
        clock.advance(ms: 1_000)
        let b = try await rig.create(rig.text("key-b", "bee"))
        clock.advance(ms: 1_000)
        _ = try await rig.store.database.editText(id: a, to: "new text", classifiers: editClassifiers).get()
        #expect(try await rig.store.database.listing(LibraryQuery()).ids == [b, a])
        #expect(try rig.store.count("item") == 2)

        clock.advance(ms: 1_000)
        let newCopy = try await rig.ingest.ingest(rig.text("edit:new text", "new text")).get()

        #expect(newCopy.outcome == .bumped(a))
        #expect(try rig.store.count("item") == 2)
        #expect(try await rig.store.database.listing(LibraryQuery()).ids == [a, b])

        clock.advance(ms: 1_000)
        let oldCopy = try await rig.ingest.ingest(rig.text("edit:old text", "old text")).get()

        guard case .created(let c) = oldCopy.outcome else {
            Issue.record("copying 'old text' after the edit should create a new item, got \(oldCopy.outcome)")
            return
        }
        #expect(c != a && c != b)
        #expect(try rig.store.count("item") == 3)
        #expect(try await rig.store.database.content(of: a).get().plainText == "new text")
        #expect(try await rig.store.database.content(of: c).get().plainText == "old text")
    }

    // MARK: Duplicates (FR-004-08)

    // OC-4060. Red if an edit that equals another item's text merges or deletes either row.
    @Test("OC-4060 given A 'aaa' and B 'bbb', when A is edited to 'bbb', then both exist, both read 'bbb', and the item count is still 2")
    func editToAnotherItemsTextKeepsBoth() async throws {
        let store = try await Store.make()
        defer { store.cleanUp() }
        try await store.insert([Spec(n: 1, ageMs: 2 * hourMs, text: "aaa"), Spec(n: 2, ageMs: hourMs, text: "bbb")])
        #expect(try store.count("item") == 2)

        _ = try await store.database.editText(id: Store.id(1), to: "bbb", classifiers: editClassifiers).get()

        #expect(try store.count("item") == 2)
        #expect(try store.presentIds() == [1, 2])
        #expect(try store.stored(1)?.plainText == "bbb")
        #expect(try store.stored(2)?.plainText == "bbb")
        #expect(try store.stored(1)?.contentKey == "edit:bbb")
    }

    // OC-4061. Red if the copy bumps the older duplicate (A), adds a row, or the bump reshuffles A.
    @Test("OC-4061 given A and B both holding 'bbb' (B copied later) among C and D, when 'bbb' is copied again, then the count stays 4, B moves to the top of Recent and A stays below C and D")
    func copyingDuplicateText() async throws {
        let rig = try await Rig.make()
        defer { rig.cleanUp() }
        let clock = rig.store.clock
        let a = try await rig.create(rig.text("edit:aaa", "aaa"))
        clock.advance(ms: 1_000)
        let b = try await rig.create(rig.text("edit:bbb", "bbb"))
        clock.advance(ms: 1_000)
        let c = try await rig.create(rig.text("key-c", "charlie"))
        clock.advance(ms: 1_000)
        let d = try await rig.create(rig.text("key-d", "delta"))
        clock.advance(ms: 1_000)
        _ = try await rig.store.database.editText(id: a, to: "bbb", classifiers: editClassifiers).get()
        #expect(try await rig.store.database.listing(LibraryQuery()).ids == [d, c, b, a])
        let aCopiedBefore = try await rig.store.reader().read {
            try Int64.fetchOne($0, sql: "SELECT lastCopiedAt FROM item WHERE id = ?", arguments: [a.uuidString])
        }

        clock.advance(ms: 1_000)
        let copy = try await rig.ingest.ingest(rig.text("edit:bbb", "bbb")).get()

        #expect(copy.outcome == .bumped(b))
        #expect(try rig.store.count("item") == 4)
        #expect(try await rig.store.database.listing(LibraryQuery()).ids == [b, d, c, a])
        let aCopiedAfter = try await rig.store.reader().read {
            try Int64.fetchOne($0, sql: "SELECT lastCopiedAt FROM item WHERE id = ?", arguments: [a.uuidString])
        }
        #expect(aCopiedAfter == aCopiedBefore)
    }

    // MARK: Edit does not count as a copy (BR-3)

    // OC-4107. Red if editText touches lastCopiedAt (the preview time would change and X would jump to the top of Recent).
    @Test("OC-4107 given X copied 5 hours ago between Y (1 hour) and Z (9 hours), when X is edited a day later, then its copied time is unchanged and X keeps its place under Recent and Oldest")
    func editLeavesCopiedTimeAndPositionAlone() async throws {
        let store = try await Store.make()
        defer { store.cleanUp() }
        try await store.insert([Spec(n: 1, ageMs: 5 * hourMs, text: "xray"), Spec(n: 2, ageMs: hourMs, text: "yankee"), Spec(n: 3, ageMs: 9 * hourMs, text: "zulu")])
        let copiedAt = try #require(try store.stored(1)).lastCopiedAt
        let shownBefore = try await store.database.items(matching: LibraryQuery()).get().rows.first { $0.id == Store.id(1) }?.lastCopiedAt
        #expect(try await store.order(sort: .recent) == [2, 1, 3])
        #expect(try await store.order(sort: .oldest) == [3, 1, 2])
        store.clock.advance(ms: dayMs)

        _ = try await store.database.editText(id: Store.id(1), to: "x-ray edited", classifiers: editClassifiers).get()

        #expect(try store.stored(1)?.lastCopiedAt == copiedAt)
        let shownAfter = try await store.database.items(matching: LibraryQuery()).get().rows.first { $0.id == Store.id(1) }?.lastCopiedAt
        #expect(shownAfter == shownBefore)
        #expect(shownAfter != nil)
        #expect(try await store.order(sort: .recent) == [2, 1, 3])
        #expect(try await store.order(sort: .oldest) == [3, 1, 2])
        #expect(try store.stored(1)?.plainText == "x-ray edited")
        #expect(try store.stored(1)?.updatedAt == store.clock.millis)
    }
}
