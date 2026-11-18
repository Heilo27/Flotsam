import CoreGraphics
import CoreText
import CryptoKit
import FlotsamBase
import FlotsamPaste
import FlotsamStorage
import Foundation
import ImageIO
import Testing
@testable import FlotsamLibrary

// FRD-003 8T, contract OC-3068 to OC-3105 (paste-back and its failures, FR-003-15 to FR-003-20, AC-003-11 to -14).
// The Library model runs over a real FlotsamDatabase and the shipping PasteService; only the OS edges are fakes (the
// pasteboard, the frontmost app, the Accessibility probe, the ⌘V poster, the clock). Expected values are literals from
// .claude/oracle/frd-003-contract.json (blind). What a real target app does with ⌘V (TextEdit's document text), the HUD's
// placement and 2.5 s timing, and VoiceOver's spoken order need a running app and are not covered here.

@MainActor
final class ContractPasteboard: PasteboardPort {
    private(set) var changeCount = 0
    private(set) var written: [[PasteboardRepresentation]] = []

    func currentTypeIdentifiers() -> [String] { written.last?.map(\.uti) ?? [] }
    func readSnapshot(types: [String]) -> FlotsamResult<PasteboardSnapshot> {
        .success(PasteboardSnapshot(changeCount: changeCount, typeIdentifiers: currentTypeIdentifiers(), representations: written.last ?? []))
    }
    func write(_ representations: [PasteboardRepresentation]) -> FlotsamResult<Int> {
        written.append(representations)
        changeCount += 1
        return .success(changeCount)
    }

    /// The text the last write put on the pasteboard, or nil.
    var lastText: String? {
        written.last?.first { $0.uti == "public.utf8-plain-text" }.map { String(decoding: $0.data, as: UTF8.self) }
    }
}

@MainActor
final class ContractFrontmost: FrontmostAppProvider {
    var current: FrontmostApp?
    init(_ current: FrontmostApp?) { self.current = current }
    func frontmost() -> FrontmostApp? { current }
}

@MainActor
final class ContractKeys: KeyEventPoster {
    var succeeds = true
    private(set) var posts = 0
    func postPaste() -> Bool { posts += 1; return succeeds }
}

final class ContractTrust: PermissionProbe, @unchecked Sendable {
    private let lock = NSLock()
    private var granted: Bool
    init(_ granted: Bool) { self.granted = granted }
    var accessibility: Bool {
        get { lock.withLock { granted } }
        set { lock.withLock { granted = newValue } }
    }
    func isGranted(_ kind: PermissionKind) -> Bool { kind == .accessibility ? accessibility : false }
    func request(_ kind: PermissionKind) {}
    func openSystemSettings(_ kind: PermissionKind) {}
}

/// Never sleeps, so the 250 ms target window and the settle delay cost nothing.
struct ContractClock: WallClock {
    func now() -> Date { Date(timeIntervalSince1970: 1_800_000_000) }
    func sleep(for duration: Duration) async {}
}

/// The real database with a switch that makes reads fail, the contract's "test hook" for OC-3085.
final class UnreadableSource: LibraryDataSource, @unchecked Sendable {
    private let inner: any LibraryDataSource
    private let lock = NSLock()
    private var _unreadable = false
    init(_ inner: any LibraryDataSource) { self.inner = inner }
    var unreadable: Bool {
        get { lock.withLock { _unreadable } }
        set { lock.withLock { _unreadable = newValue } }
    }
    func items(matching query: LibraryQuery) async -> FlotsamResult<ItemPage> {
        unreadable ? .failure(FlotsamError(.stoDb004, "forced read failure")) : await inner.items(matching: query)
    }
    func sidebarCounts() async -> FlotsamResult<SidebarCounts> { await inner.sidebarCounts() }
    func content(of itemId: UUID) async -> FlotsamResult<ItemContent> { await inner.content(of: itemId) }
    func thumbnail(itemId: UUID, size: ThumbnailSize) async -> Data? { await inner.thumbnail(itemId: itemId, size: size) }
    func releaseMemory() async { await inner.releaseMemory() }
}

@MainActor
struct PasteRig {
    let lib: RealLibrary
    let pasteboard = ContractPasteboard()
    let keys = ContractKeys()
    let trust: ContractTrust
    let frontmost: ContractFrontmost
    let host = FakeHost()
    let reported = Harness.Reported()
    let target = FrontmostApp(bundleId: "com.apple.TextEdit", processId: 4242)
    let model: LibraryViewModel

    init(lib: RealLibrary, trusted: Bool, source: (any LibraryDataSource)? = nil) {
        self.lib = lib
        trust = ContractTrust(trusted)
        frontmost = ContractFrontmost(target)
        let service = PasteService(
            store: lib.database, pasteboard: pasteboard, files: LocalFileSystem(), frontmost: frontmost,
            accessibility: trust, keys: keys, clock: ContractClock(), ownWrites: OwnWriteLedger())
        let reported = reported
        let trust = trust
        model = LibraryViewModel(
            source: source ?? lib.database, paster: service, host: host, preferences: FakePreferences(),
            effects: LibraryEffects(
                report: { reported.errors.append($0) }, external: { reported.external.append(($0, $1)) },
                isAccessibilityTrusted: { trust.accessibility }))
    }

    static func make(trusted: Bool = true) async throws -> PasteRig {
        PasteRig(lib: try await RealLibrary.make(), trusted: trusted)
    }

    /// The panel opening again: visible, search cleared, newest selected, target recorded.
    func reopen() async {
        host.isPanelVisible = true
        await model.open(target: target)
    }

    /// A key, then the paste it started, if any.
    func press(_ input: KeyInput, _ modifiers: ChordModifiers = []) async {
        model.handle(KeyStroke(input, modifiers))
        await model.pasteTask?.value
        await model.settled()
    }

    func pasteCount(_ id: UUID) async throws -> Int {
        try await lib.allRows().first { $0.id == id }?.pasteCount ?? -1
    }
}

/// What a paste must never change about an item (BR-003-01).
struct StoredState: Equatable {
    let kind: ItemKind
    let primaryLine: String
    let tags: [String]
    let note: String?
    let blobDigests: [String: String]
}

@MainActor
@Suite struct Frd003ContractPasteTests {
    private static let libDat001Text = "The original file or folder has moved or been deleted."
    private static let libIo001Text = "This item's data is missing, so it was removed."
    private static let libOs001Text = "Couldn't paste into that app. The item is on your clipboard; press ⌘V."
    private static let setPrm001Text = "Accessibility is off, so Flotsam can't paste for you. The item is on your clipboard; press ⌘V."
    private static let stoDb004Text = "Couldn't read your history. Try again."

    private func state(of id: UUID, in rig: PasteRig) async throws -> StoredState {
        let row = try #require(try await rig.lib.allRows().first { $0.id == id })
        let note = try await rig.lib.database.note(of: id).get()
        return StoredState(
            kind: row.kind, primaryLine: row.primaryLine, tags: row.tagNames, note: note,
            blobDigests: blobDigests(of: id, in: rig.lib.root))
    }

    /// SHA-256 of every blob file the item owns, by file name.
    private func blobDigests(of id: UUID, in root: URL) -> [String: String] {
        var digests: [String: String] = [:]
        let blobs = root.appendingPathComponent("blobs")
        guard let walker = FileManager.default.enumerator(at: blobs, includingPropertiesForKeys: nil) else { return [:] }
        for case let url as URL in walker where url.lastPathComponent.hasPrefix(id.uuidString) {
            guard let data = try? Data(contentsOf: url) else { continue }
            digests[url.lastPathComponent] = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        }
        return digests
    }

    /// Removes every blob file the item owns (synchronous: FileManager's enumerator cannot be iterated from async code).
    private func deleteBlobs(of id: UUID, in root: URL) throws {
        let blobs = root.appendingPathComponent("blobs")
        guard let walker = FileManager.default.enumerator(at: blobs, includingPropertiesForKeys: nil) else { return }
        for case let url as URL in walker where url.lastPathComponent.hasPrefix(id.uuidString) {
            try FileManager.default.removeItem(at: url)
        }
    }

    // MARK: Files gone (OC-3068, OC-3102)

    // OC-3068 / OC-3102. Mutation: the all-missing case pastes an empty payload, hides the panel, counts the paste, or
    // reports another code.
    @Test("OC-3068 / OC-3102 Return on a bundle whose members are all gone pastes nothing, keeps the panel, reports LIB-DAT-001")
    func oc3068_allMembersMissing() async throws {
        // given: a bundle of two files that do not exist, and a text item that does
        let rig = try await PasteRig.make()
        defer { rig.lib.cleanUp() }
        let members = [
            IngestMember(path: "/nonexistent-flotsam-8t/a.txt", bookmark: nil, isDirectory: false),
            IngestMember(path: "/nonexistent-flotsam-8t/b.txt", bookmark: nil, isDirectory: false),
        ]
        let bundle = try await rig.lib.add(.bundle, key: "gone-bundle", secondsAgo: 5, members: members).itemId
        let survivor = try await rig.lib.add(.text, key: "kept", text: "kept text", secondsAgo: 50).itemId
        await rig.model.open(target: rig.target)
        let row = try #require(rig.model.visibleRows.first { $0.id == bundle })
        #expect(row.isMissing)
        #expect(LibraryRowPresentation(row: row, position: 0, now: Date()).missingBadge == "Missing")
        // when: the bundle is selected and Return is pressed
        rig.model.select(id: bundle)
        await rig.press(.returnKey)
        // then: nothing on the pasteboard, no ⌘V, the panel is still open, one LIB-DAT-001 with the catalogue text
        #expect(rig.pasteboard.written.isEmpty)
        #expect(rig.keys.posts == 0)
        #expect(rig.host.hideCount == 0)
        #expect(rig.host.isPanelVisible)
        #expect(rig.reported.errors.map(\.code) == [.libDat001])
        #expect(FlotsamStrings.message(for: try #require(rig.reported.errors.first)) == Self.libDat001Text)
        // and: Times pasted is unchanged and both items are still there
        #expect(try await rig.pasteCount(bundle) == 0)
        #expect(Set(try await rig.lib.allRows().map(\.id)) == [bundle, survivor])
    }

    // MARK: Times pasted (OC-3069)

    // OC-3069. Mutation: recordPaste skipped, counted twice, or a paste re-ingests the text as a second item.
    @Test("OC-3069 a paste adds exactly one to Times pasted and leaves the item count alone")
    func oc3069_incrementsByOne() async throws {
        // given: a text item pasted 0 times and a bystander
        let rig = try await PasteRig.make()
        defer { rig.lib.cleanUp() }
        let item = try await rig.lib.add(.text, key: "t1", text: "tally text", secondsAgo: 5).itemId
        let other = try await rig.lib.add(.text, key: "t2", text: "bystander", secondsAgo: 50).itemId
        // when: it is pasted with Return, then again after reopening the panel
        await rig.reopen()
        rig.model.select(id: item)
        await rig.press(.returnKey)
        #expect(try await rig.pasteCount(item) == 1)
        await rig.reopen()
        rig.model.select(id: item)
        await rig.press(.returnKey)
        // then: 2, the other item still 0, the same two items and no third
        #expect(try await rig.pasteCount(item) == 2)
        #expect(try await rig.pasteCount(other) == 0)
        #expect(Set(try await rig.lib.allRows().map(\.id)) == [item, other])
        #expect(rig.keys.posts == 2)
    }

    // MARK: Copy-only (OC-3071 to OC-3073)

    // OC-3071. Mutation: Shift-Return posts ⌘V, skips the pasteboard, keeps the panel open, or skips the count.
    @Test("OC-3071 Shift-Return copies only: panel closes, text on the pasteboard, no command-V, Times pasted + 1")
    func oc3071_copyOnly() async throws {
        // given: Accessibility granted, a text item pasted 0 times
        let rig = try await PasteRig.make()
        defer { rig.lib.cleanUp() }
        let item = try await rig.lib.add(.text, key: "shift", text: "shift-8T-0001", secondsAgo: 5).itemId
        await rig.reopen()
        // when: Shift-Return
        await rig.press(.returnKey, .shift)
        // then
        #expect(rig.host.hideCount == 1)
        #expect(!rig.host.isPanelVisible)
        #expect(rig.pasteboard.lastText == "shift-8T-0001")
        #expect(rig.keys.posts == 0)
        #expect(try await rig.pasteCount(item) == 1)
        #expect(rig.reported.errors.isEmpty)
    }

    // OC-3072. Mutation: the rich item is written as plain text only, or the own-write markers are dropped.
    @Test("OC-3072 Shift-Return on a rich item puts html, plain text and both own-write markers on the pasteboard")
    func oc3072_richCopyOnly() async throws {
        // given: a rich item captured with html and plain text
        let rig = try await PasteRig.make()
        defer { rig.lib.cleanUp() }
        let html = Data("<b>bold</b> words".utf8)
        try await rig.lib.add(
            .richText, key: "rich", text: "bold words", secondsAgo: 5,
            representations: [PasteboardRepresentation(uti: "public.html", data: html)])
        await rig.reopen()
        // when: Shift-Return
        await rig.press(.returnKey, .shift)
        // then: exactly these four types, with the html bytes intact
        let written = try #require(rig.pasteboard.written.last)
        #expect(written.map(\.uti).sorted() == [
            "com.flotsam.own-write", "org.nspasteboard.AutoGeneratedType", "public.html", "public.utf8-plain-text",
        ])
        #expect(written.first { $0.uti == "public.html" }?.data == html)
        #expect(rig.pasteboard.lastText == "bold words")
    }

    // OC-3073. Mutation: the image is written without its pixels, or as a file reference.
    @Test("OC-3073 Shift-Return on an image puts a standard image type on the pasteboard that decodes to its pixels")
    func oc3073_imageCopyOnly() async throws {
        // given: a 120 x 80 image item
        let rig = try await PasteRig.make()
        defer { rig.lib.cleanUp() }
        try await rig.lib.add(
            .image, key: "img", secondsAgo: 5,
            representations: [PasteboardRepresentation(uti: "public.png", data: ContractPNG.make(width: 120, height: 80))])
        await rig.reopen()
        // when: Shift-Return
        await rig.press(.returnKey, .shift)
        // then: a public.png or public.tiff that decodes to 120 x 80
        let written = try #require(rig.pasteboard.written.last)
        let image = try #require(written.first { ["public.png", "public.tiff"].contains($0.uti) })
        let source = try #require(CGImageSourceCreateWithData(image.data as CFData, nil))
        let decoded = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        #expect(decoded.width == 120)
        #expect(decoded.height == 80)
    }

    // MARK: Accessibility revoked (OC-3077 to OC-3080)

    // OC-3077 / OC-3103 / OC-3078. Mutation: the paste still posts ⌘V, the error is another code, the panel stays open, or
    // the footer ignores the revoked permission.
    @Test("OC-3077 / OC-3103 / OC-3078 with Accessibility revoked a paste copies, reports SET-PRM-001, and the footer says Press command-V")
    func oc3077_accessibilityRevoked() async throws {
        // given: Accessibility revoked, a text item
        let rig = try await PasteRig.make(trusted: false)
        defer { rig.lib.cleanUp() }
        let item = try await rig.lib.add(.text, key: "ax", text: "ax-8T-0001", secondsAgo: 5).itemId
        await rig.reopen()
        // when: Return
        await rig.press(.returnKey)
        // then: the panel closed, the text is on the pasteboard, no ⌘V, one SET-PRM-001 with the catalogue text
        #expect(rig.host.hideCount == 1)
        #expect(rig.pasteboard.lastText == "ax-8T-0001")
        #expect(rig.keys.posts == 0)
        #expect(rig.reported.errors.map(\.code) == [.setPrm001])
        #expect(FlotsamStrings.message(for: try #require(rig.reported.errors.first)) == Self.setPrm001Text)
        #expect(try await rig.pasteCount(item) == 1)
        // and: the footer on the next open reads Press command-V to paste
        await rig.reopen()
        #expect(rig.model.footer().notice == "Press ⌘V to paste")
    }

    // OC-3079. Mutation: only the first revoked paste is counted, or the footer notice clears after one use.
    @Test("OC-3079 three Returns with Accessibility revoked each land on the pasteboard, count once each, notice on every open")
    func oc3079_threeReturnsRevoked() async throws {
        // given: Accessibility revoked, a text item pasted 0 times
        let rig = try await PasteRig.make(trusted: false)
        defer { rig.lib.cleanUp() }
        let item = try await rig.lib.add(.text, key: "ax3", text: "three-8T", secondsAgo: 5).itemId
        for expected in 1...3 {
            // when: the panel opens and Return is pressed
            await rig.reopen()
            #expect(rig.model.footer().notice == "Press ⌘V to paste")
            await rig.press(.returnKey)
            // then: one more write, one more count
            #expect(rig.pasteboard.written.count == expected)
            #expect(rig.pasteboard.lastText == "three-8T")
            #expect(try await rig.pasteCount(item) == expected)
        }
        #expect(rig.keys.posts == 0)
    }

    // OC-3080. Mutation: search, preview, pin, tags or delete stop working when Accessibility is off.
    @Test("OC-3080 search, preview, command-P, command-T and command-Delete work with Accessibility revoked")
    func oc3080_otherKeysUnaffected() async throws {
        // given: Accessibility revoked, two items
        let rig = try await PasteRig.make(trusted: false)
        defer { rig.lib.cleanUp() }
        try await rig.lib.add(.text, key: "a", text: "alpha note", secondsAgo: 20)
        let beta = try await rig.lib.add(.text, key: "b", text: "beta note", secondsAgo: 10).itemId
        await rig.reopen()
        // when: searching for beta
        rig.model.setSearchText("beta")
        await rig.model.settled()
        // then: exactly the beta item
        #expect(rig.model.visibleRows.map(\.id) == [beta])
        // when: the search is cleared (Space is a typed character while it holds text), then Space and the organise keys
        rig.model.setSearchText("")
        await rig.model.settled()
        rig.model.select(id: beta)
        rig.model.handle(KeyStroke(.space, []))
        await rig.model.awaitPreview()
        rig.model.handle(KeyStroke(.character("p"), .command))
        rig.model.handle(KeyStroke(.character("t"), .command))
        rig.model.handle(KeyStroke(.delete, .command))
        // then: the preview opened and each command reached its owner with the selected id
        #expect(rig.model.isPreviewOpen)
        #expect(rig.reported.external.map(\.0) == [.pin, .tags, .delete])
        #expect(rig.reported.external.allSatisfy { $0.1 == [beta] })
    }

    // OC-3081. Mutation: the revoked-state notice shows while Accessibility is granted, or a hint goes missing.
    @Test("OC-3081 with Accessibility granted and one row selected the footer has three hints, 7 items and no notice")
    func oc3081_footerGranted() async throws {
        // given: 7 items, Accessibility granted
        let rig = try await PasteRig.make(trusted: true)
        defer { rig.lib.cleanUp() }
        for n in 1...7 { try await rig.lib.add(.text, key: "f\(n)", text: "footer \(n)", secondsAgo: Double(n)) }
        // when: the Library opens and the footer is read
        await rig.reopen()
        let footer = rig.model.footer()
        // then
        #expect(footer.hints.count == 3)
        #expect(footer.countText == "7 items")
        #expect(footer.notice == nil)
    }

    // MARK: Data failures (OC-3084, OC-3085, OC-3101, OC-3104)

    // OC-3084 / OC-3101. Mutation: the missing blob is pasted empty, the item stays, or the error is another code.
    @Test("OC-3084 / OC-3101 a missing blob pastes nothing, reports LIB-IO-001, and the item is removed from search and count")
    func oc3084_missingBlob() async throws {
        // given: two rich items; the blobs of one are deleted from disk
        let rig = try await PasteRig.make()
        defer { rig.lib.cleanUp() }
        let html = PasteboardRepresentation(uti: "public.html", data: Data("<i>x</i>".utf8))
        let doomed = try await rig.lib.add(.richText, key: "doomed", text: "vanish-8t", secondsAgo: 5, representations: [html]).itemId
        let survivor = try await rig.lib.add(.richText, key: "alive", text: "survivor-8t", secondsAgo: 50, representations: [html]).itemId
        let doomedBlobs = blobDigests(of: doomed, in: rig.lib.root)
        #expect(!doomedBlobs.isEmpty)
        try deleteBlobs(of: doomed, in: rig.lib.root)
        await rig.reopen()
        #expect(try await rig.lib.allRows().count == 2)
        // when: the doomed item is pasted
        rig.model.select(id: doomed)
        await rig.press(.returnKey)
        // then: nothing pasted, LIB-IO-001 with the catalogue text
        #expect(rig.pasteboard.written.isEmpty)
        #expect(rig.keys.posts == 0)
        #expect(rig.reported.errors.map(\.code) == [.libIo001])
        #expect(FlotsamStrings.message(for: try #require(rig.reported.errors.first)) == Self.libIo001Text)
        // and: the count is 2 - 1, only the survivor remains, and searching for the doomed text finds nothing
        #expect(try await rig.lib.allRows().map(\.id) == [survivor])
        #expect(rig.model.totalCount == 1)
        rig.model.setSearchText("vanish-8t")
        await rig.model.settled()
        #expect(rig.model.visibleRows.isEmpty)
    }

    // OC-3085 / OC-3104. Mutation: the failure shows an empty list instead of the error state, Retry does nothing,
    // or search and Esc stop answering while it is shown.
    @Test("OC-3085 / OC-3104 a failed history read shows the error state, search and Esc still answer, Retry recovers")
    func oc3085_readFailureAndRetry() async throws {
        // given: two items and a source whose reads fail
        let lib = try await RealLibrary.make()
        defer { lib.cleanUp() }
        try await lib.add(.text, key: "r1", text: "recover one", secondsAgo: 5)
        try await lib.add(.text, key: "r2", text: "recover two", secondsAgo: 10)
        let source = UnreadableSource(lib.database)
        source.unreadable = true
        let rig = PasteRig(lib: lib, trusted: true, source: source)
        // when: the Library opens
        await rig.reopen()
        // then: the failed state with STO-DB-004's text, the title, and a Retry button; the error is inline, not a HUD
        guard case .failed(let error) = rig.model.loadState else {
            Issue.record("expected .failed, got \(rig.model.loadState)")
            return
        }
        #expect(error.code == .stoDb004)
        #expect(LibraryText.string(LibraryText.errorTitle) == "History unavailable")
        #expect(FlotsamStrings.message(for: error) == Self.stoDb004Text)
        #expect(LibraryText.string(LibraryText.retryButton) == "Retry")
        #expect(rig.reported.errors.isEmpty)
        // when: typing in the search field, then Esc twice
        rig.model.setSearchText("rec")
        #expect(rig.model.searchText == "rec")
        rig.model.handle(KeyStroke(.escape, []))
        #expect(rig.model.searchText == "")
        rig.model.handle(KeyStroke(.escape, []))
        // then: Esc cleared the search, then closed the panel
        #expect(rig.host.hideCount == 1)
        // when: the fault clears and Retry runs
        source.unreadable = false
        await rig.model.retry()
        // then: the two items show
        #expect(rig.model.loadState == .loaded)
        #expect(rig.model.visibleRows.count == 2)
    }

    // MARK: VoiceOver length (OC-3087)

    // OC-3087. Mutation: the limit moves to 140 (the whole primary line) or 101.
    @Test("OC-3087 a 300-character item is spoken with at most 100 characters of its text")
    func oc3087_spokenPrimaryLimit() async throws {
        // given: a 300-character text item
        let lib = try await RealLibrary.make()
        defer { lib.cleanUp() }
        try await lib.add(.text, key: "long300", text: String(repeating: "Z", count: 300))
        let row = try #require(try await lib.allRows().first)
        // when: its row presentation is built
        let label = LibraryRowPresentation(row: row, position: 0, now: Date()).accessibilityLabel
        // then: 100 of the characters are spoken, not 101
        #expect(label.contains(String(repeating: "Z", count: 100)))
        #expect(!label.contains(String(repeating: "Z", count: 101)))
    }

    // MARK: Paste never edits (OC-3095, OC-3096)

    private func seedThree(_ rig: PasteRig) async throws -> [UUID] {
        let text = try await rig.lib.add(.text, key: "keep-text", text: "kept text", secondsAgo: 30).itemId
        try await rig.lib.database.setNote("kept note", for: text).get()
        _ = try await rig.lib.database.createTagAndApply(name: "keep", to: [text]).get()
        let rich = try await rig.lib.add(
            .richText, key: "keep-rich", text: "kept rich", secondsAgo: 20,
            representations: [PasteboardRepresentation(uti: "public.html", data: Data("<b>kept</b>".utf8))]).itemId
        let image = try await rig.lib.add(
            .image, key: "keep-image", secondsAgo: 10,
            representations: [PasteboardRepresentation(uti: "public.png", data: ContractPNG.make(width: 30, height: 20))]).itemId
        return [text, rich, image]
    }

    // OC-3095 (Times copied is not readable through the package's public API; the other fields are). Mutation: a paste
    // rewrites the blob, the note, the tags or the text, or re-ingests and changes the count.
    @Test("OC-3095 five pastes by Return, Option-Return, Shift-Return and command-digit change no stored content")
    func oc3095_pasteNeverEdits() async throws {
        // given: a text item with note and tag, a rich item and an image item with blobs
        let rig = try await PasteRig.make()
        defer { rig.lib.cleanUp() }
        let ids = try await seedThree(rig)
        var before: [UUID: StoredState] = [:]
        for id in ids { before[id] = try await state(of: id, in: rig) }
        #expect(before[ids[1]]?.blobDigests.isEmpty == false)
        #expect(before[ids[2]]?.blobDigests.isEmpty == false)
        #expect(before[ids[0]]?.note == "kept note")
        #expect(before[ids[0]]?.tags == ["keep"])
        // when: each item is pasted five times
        for id in ids {
            let ways: [(KeyInput, ChordModifiers)] = [(.returnKey, []), (.character("0"), .option), (.returnKey, .shift), (.character("1"), .command), (.returnKey, [])]
            for (input, modifiers) in ways {
                await rig.reopen()
                rig.model.select(id: id)
                if modifiers == .option {
                    await rig.press(.returnKey, .option)
                } else if modifiers == .command {
                    let position = try #require(rig.model.visibleRows.firstIndex { $0.id == id }) + 1
                    await rig.press(.character(Character(String(position))), .command)
                } else {
                    await rig.press(input, modifiers)
                }
            }
        }
        // then: nothing stored changed and the library still holds exactly these three
        for id in ids { #expect(try await state(of: id, in: rig) == before[id]) }
        #expect(Set(try await rig.lib.allRows().map(\.id)) == Set(ids))
        for id in ids { #expect(try await rig.pasteCount(id) == 5) }
    }

    // OC-3096. Mutation: a way of placing skips the count, counts twice, or opening and Esc count as a paste.
    @Test("OC-3096 Return, Shift-Return, command-1, context-menu Copy and a revoked Return each add one; open and Esc add none")
    func oc3096_pasteCountAcrossWays() async throws {
        // given: a text item pasted twice already (p = 2), Accessibility granted
        let rig = try await PasteRig.make()
        defer { rig.lib.cleanUp() }
        let item = try await rig.lib.add(.text, key: "count", text: "count me", secondsAgo: 5).itemId
        for _ in 0..<2 {
            await rig.reopen()
            await rig.press(.returnKey)
        }
        #expect(try await rig.pasteCount(item) == 2)
        // when: opening and Esc-closing the Library a few times
        for _ in 0..<3 {
            await rig.reopen()
            rig.model.handle(KeyStroke(.escape, []))
        }
        // then: still 2
        #expect(try await rig.pasteCount(item) == 2)
        // when: the five ways
        await rig.reopen()
        await rig.press(.returnKey)
        await rig.reopen()
        await rig.press(.returnKey, .shift)
        await rig.reopen()
        await rig.press(.character("1"), .command)
        await rig.reopen()
        rig.model.perform(.paste(.copyOnly))
        await rig.model.pasteTask?.value
        rig.trust.accessibility = false
        await rig.reopen()
        await rig.press(.returnKey)
        // then: p + 5
        #expect(try await rig.pasteCount(item) == 7)
        #expect(try await rig.lib.allRows().count == 1)
    }

    // MARK: No OCR (OC-3098)

    private func pelicanPNG() -> Data {
        let context = CGContext(
            data: nil, width: 300, height: 100, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 300, height: 100))
        context.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))
        let font = CTFontCreateWithName("Helvetica-Bold" as CFString, 56, nil)
        let attributes = [kCTFontAttributeName: font, kCTForegroundColorFromContextAttributeName: true] as CFDictionary
        let line = CTLineCreateWithAttributedString(CFAttributedStringCreate(nil, "Pelican" as CFString, attributes))
        context.textPosition = CGPoint(x: 10, y: 30)
        CTLineDraw(line, context)
        let output = NSMutableData()
        let destination = CGImageDestinationCreateWithData(output, "public.png" as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, context.makeImage()!, nil)
        precondition(CGImageDestinationFinalize(destination), "test png encode failed")
        return output as Data
    }

    // OC-3098. Mutation: image pixels are run through text recognition and indexed.
    @Test("OC-3098 an image that shows the word Pelican is not found by searching pelican")
    func oc3098_noOCR() async throws {
        // given: an image whose pixels spell Pelican (no text field), and an unrelated text item
        let rig = try await PasteRig.make()
        defer { rig.lib.cleanUp() }
        let image = try await rig.lib.add(
            .image, key: "pelican-image", secondsAgo: 5, representations: [PasteboardRepresentation(uti: "public.png", data: pelicanPNG())]).itemId
        try await rig.lib.add(.text, key: "heron", text: "heron facts", secondsAgo: 50)
        await rig.reopen()
        // when: pelican is typed
        rig.model.setSearchText("pelican")
        await rig.model.settled()
        // then: no results
        #expect(rig.model.visibleRows.isEmpty)
        #expect(rig.model.isNoResults)
        // control: a text item with the word is found, and the image is still not
        let text = try await rig.lib.add(.text, key: "pelican-text", text: "pelican facts", secondsAgo: 1).itemId
        rig.model.setSearchText("")
        await rig.model.settled()
        rig.model.setSearchText("pelican")
        await rig.model.settled()
        #expect(rig.model.visibleRows.map(\.id) == [text])
        #expect(!rig.model.visibleRows.map(\.id).contains(image))
    }

    // MARK: Target changed or ⌘V not posted (OC-3100)

    // OC-3100. Mutation: the failure is silent, another code, or the item is taken off the pasteboard.
    @Test("OC-3100 when the target is not frontmost, or command-V cannot be posted, the item stays on the clipboard with LIB-OS-001", arguments: [
        "target changed", "key not posted",
    ])
    func oc3100_pasteIntoWrongTarget(scenario: String) async throws {
        // given: a text item and either another app frontmost for the whole window, or a key poster that fails
        let rig = try await PasteRig.make()
        defer { rig.lib.cleanUp() }
        let item = try await rig.lib.add(.text, key: "os", text: "os-8T-0001", secondsAgo: 5).itemId
        await rig.reopen()
        if scenario == "target changed" {
            rig.frontmost.current = FrontmostApp(bundleId: "com.example.other", processId: 999)
        } else {
            rig.keys.succeeds = false
        }
        // when: Return
        await rig.press(.returnKey)
        // then: the text is on the pasteboard, LIB-OS-001 with the catalogue text, no successful ⌘V, the paste counted
        #expect(rig.pasteboard.lastText == "os-8T-0001")
        #expect(rig.reported.errors.map(\.code) == [.libOs001])
        #expect(FlotsamStrings.message(for: try #require(rig.reported.errors.first)) == Self.libOs001Text)
        #expect(rig.keys.posts == (scenario == "key not posted" ? 1 : 0))
        #expect(try await rig.pasteCount(item) == 1)
    }
}
