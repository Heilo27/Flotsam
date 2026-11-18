import Foundation
import Testing
@testable import FlotsamBase

// Worf TASK-469 blind QA: literal expectations for every plural count string at n = 0, 1, 2 and the max boundary, on both
// the public (compiled-or-raw) path and the raw-catalogue resolver, plus hostile arguments. Expected sides are literals.

@Suite struct Worf469PluralAdversarialTests {
    /// key, arguments before the count (text slots), count position irrelevant (taken from the entry's argNum), n -> expected.
    private struct Case: Sendable {
        let key: String
        let extra: String?          // text argument ('%2$@' or '%1$@'), nil when the template has none
        let zero: String
        let one: String
        let two: String
        let many: String            // n = 21
    }

    private static let cases: [Case] = [
        Case(key: "ui.library.footerItems", extra: nil, zero: "0 items", one: "1 item", two: "2 items", many: "21 items"),
        Case(key: "ui.row.bundleCount", extra: nil, zero: "0 items", one: "1 item", two: "2 items", many: "21 items"),
        Case(key: "ui.settings.clearDone", extra: nil, zero: "0 items deleted", one: "1 item deleted", two: "2 items deleted", many: "21 items deleted"),
        Case(key: "ui.settings.clearCount", extra: nil,
             zero: "This permanently deletes 0 items. This can\u{2019}t be undone.",
             one: "This permanently deletes 1 item. This can\u{2019}t be undone.",
             two: "This permanently deletes 2 items. This can\u{2019}t be undone.",
             many: "This permanently deletes 21 items. This can\u{2019}t be undone."),
        Case(key: "ui.organize.confirmDelete", extra: nil,
             zero: "Delete 0 items permanently? This cannot be undone.",
             one: "Delete 1 item permanently? This cannot be undone.",
             two: "Delete 2 items permanently? This cannot be undone.",
             many: "Delete 21 items permanently? This cannot be undone."),
        Case(key: "ui.organize.confirmDeleteTag", extra: "work",
             zero: "Remove tag 'work' from 0 items?", one: "Remove tag 'work' from 1 item?",
             two: "Remove tag 'work' from 2 items?", many: "Remove tag 'work' from 21 items?"),
        Case(key: "ui.settings.confirmBudget", extra: "5 MB",
             zero: "Lowering the image budget removes 0 older images (5 MB). Pinned and shortcut items are kept.",
             one: "Lowering the image budget removes 1 older image (5 MB). Pinned and shortcut items are kept.",
             two: "Lowering the image budget removes 2 older images (5 MB). Pinned and shortcut items are kept.",
             many: "Lowering the image budget removes 21 older images (5 MB). Pinned and shortcut items are kept."),
        Case(key: "ui.settings.confirmShorten", extra: "30 days",
             zero: "This permanently deletes 0 items older than 30 days. Pinned items and items with a shortcut are kept.",
             one: "This permanently deletes 1 item older than 30 days. Pinned items and items with a shortcut are kept.",
             two: "This permanently deletes 2 items older than 30 days. Pinned items and items with a shortcut are kept.",
             many: "This permanently deletes 21 items older than 30 days. Pinned items and items with a shortcut are kept."),
    ]

    /// Arguments in template order: the count and the text slot placed by the key's own argument order.
    private static func args(_ c: Case, count: Int) -> [CVarArg] {
        switch c.key {
        case "ui.organize.confirmDeleteTag": return [c.extra!, count]
        default: return c.extra.map { [count, $0] } ?? [count]
        }
    }

    @Test("OC-0017 given every plural count key, when n is 0, 1, 2 or 21, then the public path reads the literal English form")
    func publicPathLiteralTable() {
        // Red if: any key loses/changes its one or other variation, or formatted(forKey:) stops resolving by count.
        for c in Self.cases {
            for (n, expected) in [(0, c.zero), (1, c.one), (2, c.two), (21, c.many)] {
                #expect(FlotsamStrings.formatted(forKey: c.key, Self.args(c, count: n)) == expected, "\(c.key) n=\(n)")
            }
        }
    }

    @Test("OC-0017 given the shipped catalogue entries, when the raw resolver fills them, then n=0/1/2/21 read the same literals")
    func rawResolverLiteralTable() throws {
        // Red if: resolvingPlurals picks `one` for a wrong count, drops a slot, or mis-numbers %arg's position.
        let entries = try FlotsamCatalogue.englishEntries().get()
        for c in Self.cases {
            let entry = try #require(entries[c.key], "\(c.key) missing from the shipped catalogue")
            for (n, expected) in [(0, c.zero), (1, c.one), (2, c.two), (21, c.many)] {
                let a = Self.args(c, count: n)
                let raw = String(format: FlotsamStrings.resolvingPlurals(in: entry, arguments: a), arguments: a)
                #expect(raw == expected, "\(c.key) n=\(n)")
            }
        }
    }

    @Test("FR-000-05 given the largest count, when resolved, then it is 'other' with no overflow or leaked slot")
    func maxBoundary() throws {
        let entries = try FlotsamCatalogue.englishEntries().get()
        let entry = try #require(entries["ui.library.footerItems"])
        #expect(FlotsamStrings.formatted(forKey: "ui.library.footerItems", [Int.max]) == "9223372036854775807 items")
        let raw = String(format: FlotsamStrings.resolvingPlurals(in: entry, arguments: [Int.max]), arguments: [Int.max])
        #expect(raw == "9223372036854775807 items")
    }

    @Test("FR-000-05 given a tag name that is itself a format string, when the confirmation is built, then the name is shown verbatim and the count still pluralises")
    func hostileTagName() {
        // Red if: the name is spliced into the template before plural resolution (format-string injection).
        let name = "100%% %lld %#@items@ %@"
        #expect(FlotsamStrings.formatted(forKey: "ui.organize.confirmDeleteTag", [name, 1]) == "Remove tag '\(name)' from 1 item?")
        #expect(FlotsamStrings.formatted(forKey: "ui.organize.confirmDeleteTag", [name, 2]) == "Remove tag '\(name)' from 2 items?")
    }

    @Test("FR-000-05 given a count passed as Int64/Int32/UInt8 equal to 1, when resolved on the raw fallback, then it reads 'one' like Int")
    func nonIntCounts() throws {
        let entry = try #require(FlotsamCatalogue.englishEntries().get()["ui.library.footerItems"])
        #expect(FlotsamStrings.resolvingPlurals(in: entry, arguments: [Int64(1)]) == "%1$lld item")
        #expect(FlotsamStrings.resolvingPlurals(in: entry, arguments: [Int32(1)]) == "%1$lld item")
        #expect(FlotsamStrings.resolvingPlurals(in: entry, arguments: [UInt8(1)]) == "%1$lld item")
        #expect(FlotsamStrings.resolvingPlurals(in: entry, arguments: [Int64(2)]) == "%1$lld items")
        #expect(FlotsamStrings.resolvingPlurals(in: entry, arguments: [UInt64.max]) == "%1$lld items")
    }

    @Test("FR-000-05 given every key in the catalogue, when its template is read with no arguments, then no plural slot or %arg survives on the fallback")
    func noKeyLeaksOnTheFallback() throws {
        let entries = try FlotsamCatalogue.englishEntries().get()
        #expect(entries.count > 300)
        var plural = 0
        for (key, entry) in entries {
            let resolved = FlotsamStrings.resolvingPlurals(in: entry, arguments: [])
            #expect(!resolved.contains("#@") && !resolved.contains("%arg"), "\(key): \(resolved)")
            if entry.base.contains("%#@") { plural += 1 }
        }
        #expect(plural == 8)
    }

    @Test("FR-000-05 given a catalogue whose 'one' form is dropped from a substitution, when read, then the entry loses the substitution instead of silently using 'other'")
    func droppedOneFormIsDetected() throws {
        let json = """
        {"strings":{"k":{"localizations":{"en":{"stringUnit":{"value":"%#@n@"},
          "substitutions":{"n":{"argNum":1,"variations":{"plural":{"other":{"stringUnit":{"value":"%arg things"}}}}}}}}}}}
        """
        let entry = try #require(FlotsamCatalogue.englishEntries(from: Data(json.utf8)).get()["k"])
        #expect(entry.substitutions.isEmpty)
    }
}
