import Foundation
import GRDB
import Testing
import FlotsamBase
@testable import FlotsamStorage

// FRD-004 8T contract tests, slice Remainder (oracle .claude/oracle/frd-004-contract.json): the package-observable half
// of OC-4021 4022 4023 4024 4027 4040 4047 4059 4069. The popover, the editor and the keystrokes are overlays in the App
// target's OrganizeCoordinator (no test target there); what each OC says about STATE (tag counts, chips, limits, which
// kinds are editable, bindings kept, nothing recoverable) is the Storage command underneath, and that is what these drive,
// over a real FlotsamDatabase in a temp folder. The UI halves are listed in FRD004ContractTestsGaps.swift. Expected
// values are literals; state is read back through a fresh query or a second read-only connection.

private let editClassifiers = ItemClassifiers(
    editedText: { ItemClassification(kind: .text, contentKey: "edit:" + $0) },
    fileMember: { path, isDirectory in ItemClassification(kind: isDirectory ? .folder : .file, contentKey: "file:" + path) })

private extension Store {
    func row(_ n: Int) async throws -> ItemRow? {
        try await database.items(matching: LibraryQuery()).get().rows.first { $0.id == Store.id(n) }
    }

    /// name -> (colour, count) for every tag, from the sidebar the popover and the sidebar both read.
    func tagTable() async throws -> [String: String] {
        let tags = try await database.sidebarCounts().get().tags
        return Dictionary(uniqueKeysWithValues: tags.map { ($0.name, "\($0.color ?? "nil"):\($0.count)") })
    }

    func itemCount() async throws -> Int { try await database.sidebarCounts().get().all }
}

@Suite struct FRD004ContractTestsRemainder {

    // MARK: Tag popover state (FR-004-03)

    // OC-4021 (the list's data; the popover's anchoring is App). Red if membership reports the wrong check state, or a
    // tag loses its colour or its count.
    @Test("OC-4021 given tags work (red, on item 1), home (blue, on none) and misc (gray), when the popover data for item 1 is read, then every tag is listed with its colour and count and only work is checked")
    func tagListCarriesCheckColourAndCount() async throws {
        let store = try await Store.make()
        defer { store.cleanUp() }
        try await store.insert([Spec(n: 1), Spec(n: 2), Spec(n: 3)])
        let work = try await store.database.createTag(name: "work", color: .red).get()
        let home = try await store.database.createTag(name: "home", color: .blue).get()
        _ = try await store.database.createTag(name: "misc").get()
        _ = try await store.database.toggleTag(id: work, on: [Store.id(1)]).get()
        // when reading what the popover shows for item 1
        let membership = try await store.database.tagMembership(of: [Store.id(1)]).get()
        // then three tags with their colour dots and counts, and a check on work alone
        #expect(try await store.tagTable() == ["work": "red:1", "home": "blue:0", "misc": "gray:0"])
        #expect(membership == [work: 1])
        #expect(membership[home] == nil)
        // and item 2, which carries nothing, shows no checks
        #expect(try await store.database.tagMembership(of: [Store.id(2)]).get() == [:])
    }

    // OC-4022 (the Create row and Return are App; the create-and-apply is Storage). Red if create-and-apply does not
    // apply, adds the tag twice, or the count is wrong.
    @Test("OC-4022 given item 1 and no tag 'newtag', when 'newtag' is created for it, then the tag count rises 0 to 1, item 1 shows the chip and the tag's count is 1")
    func createAndApplyAddsOneTagAndTheChip() async throws {
        let store = try await Store.make()
        defer { store.cleanUp() }
        try await store.insert([Spec(n: 1), Spec(n: 2)])
        #expect(try await store.tagTable().isEmpty)
        // when
        let id = try await store.database.createTagAndApply(name: "newtag", to: [Store.id(1)]).get()
        // then, read fresh
        #expect(try await store.tagTable() == ["newtag": "gray:1"])
        #expect(try await store.row(1)?.tagNames == ["newtag"])
        #expect(try await store.row(2)?.tagNames == [])
        #expect(try await store.database.tagMembership(of: [Store.id(1)]).get() == [id: 1])
    }

    // OC-4023 (picking the first match is App; the toggle it calls is Storage). Red if toggling an existing tag creates
    // a second tag or leaves the item without its chip.
    @Test("OC-4023 given tag 'work' and an item without it, when 'work' is toggled on, then the item gains the 'work' chip and the tag count stays 1")
    func togglingAnExistingTagCreatesNothing() async throws {
        let store = try await Store.make()
        defer { store.cleanUp() }
        try await store.insert([Spec(n: 1)])
        let work = try await store.database.createTag(name: "work").get()
        #expect(try await store.row(1)?.tagNames == [])
        // when
        #expect(try await store.database.toggleTag(id: work, on: [Store.id(1)]).get() == true)
        // then
        #expect(try await store.row(1)?.tagNames == ["work"])
        #expect(try await store.tagTable() == ["work": "gray:1"])
    }

    // OC-4024. Red if a toggle changes any count by other than exactly 1, touches another tag, or a second toggle does
    // not take it off again.
    @Test("OC-4024 given tags a and b on 3 items, when a is toggled onto item 1 then item 2, then a's count goes 0, 1, 2 exactly, b stays 0, and toggling item 2 again drops a to 1")
    func eachToggleMovesTheCountByExactlyOne() async throws {
        let store = try await Store.make()
        defer { store.cleanUp() }
        try await store.insert([Spec(n: 1), Spec(n: 2), Spec(n: 3)])
        let a = try await store.database.createTag(name: "a").get()
        _ = try await store.database.createTag(name: "b").get()
        #expect(try await store.tagTable() == ["a": "gray:0", "b": "gray:0"])
        // when
        _ = try await store.database.toggleTag(id: a, on: [Store.id(1)]).get()
        #expect(try await store.tagTable() == ["a": "gray:1", "b": "gray:0"])
        _ = try await store.database.toggleTag(id: a, on: [Store.id(2)]).get()
        #expect(try await store.tagTable() == ["a": "gray:2", "b": "gray:0"])
        // then toggling item 2 off again leaves item 1 tagged
        #expect(try await store.database.toggleTag(id: a, on: [Store.id(2)]).get() == false)
        #expect(try await store.tagTable() == ["a": "gray:1", "b": "gray:0"])
        #expect(try await store.row(1)?.tagNames == ["a"])
        #expect(try await store.row(2)?.tagNames == [])
        #expect(try await store.row(3)?.tagNames == [])
    }

    // OC-4027. Red if reading the popover data for an item invents a tag or writes to the item.
    @Test("OC-4027 given no tags and one item, when the popover data is read, then there are no tag rows, no memberships and the item is unchanged")
    func noTagsMeansNoRowsAndNoWrite() async throws {
        let store = try await Store.make()
        defer { store.cleanUp() }
        try await store.insert([Spec(n: 1)])
        let before = try await store.row(1)
        // when
        let membership = try await store.database.tagMembership(of: [Store.id(1)]).get()
        // then
        #expect(membership.isEmpty)
        #expect(try await store.database.sidebarCounts().get().tags.isEmpty)
        #expect(try await store.row(1) == before)
        #expect(before?.tagNames == [])
    }

    // MARK: Note counter limit (FR-004-06)

    // OC-4040 (the counter label is App/Library; the number it counts against is Storage's). Red if the ceiling moves from
    // 2,000, the counter threshold leaves 90%, or the counting rule stops being the one the save enforces.
    @Test("OC-4040 given the note limits, when read, then the ceiling is 2,000, the counter shows from 1,800, and a 2,000-scalar note is accepted while 2,001 is rejected by the same count")
    func noteLimitIsTwoThousandAndCounterAgreesWithSave() async throws {
        #expect(IngestLimits.maxNoteCharacters == 2000)
        #expect(IngestLimits.noteCounterThreshold == 1800)
        #expect(IngestLimits.noteLength(String(repeating: "a", count: 2000)) == 2000)
        // a ZWJ family emoji is one Character but 7 scalars: the counter and the save both count 7
        #expect(IngestLimits.noteLength("\u{1F468}\u{200D}\u{1F469}\u{200D}\u{1F467}\u{200D}\u{1F466}") == 7)
        let store = try await Store.make()
        defer { store.cleanUp() }
        try await store.insert([Spec(n: 1)])
        // when saving exactly at and one over the count the counter reports
        #expect(try await store.database.setNote(String(repeating: "a", count: 2000), for: Store.id(1)).get() == true)
        let over = await store.database.setNote(String(repeating: "a", count: 1999) + "\u{1F468}\u{200D}\u{1F469}", for: Store.id(1))
        // then the over-limit scalar count is rejected and the 2,000 note is what is stored
        if case .failure(let error) = over { #expect(error.code == .orgVal002) } else { Issue.record("2,002 scalars were accepted") }
        let stored = try await store.reader().read { try String.fetchOne($0, sql: "SELECT note FROM item WHERE id = ?", arguments: [Store.id(1).uuidString]) }
        #expect(stored?.unicodeScalars.count == 2000)
    }

    // MARK: Editable kinds (FR-004-07)

    // OC-4047 (the in-panel editor is App; which kinds open it, and that Save stores plain text for each, is Storage).
    // Red if a text-like kind stops being editable, or a non-text kind becomes editable.
    @Test("OC-4047 given one item of each text-like kind, when each is edited, then each saves its new plain text as text; image, file, folder, bundle and screenshot are not editable and keep their content")
    func everyTextLikeKindEditsAndOthersDoNot() async throws {
        let store = try await Store.make()
        defer { store.cleanUp() }
        let editable: [ItemKind] = [.text, .richText, .link, .color, .phone, .email]
        let fixed: [ItemKind] = [.image, .file, .folder, .bundle, .screenshot]
        #expect(Set(ItemKind.allCases.filter(\.isTextEditable)) == Set(editable))
        for (offset, kind) in (editable + fixed).enumerated() { try await store.insert(Spec(n: offset + 1, kind: kind, text: "orig \(kind.rawValue)")) }
        // when editing every one
        for (offset, kind) in editable.enumerated() {
            let result = try await store.database.editText(id: Store.id(offset + 1), to: "edited \(kind.rawValue)", classifiers: editClassifiers).get()
            #expect(result == .text, "\(kind) edit saved as \(String(describing: result))")
        }
        // then the stored text is the new text for each editable kind
        let texts = try await store.reader().read { try String.fetchAll($0, sql: "SELECT substr(id, 25) || '|' || COALESCE(plainText, '') FROM item") }
        let byNumber = Dictionary(uniqueKeysWithValues: texts.map { line -> (Int, String) in
            let parts = line.split(separator: "|", maxSplits: 1, omittingEmptySubsequences: false)
            return (Int(parts[0])!, String(parts[1]))
        })
        for (offset, kind) in editable.enumerated() { #expect(byNumber[offset + 1] == "edited \(kind.rawValue)") }
        // and every other kind is refused with ORG-VAL-003 and its text is untouched
        for (offset, kind) in fixed.enumerated() {
            let n = editable.count + offset + 1
            let result = await store.database.editText(id: Store.id(n), to: "edited", classifiers: editClassifiers)
            if case .failure(let error) = result { #expect(error.code == .orgVal003, "\(kind)") } else { Issue.record("\(kind) was editable") }
            #expect(byNumber[n] == "orig \(kind.rawValue)")
        }
    }

    // MARK: Edit keeps bindings (FR-004-07)

    // OC-4059 (typing ';x' and pressing H in TextEdit is the OS; what both read is the item's trigger, hotkey and plain
    // text). Red if an edit drops the trigger or hotkey, or leaves the old text for them to insert.
    @Test("OC-4059 given an item 'one' with trigger ';x' and hotkey, when its text is edited to 'two', then the trigger and hotkey are still bound to it and the content they paste reads 'two'")
    func editKeepsTriggerAndHotkeyAndPastesNewText() async throws {
        let store = try await Store.make()
        defer { store.cleanUp() }
        try await store.insert([Spec(n: 1, text: "one"), Spec(n: 2, text: "other")])
        let chord = Chord(keyCode: 4, modifiers: [.command, .option])
        _ = try await store.database.applyExemptionEdit(.setTrigger(";x"), to: Store.id(1)).get()
        _ = try await store.database.applyExemptionEdit(.setHotkey(chord), to: Store.id(1)).get()
        #expect(try await store.database.itemBindings().get().triggers == [Store.id(1): ";x"])
        // when
        _ = try await store.database.editText(id: Store.id(1), to: "two", classifiers: editClassifiers).get()
        // then, read fresh: same bindings on the same item, and the content they expand is the new text
        let bindings = try await store.database.itemBindings().get()
        #expect(bindings.triggers == [Store.id(1): ";x"])
        #expect(bindings.hotkeys == [Store.id(1): chord])
        #expect(try await store.database.content(of: Store.id(1)).get().plainText == "two")
        #expect(try await store.database.content(of: Store.id(2)).get().plainText == "other")
    }

    // MARK: Delete is final (FR-004-09)

    // OC-4069 (Command-Z and the absence of a Trash view are App; that nothing is recoverable is Storage). Red if delete
    // becomes a soft delete: the item's id would remain in a row, or a trash/deleted table would appear.
    @Test("OC-4069 given items 1 to 3, when item 2 is deleted, then its id is in no row of any table and no table is named trash, deleted or undo; items 1 and 3 remain")
    func deleteLeavesNothingToRestore() async throws {
        let store = try await Store.make()
        defer { store.cleanUp() }
        try await store.insert([Spec(n: 1), Spec(n: 2, text: "doomed"), Spec(n: 3)])
        let tag = try await store.database.createTag(name: "t").get()
        _ = try await store.database.toggleTag(id: tag, on: [Store.id(2)]).get()
        _ = try await store.database.setNote("n", for: Store.id(2)).get()
        let id = Store.id(2).uuidString
        func rowsMentioning(_ id: String) throws -> Int {
            try store.reader().read { db in
                var hits = 0
                for table in try String.fetchAll(db, sql: "SELECT name FROM sqlite_master WHERE type = 'table' AND name NOT LIKE 'sqlite_%'") {
                    for row in try Row.fetchAll(db, sql: "SELECT * FROM \"\(table)\"") {
                        if row.databaseValues.contains(where: { String.fromDatabaseValue($0)?.contains(id) == true }) { hits += 1 }
                    }
                }
                return hits
            }
        }
        // control: before the delete the scan sees the item (a scan that cannot find it would pass vacuously)
        #expect(try rowsMentioning(id) >= 2)  // the item row and its itemTag row
        // when
        let removed = try await store.database.delete(ids: [Store.id(2)]).get()
        // then
        #expect(removed == [Store.id(2)])
        #expect(try rowsMentioning(id) == 0)
        #expect(try store.presentIds() == [1, 3])
        let names = try await store.reader().read { try String.fetchAll($0, sql: "SELECT lower(name) FROM sqlite_master") }
        #expect(!names.contains { $0.contains("trash") || $0.contains("deleted") || $0.contains("undo") })
    }
}
