import FlotsamBase
import FlotsamPaste
import FlotsamStorage
import Foundation
import Testing
@testable import FlotsamLibrary

// FRD-003 8T, contract OC-3032..OC-3033, OC-3040, OC-3042..OC-3054 (delete, sort, search, footer, empty states,
// sidebar). Items go through the shipping ingest and query layer in a temp database, so search, counts and kinds are
// real. The expected side of every assertion is a literal from .claude/oracle/frd-003-contract.json (blind).

@MainActor
@Suite struct Frd003ContractSearchTests {
    private let target = FrontmostApp(bundleId: "com.apple.TextEdit", processId: 4242)

    private func key(_ input: LibraryKeyInput, _ modifiers: ChordModifiers = []) -> LibraryKeyStroke {
        LibraryKeyStroke(input, modifiers)
    }

    private func search(_ lib: RealLibrary, _ query: String) async -> [UUID] {
        lib.model.setSearchText(query)
        await lib.model.settled()
        return lib.model.loadedRows.map(\.id)
    }

    private func fillers(_ lib: RealLibrary, _ count: Int, prefix: String = "filler") async throws {
        for n in 0..<count { try await lib.add(.text, key: "\(prefix)-\(n)", text: "\(prefix) number \(n)", source: "Notes", secondsAgo: 1_000 + Double(n)) }
    }

    // MARK: Delete (FR-003-08, AC-003-06)

    // OC-3032. Mutation: deleteSelected removes nothing, removes a different row, or leaves the search index entry behind.
    @Test("OC-3032 command-delete on a selected item removes it: search finds nothing and the count is n - 1")
    func oc3032_deleteOne() async throws {
        // given: 6 items, 'del-<uuid>' selected
        let lib = try await RealLibrary.make()
        defer { lib.cleanUp() }
        let tag = UUID().uuidString.lowercased()
        let doomed = try await lib.add(.text, key: "del", text: "del-\(tag)", secondsAgo: 10).itemId
        var survivors: [UUID] = []
        for n in 0..<5 { survivors.append(try await lib.add(.text, key: "keep\(n)", text: "keeper \(n)", secondsAgo: 20 + Double(n)).itemId) }
        await lib.model.open(target: target)
        #expect(lib.model.totalCount == 6)
        lib.model.select(id: doomed)
        // when: command-delete is pressed (the Library hands the command on) and the delete runs
        #expect(lib.model.handle(key(.delete, .command)))
        #expect(lib.reported.external.count == 1)
        #expect(lib.reported.external.first?.0 == .delete)
        #expect(lib.reported.external.first?.1 == [doomed])
        let removed = await lib.model.deleteSelected()
        // then: it is gone from search, the count is 5, every survivor is still listed
        #expect(removed == [doomed])
        let hits = await search(lib, "del-\(tag)")
        #expect(hits.isEmpty)
        #expect(lib.model.isNoResults)
        _ = await search(lib, "")
        #expect(lib.model.totalCount == 5)
        #expect(lib.model.footer().countText == "5 items")
        #expect(Set(lib.model.loadedRows.map(\.id)) == Set(survivors))
        #expect(lib.reported.errors.isEmpty)
    }

    // OC-3040. Mutation: deleteSelected deletes only the cursor row or only the first selected id.
    @Test("OC-3040 deleting three selected items removes all three and leaves count n - 3")
    func oc3040_deleteThree() async throws {
        // given: 8 items, m1, m2, m3 selected
        let lib = try await RealLibrary.make()
        defer { lib.cleanUp() }
        let tag = UUID().uuidString.lowercased()
        var doomed: [UUID] = []
        for n in 1...3 { doomed.append(try await lib.add(.text, key: "m\(n)", text: "m\(n)-\(tag)", secondsAgo: Double(n)).itemId) }
        var survivors: [UUID] = []
        for n in 0..<5 { survivors.append(try await lib.add(.text, key: "keep\(n)", text: "keeper \(n)", secondsAgo: 20 + Double(n)).itemId) }
        await lib.model.open(target: target)
        lib.model.select(id: doomed[0])
        lib.model.toggle(id: doomed[1])
        lib.model.toggle(id: doomed[2])
        #expect(lib.model.selection == Set(doomed))
        // when: command-delete is pressed and the delete runs
        #expect(lib.model.handle(key(.delete, .command)))
        #expect(Set(lib.reported.external.first?.1 ?? []) == Set(doomed))
        let removed = await lib.model.deleteSelected()
        // then: all three are absent from search, the count is 5, the survivors are intact
        #expect(Set(removed ?? []) == Set(doomed))
        for n in 1...3 {
            let hits = await search(lib, "m\(n)-\(tag)")
            #expect(hits.isEmpty, "m\(n) still found")
        }
        _ = await search(lib, "")
        #expect(lib.model.totalCount == 5)
        #expect(Set(lib.model.loadedRows.map(\.id)) == Set(survivors))
    }

    // MARK: Sort (OC-3033)

    // OC-3033. Mutation: cycle order wrong, a sort key swapped (pasteCount vs copyCount), alphabetical case-sensitive, or the
    // label not updated.
    @Test("OC-3033 command-S cycles Recent, Oldest, Most Used, A to Z, back to Recent, with the label and order")
    func oc3033_sortCycle() async throws {
        // given: Zeta (copied first), mid (in between, most copied and pasted), alpha (copied last); sort Recent
        let lib = try await RealLibrary.make()
        defer { lib.cleanUp() }
        let zeta = try await lib.add(.text, key: "zeta", text: "Zeta-x1", secondsAgo: 300).itemId
        let mid = try await lib.add(.text, key: "mid", text: "mid-x1", secondsAgo: 200).itemId
        for _ in 0..<3 { try await lib.add(.text, key: "mid", text: "mid-x1", secondsAgo: 200) }
        for _ in 0..<5 { _ = await lib.database.recordPaste(of: mid) }
        let alpha = try await lib.add(.text, key: "alpha", text: "alpha-x1", secondsAgo: 100).itemId
        await lib.model.open(target: target)
        #expect(lib.model.footer().sortName == "Recent")
        #expect(lib.model.loadedRows.map(\.id) == [alpha, mid, zeta])
        // when / then: four presses
        #expect(lib.model.handle(key(.character("s"), .command)))
        await lib.model.settled()
        #expect(lib.model.footer().sortName == "Oldest")
        #expect(lib.model.loadedRows.map(\.id) == [zeta, mid, alpha])
        #expect(lib.model.handle(key(.character("s"), .command)))
        await lib.model.settled()
        #expect(lib.model.footer().sortName == "Most Used")
        #expect(lib.model.loadedRows.first?.id == mid)
        #expect(lib.model.handle(key(.character("s"), .command)))
        await lib.model.settled()
        #expect(lib.model.footer().sortName == "A to Z")
        #expect(lib.model.loadedRows.map(\.id) == [alpha, mid, zeta])
        #expect(lib.model.handle(key(.character("s"), .command)))
        await lib.model.settled()
        #expect(lib.model.footer().sortName == "Recent")
        #expect(lib.model.loadedRows.map(\.id) == [alpha, mid, zeta])
        #expect(lib.reported.external.isEmpty, "command-S is the Library's own, it is not handed on")
    }

    // MARK: Search (FR-003-09)

    private func resumeLibrary() async throws -> (RealLibrary, UUID) {
        let lib = try await RealLibrary.make()
        let id = try await lib.add(.text, key: "resume", text: "Résumé draft", source: "Safari", secondsAgo: 5).itemId
        _ = await lib.database.setNote("for Anna", for: id)
        if case .success(let tagId) = await lib.database.createTag(name: "work", color: .blue) { _ = await lib.database.toggleTag(id: tagId, on: [id]) }
        try await fillers(lib, 50)
        await lib.model.open(target: target)
        return (lib, id)
    }

    // OC-3042. Mutation: search skips the note, the tag names, the source name, or ANDs nothing (OR instead of AND).
    @Test("OC-3042 search matches text, note, tag and source, and every token must match")
    func oc3042_fieldsAndTokens() async throws {
        // given: 'Résumé draft' with note 'for Anna', tag 'work', source Safari, among 50 others
        let (lib, id) = try await resumeLibrary()
        defer { lib.cleanUp() }
        // when / then: each query hits exactly that item
        for query in ["resume", "anna", "work", "safari draft"] {
            let hits = await search(lib, query)
            #expect(hits == [id], "query '\(query)' got \(hits.count) hits")
        }
        // and a token that matches nothing sinks the whole query
        let none = await search(lib, "resume zzz")
        #expect(none.isEmpty)
        #expect(lib.model.isNoResults)
    }

    // OC-3043. Mutation: case-sensitive or diacritic-sensitive match, or prefix-only match.
    @Test("OC-3043 search ignores case and accents, and matches inside words")
    func oc3043_normalisation() async throws {
        // given: the same fixture
        let (lib, id) = try await resumeLibrary()
        defer { lib.cleanUp() }
        // when / then
        for query in ["RÉSUMÉ", "DRAFT ANNA", "umé dra"] {
            let hits = await search(lib, query)
            #expect(hits == [id], "query '\(query)' got \(hits.count) hits")
        }
    }

    // OC-3044. Mutation: the index drops the URL, the file name, bundle member names, the original screenshot name, or the kind label.
    @Test("OC-3044 search reaches URLs, file names, bundle members, screenshot names and kind labels")
    func oc3044_indexedFields() async throws {
        // given: link, file, bundle, screenshot named 'Screenshot qz4.png', a screenshot with no path, a text item
        let lib = try await RealLibrary.make()
        defer { lib.cleanUp() }
        let link = try await lib.add(.link, key: "l", text: "https://example.com/qz1-path", secondsAgo: 10).itemId
        let file = try await lib.add(.file, key: "f", text: "qz2-name.txt", secondsAgo: 20,
            members: [IngestMember(path: "/tmp/qz2-name.txt", bookmark: nil, isDirectory: false)]).itemId
        let bundle = try await lib.add(.bundle, key: "b", secondsAgo: 30,
            members: [IngestMember(path: "/tmp/qz3-member.pdf", bookmark: nil, isDirectory: false)]).itemId
        let shot = try await lib.add(.screenshot, key: "s1", secondsAgo: 40, originalPath: "/tmp/Screenshot qz4.png").itemId
        let bareShot = try await lib.add(.screenshot, key: "s2", text: "plain", secondsAgo: 50).itemId
        let note = try await lib.add(.text, key: "t", text: "ordinary words", secondsAgo: 60).itemId
        _ = await lib.database.setNote("", for: note)
        await lib.model.open(target: target)
        // when / then
        let pairs: [(String, UUID)] = [("qz1-path", link), ("qz2-name", file), ("qz3-member", bundle), ("qz4", shot)]
        for (query, expected) in pairs {
            let hits = await search(lib, query)
            #expect(hits == [expected], "query '\(query)' got \(hits.count) hits")
        }
        let byLabel = await search(lib, "screenshot")
        #expect(Set(byLabel) == Set([shot, bareShot]), "kind label 'screenshot' got \(byLabel.count) hits")
    }

    // OC-3045. Mutation: the 10,000-character index limit moves (or is dropped to a smaller one).
    @Test("OC-3045 text is searchable up to 10,000 characters and not beyond")
    func oc3045_textLimit() async throws {
        // given: 12,000 characters, 'deep9k' at 9,000 and 'deep11k' at 11,000
        let lib = try await RealLibrary.make()
        defer { lib.cleanUp() }
        let text = String(repeating: "x", count: 9_000) + "deep9k" + String(repeating: "x", count: 1_994) + "deep11k" + String(repeating: "x", count: 993)
        #expect(text.count == 12_000)
        #expect(text.range(of: "deep9k").map { text.distance(from: text.startIndex, to: $0.lowerBound) } == 9_000)
        #expect(text.range(of: "deep11k").map { text.distance(from: text.startIndex, to: $0.lowerBound) } == 11_000)
        let id = try await lib.add(.text, key: "long", text: text, secondsAgo: 5).itemId
        await lib.model.open(target: target)
        // when / then
        let early = await search(lib, "deep9k")
        #expect(early == [id])
        let late = await search(lib, "deep11k")
        #expect(late.isEmpty)
        #expect(lib.model.isNoResults)
    }

    // OC-3046. Mutation: search ignores the active filter, or the filter ignores the search.
    @Test("OC-3046 search and the Links filter combine")
    func oc3046_filterAndSearch() async throws {
        // given: a link and a text item sharing a word
        let lib = try await RealLibrary.make()
        defer { lib.cleanUp() }
        let link = try await lib.add(.link, key: "l", text: "https://example.com/sharedword", secondsAgo: 10).itemId
        let text = try await lib.add(.text, key: "t", text: "sharedword in a sentence", secondsAgo: 20).itemId
        await lib.model.open(target: target)
        let both = await search(lib, "sharedword")
        #expect(Set(both) == Set([link, text]))
        // when: the Links filter is on
        lib.model.select(filter: .kind(.link))
        await lib.model.settled()
        // then: only the link remains
        #expect(lib.model.loadedRows.map(\.id) == [link])
        #expect(lib.model.searchText == "sharedword")
    }

    // OC-3047. Mutation: results re-ranked by match count instead of keeping the sort.
    @Test("OC-3047 matches keep the active sort, not match frequency")
    func oc3047_sortKept() async throws {
        // given: newer N says 'rank' once, older O says it twenty times
        let lib = try await RealLibrary.make()
        defer { lib.cleanUp() }
        let newer = try await lib.add(.text, key: "n", text: "rank", secondsAgo: 10).itemId
        let older = try await lib.add(.text, key: "o", text: Array(repeating: "rank", count: 20).joined(separator: " "), secondsAgo: 100).itemId
        await lib.model.open(target: target)
        // when / then
        let hits = await search(lib, "rank")
        #expect(hits == [newer, older])
    }

    // OC-3049. Mutation: drop the generation guard so a slow early query lands after the final one.
    @Test("OC-3049 typing 'abcdef' at 20 ms a character ends on exactly the 'abcdef' results, no stale prefix after")
    func oc3049_typing() async throws {
        // given: 10,000 items; each shorter prefix matches a different set; earlier queries answer slower
        var rows: [ItemRow] = (0..<5).map { makeRow($0, primary: "abcdef-hit \($0)") }
        let prefixes = ["a", "ab", "abc", "abcd", "abcde"]
        for (p, prefix) in prefixes.enumerated() {
            for n in 0..<1_999 { rows.append(makeRow(10 + p * 2_000 + n, primary: "\(prefix)-fill \(n)")) }
        }
        #expect(rows.count == 9_990 + 5 + 5)  // padded below to 10,000
        while rows.count < 10_000 { rows.append(makeRow(50_000 + rows.count, primary: "zzz \(rows.count)")) }
        let inner = FakeSource(rows: rows)
        let slow = UncancellableDelaySource(
            inner: inner, delays: ["a": .milliseconds(300), "ab": .milliseconds(250), "abc": .milliseconds(200),
                                   "abcd": .milliseconds(150), "abcde": .milliseconds(100), "abcdef": .milliseconds(10)])
        let model = LibraryViewModel(source: slow, paster: FakePaster(), host: FakeHost(), preferences: FakePreferences())
        let h = (model: model, source: slow)
        await h.model.open(target: target)
        // when: typed at 20 ms per character
        var typed = ""
        for ch in "abcdef" {
            typed.append(ch)
            h.model.setSearchText(typed)
            try await Task.sleep(for: .milliseconds(20))
        }
        // then: sampled until every slow answer has landed, once 'abcdef' is shown nothing else ever is
        let expected = Set(rows.prefix(5).map(\.id))
        var sawFinal = false
        var staleAfterFinal = 0
        for _ in 0..<60 {
            let shown = Set(h.model.loadedRows.map(\.id))
            if shown == expected { sawFinal = true } else if sawFinal { staleAfterFinal += 1 }
            try await Task.sleep(for: .milliseconds(10))
        }
        await h.model.settled()
        #expect(Set(h.model.loadedRows.map(\.id)) == expected)
        #expect(h.model.totalCount == 5)
        #expect(sawFinal)
        #expect(staleAfterFinal == 0, "\(staleAfterFinal) later renders showed a shorter prefix")
    }

    // MARK: Footer and empty states (FR-003-11, FR-003-10)

    // OC-3050. Mutation: count ignores filter or search, no-results copy changes, or no-results reports an error.
    @Test("OC-3050 footer counts the filtered set and no-results shows the query and the hint")
    func oc3050_footerAndNoResults() async throws {
        // given: 10 items, 4 of them links
        let lib = try await RealLibrary.make()
        defer { lib.cleanUp() }
        for n in 0..<4 { try await lib.add(.link, key: "l\(n)", text: "https://example.com/\(n)", secondsAgo: Double(n)) }
        for n in 0..<6 { try await lib.add(.text, key: "t\(n)", text: "plain \(n)", secondsAgo: 10 + Double(n)) }
        await lib.model.open(target: target)
        #expect(lib.model.footer().countText == "10 items")
        // when: the Links filter is chosen
        lib.model.select(filter: .kind(.link))
        await lib.model.settled()
        // then
        #expect(lib.model.footer().countText == "4 items")
        // and when a query matches nothing
        _ = await search(lib, "zzzq")
        // then: zero items, the literal title and body, no error
        #expect(lib.model.footer().countText == "0 items")
        #expect(lib.model.isNoResults)
        #expect(!lib.model.isHistoryEmpty)
        #expect(LibraryText.noResultsTitle(query: "zzzq") == "No matches for “zzzq”")
        #expect(LibraryText.string("ui.library.noResultsBody") == "Check the spelling, or clear the search to see everything.")
        #expect(lib.reported.errors.isEmpty)
    }

    // OC-3051. Mutation: empty history reported as no-results, copy changed, or an error raised.
    @Test("OC-3051 an empty library shows the empty-history state, not an error")
    func oc3051_emptyHistory() async throws {
        // given: nothing copied yet
        let lib = try await RealLibrary.make()
        defer { lib.cleanUp() }
        // when
        await lib.model.open(target: target)
        // then
        #expect(lib.model.isHistoryEmpty)
        #expect(!lib.model.isNoResults)
        #expect(lib.model.loadedRows.isEmpty)
        #expect(LibraryText.string("ui.library.emptyTitle") == "Nothing copied yet")
        #expect(LibraryText.string("ui.library.emptyBody") == "Copy something and it appears here. Press ⌃⌘V any time to open this panel.")
        #expect(lib.reported.errors.isEmpty)
    }

    // MARK: Sidebar (FR-003-12)

    // OC-3052. Mutation: tags listed by count not name, an empty tag hidden or not dimmed, or a zero-count kind listed.
    @Test("OC-3052 tags are alphabetical with an empty tag dimmed, and a kind with no items has no row")
    func oc3052_tagsAndEmptyKinds() async throws {
        // given: tags 'work' (3 items) and 'home' (0 items); only text items
        let lib = try await RealLibrary.make()
        defer { lib.cleanUp() }
        var ids: [UUID] = []
        for n in 0..<4 { ids.append(try await lib.add(.text, key: "t\(n)", text: "text \(n)", secondsAgo: Double(n)).itemId) }
        guard case .success(let work) = await lib.database.createTag(name: "work", color: .blue),
              case .success(_) = await lib.database.createTag(name: "home", color: .blue) else { Issue.record("tag setup failed"); return }
        _ = await lib.database.toggleTag(id: work, on: Array(ids.prefix(3)))
        // when
        await lib.model.open(target: target)
        // then
        let tags = lib.model.sidebarEntries.filter { $0.section == .tags }
        #expect(tags.map(\.title) == ["home", "work"])
        #expect(tags.map(\.count) == [0, 3])
        #expect(tags.map(\.isDimmed) == [true, false])
        #expect(!lib.model.sidebarEntries.contains { $0.title == "Emails" })
        #expect(lib.model.sidebarEntries.filter { $0.section == .types }.map(\.title) == ["Text"])
    }

    // OC-3053. Mutation: type order changed, Pinned not dimmed at 0, apps uncapped, apps not sorted by count, All not the total.
    @Test("OC-3053 sidebar order, counts, a dimmed Pinned, and the top 15 apps by count")
    func oc3053_sidebarShape() async throws {
        // given: every kind, 2 tags, no pinned, 17 source apps with counts 1...17 (153 items)
        let lib = try await RealLibrary.make()
        defer { lib.cleanUp() }
        let kinds: [ItemKind] = [.text, .richText, .link, .color, .phone, .email, .image, .screenshot, .file, .folder, .bundle]
        var index = 0
        var firstIDs: [UUID] = []
        for app in 1...17 {
            for _ in 0..<app {
                let id = try await lib.add(kinds[index % 11], key: "k\(index)", text: "item \(index)", source: "App\(app)", secondsAgo: Double(index)).itemId
                if firstIDs.count < 2 { firstIDs.append(id) }
                index += 1
            }
        }
        #expect(index == 153)
        for name in ["alpha", "beta"] { _ = await lib.database.createTag(name: name, color: .blue) }
        // when
        await lib.model.open(target: target)
        let entries = lib.model.sidebarEntries
        // then: sections in order, titles in order
        #expect(entries.prefix(2).map(\.title) == ["All", "Pinned"])
        #expect(entries.filter { $0.section == .types }.map(\.title) == [
            "Text", "Rich Text", "Links", "Colors", "Phone Numbers", "Emails", "Images", "Screenshots", "Files", "Folders", "Bundles"])
        #expect(entries.filter { $0.section == .tags }.map(\.title) == ["alpha", "beta"])
        let sections = entries.map(\.section)
        #expect(sections == sections.sorted { order($0) < order($1) }, "sections out of order: \(sections)")
        // counts
        #expect(entries.first?.count == 153)
        #expect(entries.first { $0.title == "Pinned" }?.count == 0)
        #expect(entries.first { $0.title == "Pinned" }?.isDimmed == true, "Pinned at 0 must be dimmed")
        let typeCounts = entries.filter { $0.section == .types }.reduce(into: [String: Int]()) { $0[$1.title] = $1.count }
        #expect(typeCounts.values.reduce(0, +) == 153)
        // apps: exactly 15, descending 17...3
        let apps = entries.filter { $0.section == .apps }
        #expect(apps.count == 15)
        #expect(apps.map(\.count) == Array((3...17).reversed()))
        #expect(apps.first?.title == "App17")
    }

    private func order(_ section: SidebarEntry.Section) -> Int {
        switch section { case .top: 0; case .types: 1; case .tags: 2; case .apps: 3 }
    }

    // OC-3054. Mutation: two rows highlighted at once, or the filter not applied to the results.
    @Test("OC-3054 choosing Images, a tag, then an app leaves exactly one row selected and only its items shown")
    func oc3054_oneRowSelected() async throws {
        // given: images, tagged text items, and app-specific items
        let lib = try await RealLibrary.make()
        defer { lib.cleanUp() }
        var images: [UUID] = []
        for n in 0..<2 { images.append(try await lib.add(.image, key: "i\(n)", text: nil, source: "Preview", secondsAgo: Double(n)).itemId) }
        var tagged: [UUID] = []
        for n in 0..<3 { tagged.append(try await lib.add(.text, key: "t\(n)", text: "tagged \(n)", source: "Notes", secondsAgo: 10 + Double(n)).itemId) }
        var mail: [UUID] = []
        for n in 0..<4 { mail.append(try await lib.add(.text, key: "m\(n)", text: "mail \(n)", source: "Mail", secondsAgo: 20 + Double(n)).itemId) }
        guard case .success(let tag) = await lib.database.createTag(name: "work", color: .blue) else { Issue.record("tag setup failed"); return }
        _ = await lib.database.toggleTag(id: tag, on: tagged)
        await lib.model.open(target: target)
        // when / then
        let cases: [(LibraryFilter, Set<UUID>)] = [(.kind(.image), Set(images)), (.tag(tag), Set(tagged)), (.sourceApp(.bundle("com.example.mail")), Set(mail))]
        for (filter, expected) in cases {
            lib.model.select(filter: filter)
            await lib.model.settled()
            let selected = lib.model.sidebarEntries.filter { $0.filter == lib.model.filter }
            #expect(selected.count == 1, "\(filter): \(selected.count) rows selected")
            #expect(Set(lib.model.loadedRows.map(\.id)) == expected, "\(filter)")
        }
    }
}

/// A source whose per-query delay is not cut short when the caller cancels (a real database query already in flight
/// still answers), so an earlier query really can land after a later one.
final class UncancellableDelaySource: LibraryDataSource, @unchecked Sendable {
    let inner: FakeSource
    let delays: [String: Duration]
    init(inner: FakeSource, delays: [String: Duration]) { self.inner = inner; self.delays = delays }
    func items(matching query: LibraryQuery) async -> FlotsamResult<ItemPage> {
        if let delay = delays[query.text] { await Task.detached { try? await Task.sleep(for: delay) }.value }
        return await inner.items(matching: query)
    }
    func sidebarCounts() async -> FlotsamResult<SidebarCounts> { await inner.sidebarCounts() }
    func content(of itemId: UUID) async -> FlotsamResult<ItemContent> { await inner.content(of: itemId) }
    func thumbnail(itemId: UUID, size: ThumbnailSize) async -> Data? { nil }
    func releaseMemory() async {}
}
