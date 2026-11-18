import Foundation
import GRDB
import Testing
import FlotsamBase
@testable import FlotsamStorage

// Worf, TASK-392 / FR-004-06 / AC-004-06. The note counter (OrganizeOverlays.NoteCard) shows `IngestLimits.noteLength`
// from `IngestLimits.noteCounterThreshold` and turns red above `maxNoteCharacters`; save is `setNote`. These tests drive
// the REAL database and read the stored note back through a fresh read-only connection. Expected values are literals
// (1,800 / 2,000 / scalar counts computed by hand), not production expressions. Each test names the change that turns it red.

private let family = "\u{1F468}\u{200D}\u{1F469}\u{200D}\u{1F467}\u{200D}\u{1F466}"  // 1 Character, 7 scalars
private let eAcute = "e\u{301}"                                                      // 1 Character, 2 scalars
private let grin = "\u{1F600}"                                                       // 1 Character, 1 scalar, 2 UTF-16 units, 4 UTF-8 bytes

private func code<T>(_ result: FlotsamResult<T>) -> ErrorCode? {
    if case .failure(let error) = result { return error.code }
    return nil
}

@Suite struct WorfNoteCounterBoundaryTests {
    private func storedNote(_ store: Store) throws -> String? {
        try store.reader().read { try String.fetchOne($0, sql: "SELECT note FROM item WHERE id = ?", arguments: [Store.id(1).uuidString]) }
    }

    // Red if the 90% threshold or the ceiling is re-hard-coded to a different number, or noteLength stops being literal scalars.
    @Test("OC-4060 given the constants, then the limit is 2,000 and the counter threshold is 1,800")
    func constants() {
        #expect(IngestLimits.maxNoteCharacters == 2000)
        #expect(IngestLimits.noteCounterThreshold == 1800)
    }

    // Red if noteLength counts Characters (the old behavior) or UTF-16 units / bytes.
    @Test("OC-4061 given strings of known scalar structure, then noteLength is the scalar count")
    func scalarCounting() {
        #expect(IngestLimits.noteLength("") == 0)
        #expect(IngestLimits.noteLength("abc") == 3)
        #expect(IngestLimits.noteLength(eAcute) == 2)
        #expect(IngestLimits.noteLength("\u{E9}") == 1)  // precomposed é: 1 scalar
        #expect(IngestLimits.noteLength(family) == 7)
        #expect(IngestLimits.noteLength(grin) == 1)
        #expect(IngestLimits.noteLength("\r\n") == 2)    // one Character, two scalars
        #expect(IngestLimits.noteLength(String(repeating: family, count: 1000)) == 7000)
    }

    // Red if save and the counter's unit disagree at the ceiling, in either direction, for ASCII.
    @Test("OC-4062 given ASCII, when exactly 2,000 then saved and when 2,001 then ORG-VAL-002 with the prior note kept")
    func asciiCeiling() async throws {
        let store = try await Store.make()
        defer { store.cleanUp() }
        try await store.insert(Spec(n: 1))
        let atMax = String(repeating: "a", count: 2000)
        #expect(IngestLimits.noteLength(atMax) == 2000)
        #expect(try await store.database.setNote(atMax, for: Store.id(1)).get() == true)
        #expect(try storedNote(store) == atMax)

        let over = atMax + "a"
        #expect(IngestLimits.noteLength(over) == 2001)
        #expect(code(await store.database.setNote(over, for: Store.id(1))) == .orgVal002)
        #expect(try storedNote(store) == atMax)  // rejection wrote nothing
    }

    // Red if a Character count replaces scalars: 1,000 "é" (decomposed) is 1,000 Characters but 2,000 scalars (accepted),
    // 1,001 is 1,001 Characters but 2,002 scalars (a Character counter says fine, storage rejects).
    @Test("OC-4063 given combining marks, when 1,000 sequences (2,000 scalars) then saved; when 1,001 (2,002 scalars) then rejected")
    func combiningMarks() async throws {
        let store = try await Store.make()
        defer { store.cleanUp() }
        try await store.insert(Spec(n: 1))
        let atMax = String(repeating: eAcute, count: 1000)
        #expect(atMax.count == 1000)
        #expect(IngestLimits.noteLength(atMax) == 2000)
        #expect(try await store.database.setNote(atMax, for: Store.id(1)).get() == true)
        #expect(try storedNote(store) == atMax)

        let over = String(repeating: eAcute, count: 1001)
        #expect(over.count == 1001)
        #expect(IngestLimits.noteLength(over) == 2002)
        #expect(code(await store.database.setNote(over, for: Store.id(1))) == .orgVal002)
        #expect(try storedNote(store) == atMax)
    }

    // Red if ZWJ sequences count as one. 285 families = 1,995 scalars; +5 "a" = exactly 2,000; +6 = 2,001.
    @Test("OC-4064 given ZWJ family emoji, when 1,995 scalars + 5 = 2,000 then saved; +6 = 2,001 then rejected")
    func zwjBoundary() async throws {
        let store = try await Store.make()
        defer { store.cleanUp() }
        try await store.insert(Spec(n: 1))
        let base = String(repeating: family, count: 285)
        #expect(IngestLimits.noteLength(base) == 1995)
        let atMax = base + "aaaaa"
        #expect(IngestLimits.noteLength(atMax) == 2000)
        #expect(try await store.database.setNote(atMax, for: Store.id(1)).get() == true)
        #expect(try storedNote(store) == atMax)

        let over = base + "aaaaaa"
        #expect(IngestLimits.noteLength(over) == 2001)
        #expect(over.count == 291)  // 285 + 6 Characters: a Character counter would call this tiny
        #expect(code(await store.database.setNote(over, for: Store.id(1))) == .orgVal002)
        #expect(try storedNote(store) == atMax)
    }

    // Red if astral scalars are counted in UTF-16 units (2 each) or UTF-8 bytes (4 each): 2,000 grins must save.
    @Test("OC-4065 given 2,000 astral-plane scalars, then saved (not counted as UTF-16 units or bytes); 2,001 rejected")
    func astralScalars() async throws {
        let store = try await Store.make()
        defer { store.cleanUp() }
        try await store.insert(Spec(n: 1))
        let atMax = String(repeating: grin, count: 2000)
        #expect(IngestLimits.noteLength(atMax) == 2000)
        #expect(atMax.utf16.count == 4000)
        #expect(try await store.database.setNote(atMax, for: Store.id(1)).get() == true)
        #expect(try storedNote(store) == atMax)
        #expect(code(await store.database.setNote(atMax + grin, for: Store.id(1))) == .orgVal002)
        #expect(try storedNote(store) == atMax)
    }

    // The counter appears from 1,800 (>=): one below must be below the threshold, exactly at and above must not.
    // Red if the threshold is derived off by one or compared with > instead of >=. Uses ZWJ so a Character count is far below.
    @Test("OC-4066 given the 90% threshold, then 1,799 scalars are below it and 1,800 are at it, in ASCII and in ZWJ emoji")
    func thresholdBoundary() {
        let t = IngestLimits.noteCounterThreshold
        let ascii1799 = String(repeating: "a", count: 1799)
        let ascii1800 = String(repeating: "a", count: 1800)
        #expect(!(IngestLimits.noteLength(ascii1799) >= t))
        #expect(IngestLimits.noteLength(ascii1800) >= t)
        let zwj1799 = String(repeating: family, count: 257)  // 257 * 7 = 1,799
        let zwj1800 = zwj1799 + "a"
        #expect(IngestLimits.noteLength(zwj1799) == 1799)
        #expect(!(IngestLimits.noteLength(zwj1799) >= t))
        #expect(IngestLimits.noteLength(zwj1800) == 1800)
        #expect(IngestLimits.noteLength(zwj1800) >= t)
        #expect(zwj1800.count == 258)  // the old Character counter would show nothing here
    }

    // B6: empty / zero-length and whitespace notes are unaffected by the shared counter.
    @Test("OC-4067 given an empty note, then it clears; a 2,000-space note is stored exactly as typed")
    func emptyAndWhitespace() async throws {
        let store = try await Store.make()
        defer { store.cleanUp() }
        try await store.insert(Spec(n: 1))
        #expect(try await store.database.setNote("keep", for: Store.id(1)).get() == true)
        #expect(try await store.database.setNote("", for: Store.id(1)).get() == true)
        #expect(try storedNote(store) == nil)
        let spaces = String(repeating: " ", count: 2000)
        #expect(try await store.database.setNote(spaces, for: Store.id(1)).get() == true)
        #expect(try storedNote(store) == spaces)
        #expect(code(await store.database.setNote(spaces + " ", for: Store.id(1))) == .orgVal002)
        #expect(try storedNote(store) == spaces)
    }
}
