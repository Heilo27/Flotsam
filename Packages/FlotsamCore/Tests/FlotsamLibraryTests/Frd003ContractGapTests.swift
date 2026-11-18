import CoreGraphics
import FlotsamBase
import FlotsamPaste
import FlotsamStorage
import Foundation
import ImageIO
import Testing
@testable import FlotsamLibrary

// FRD-003 8T gap-fill: the contract ids in .claude/oracle/frd-003-contract.json that no other suite cites and that have
// a seam below the AppKit layer. Same arrangement as Frd003ContractSupport.swift (real FlotsamDatabase in a temp folder,
// shipping PasteService, fakes only at the OS edges); expected values are literals from the oracle (blind).
//
// What these cannot see, and why (reported as "no seam: manual"): the hotkey itself, TextEdit's document text, the
// target app's rendering of the paste, the HUD's placement and 2.5 s timing, VoiceOver's actions menu, the SwiftUI
// context menu's order, and the network. Each test names the half it covers.

// MARK: Recording doubles (a gap-local rig, because ContractKeys cannot see the panel, the pasteboard or the target at
// the moment ⌘V is posted, and ContractFrontmost cannot change its answer mid-sequence)

/// The panel, with a hook that runs when it hides: "a script activates Calculator within 100 ms of Return".
@MainActor
final class GapHost: PasteHost {
    private(set) var isPanelVisible = true
    private(set) var hideCount = 0
    var onHide: () -> Void = {}
    func show() { isPanelVisible = true }
    func hidePanel() { hideCount += 1; isPanelVisible = false; onHide() }
}

/// Reports `current` until `restoredAfterReads` reads have happened, then `restored` (nil: never restored).
@MainActor
final class GapFrontmost: FrontmostAppProvider {
    var current: FrontmostApp?
    var restored: FrontmostApp?
    var restoredAfterReads: Int?
    private(set) var reads = 0
    init(_ current: FrontmostApp?) { self.current = current }
    func frontmost() -> FrontmostApp? {
        reads += 1
        if let after = restoredAfterReads, reads > after { return restored }
        return current
    }
}

/// Records what the world looked like at the instant ⌘V was posted.
@MainActor
final class GapKeys: KeyEventPoster {
    struct Post {
        let target: FrontmostApp
        let panelVisible: Bool
        let changeCount: Int
        let text: String?
    }
    private(set) var posts: [Post] = []
    private let host: GapHost
    private let pasteboard: ContractPasteboard
    init(host: GapHost, pasteboard: ContractPasteboard) {
        self.host = host
        self.pasteboard = pasteboard
    }
    func postPaste(to target: FrontmostApp) -> Bool {
        posts.append(Post(target: target, panelVisible: host.isPanelVisible, changeCount: pasteboard.changeCount, text: pasteboard.lastText))
        return true
    }
}

@MainActor
struct GapRig {
    let lib: RealLibrary
    let pasteboard = ContractPasteboard()
    let host = GapHost()
    let frontmost: GapFrontmost
    let keys: GapKeys
    let reported = Harness.Reported()
    let target = FrontmostApp(bundleId: "com.apple.TextEdit", processId: 4242)
    let model: LibraryViewModel

    init(lib: RealLibrary) {
        self.lib = lib
        let frontmost = GapFrontmost(target)
        self.frontmost = frontmost
        let keys = GapKeys(host: host, pasteboard: pasteboard)
        self.keys = keys
        let service = PasteService(
            store: lib.database, pasteboard: pasteboard, files: LocalFileSystem(), frontmost: frontmost,
            accessibility: ContractTrust(true), keys: keys, clock: ContractClock(), ownWrites: OwnWriteLedger())
        let reported = reported
        model = LibraryViewModel(
            source: lib.database, paster: service, host: host, preferences: FakePreferences(),
            effects: LibraryEffects(
                report: { reported.errors.append($0) }, external: { reported.external.append(($0, $1)) },
                isAccessibilityTrusted: { true }))
    }

    static func make() async throws -> GapRig { GapRig(lib: try await RealLibrary.make()) }

    /// The panel opening again: visible, search cleared, newest selected, target recorded.
    func reopen() async {
        host.show()
        await model.open(target: target)
    }

    func press(_ input: LibraryKeyInput, _ modifiers: ChordModifiers = []) async {
        model.handle(LibraryKeyStroke(input, modifiers))
        await model.pasteTask?.value
        await model.settled()
    }

    /// A context-menu command: it acts on the row it was opened on, selecting it first (the row view's `act`).
    func contextMenu(on id: UUID, _ command: LibraryCommand) async {
        if !model.selection.contains(id) { model.select(id: id) }
        model.perform(command)
        await model.pasteTask?.value
        await model.settled()
    }

    func pasteCount(_ id: UUID) async throws -> Int {
        try await lib.allRows().first { $0.id == id }?.pasteCount ?? -1
    }
}

@MainActor
@Suite struct Frd003ContractGapTests {
    private static let libOs001Text = "Couldn't paste into that app. The item is on your clipboard; press ⌘V."
    private static let ownWriteTypes = ["com.flotsam.own-write", "org.nspasteboard.AutoGeneratedType"]
    private let target = FrontmostApp(bundleId: "com.apple.TextEdit", processId: 4242)

    private func search(_ lib: RealLibrary, _ query: String) async -> [UUID] {
        lib.model.setSearchText(query)
        await lib.model.settled()
        return lib.model.loadedRows.map(\.id)
    }

    private func pixelSize(of representation: PasteboardRepresentation) throws -> (width: Int, height: Int) {
        let source = try #require(CGImageSourceCreateWithData(representation.data as CFData, nil))
        let decoded = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        return (decoded.width, decoded.height)
    }

    /// The file names on the pasteboard's file-url representations, in written order.
    private func fileNames(on pasteboard: ContractPasteboard) -> [String] {
        (pasteboard.written.last ?? []).filter { $0.uti == "public.file-url" }.compactMap {
            URL(string: String(decoding: $0.data, as: UTF8.self))?.lastPathComponent
        }
    }

    /// Three real files in a fresh temp folder: names, folder.
    private func threeFiles() throws -> (folder: URL, urls: [URL]) {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("flotsam-8t-gap-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let urls = ["alpha.txt", "beta.txt", "gamma.txt"].map { folder.appendingPathComponent($0) }
        for url in urls { try Data("x".utf8).write(to: url) }
        return (folder, urls)
    }

    // MARK: Open and close (OC-3002 Esc half, OC-3007)

    // OC-3002 (Esc half; the hotkey-again half is the AppKit panel controller, no seam: manual). Also the model half of
    // OC-3001: opening writes nothing. Mutation: Esc with nothing to clear writes the pasteboard, posts ⌘V, or fails to hide.
    @Test("OC-3002 Esc with an empty query and preview closed closes the panel and leaves the pasteboard alone; Esc with a query only clears it")
    func oc3002_escapeCloses() async throws {
        // given: a text item, the panel opened (opening must itself write nothing: OC-3001's 'D is still base')
        let rig = try await GapRig.make()
        defer { rig.lib.cleanUp() }
        try await rig.lib.add(.text, key: "esc", text: "esc-8T-0001", secondsAgo: 5)
        await rig.reopen()
        #expect(rig.pasteboard.changeCount == 0)
        #expect(rig.keys.posts.isEmpty)
        // when: Esc with a query typed (negative case), then Esc with the query empty and the preview closed
        rig.model.setSearchText("esc")
        await rig.model.settled()
        await rig.press(.escape)
        // then: the first Esc only cleared the search; the panel is still open
        #expect(rig.model.searchText == "")
        #expect(rig.host.hideCount == 0)
        #expect(rig.host.isPanelVisible)
        await rig.press(.escape)
        // and: the second closes it, with the pasteboard untouched and no key posted
        #expect(rig.host.hideCount == 1)
        #expect(!rig.host.isPanelVisible)
        #expect(rig.pasteboard.changeCount == 0)
        #expect(rig.pasteboard.written.isEmpty)
        #expect(rig.keys.posts.isEmpty)
    }

    // OC-3007 (the ingest-to-render half; the 50 ms hotkey race needs the running app: manual). Mutation: open reads a
    // cached page, so an item ingested just before open is missing or sits below older rows.
    @Test("OC-3007 an item copied just before the Library opens is the first rendered row and the count is one higher")
    func oc3007_freshCopyIsTopRow() async throws {
        // given: five older items, the Library opened once (count 5), then closed
        let rig = try await GapRig.make()
        defer { rig.lib.cleanUp() }
        var older: [UUID] = []
        for n in 0..<5 { older.append(try await rig.lib.add(.text, key: "old\(n)", text: "old number \(n)", secondsAgo: 100 + Double(n)).itemId) }
        await rig.reopen()
        #expect(rig.model.totalCount == 5)
        // when: a unique text Q is copied and the Library opens again
        let tag = UUID().uuidString.lowercased()
        let q = try await rig.lib.add(.text, key: "q", text: "fresh-\(tag)", secondsAgo: 0).itemId
        await rig.reopen()
        // then: Q is the first rendered row, selected, count 6, the five older items follow in their order
        #expect(rig.model.visibleRows.first?.id == q)
        #expect(rig.model.selection == [q])
        #expect(rig.model.totalCount == 6)
        #expect(rig.model.visibleRows.map(\.id) == [q] + older)
        // and: copying an item that already exists moves it to the top without adding a row (count stays 6)
        _ = try await rig.lib.add(.text, key: "old3", text: "old number 3", secondsAgo: 0)
        await rig.reopen()
        #expect(rig.model.visibleRows.first?.id == older[3])
        #expect(rig.model.totalCount == 6)
    }

    // MARK: Preview over the network (OC-3059 URL half)

    // OC-3059 (URL half; 'Flotsam opens zero network connections' needs a network monitor: manual). Mutation: the link
    // preview carries image bytes or drops the URL text.
    @Test("OC-3059 a link preview shows only the URL text: no image, no rich body")
    func oc3059_linkPreviewIsTextOnly() async throws {
        // given: a link item https://example.com/a and a text item with different text
        let rig = try await GapRig.make()
        defer { rig.lib.cleanUp() }
        let link = try await rig.lib.add(.link, key: "link", text: "https://example.com/a", secondsAgo: 5).itemId
        try await rig.lib.add(.text, key: "other", text: "https://example.com/other", secondsAgo: 50)
        // when: preview is opened on the link
        await rig.reopen()
        rig.model.select(id: link)
        rig.model.handle(LibraryKeyStroke(.space))
        await rig.model.awaitPreview()
        // then: the text is the URL itself and nothing else was fetched or attached
        let preview = try #require(rig.model.preview)
        #expect(preview.itemId == link)
        #expect(preview.text(showingAll: true) == "https://example.com/a")
        #expect(preview.imageData == nil)
        #expect(preview.richTextRTF == nil)
        #expect(preview.memberPaths.isEmpty)
        #expect(preview.fields.map(\.value).allSatisfy { !$0.contains("example.com") })
    }

    // MARK: Paste sequence (OC-3074, OC-3075, OC-3076, OC-3094)

    // OC-3074 (the pasteboard and key-post half; what TextEdit's document ends up reading is the target app: manual).
    // Mutation: the panel is hidden after ⌘V (or never), the key is posted twice, or the post goes to another app.
    @Test("OC-3074 Return writes the text, closes the panel, then posts command-V exactly once, to the target, with the text on the pasteboard")
    func oc3074_pastedOnceAfterPanelClosed() async throws {
        // given: a text item 'once-<uuid>' and a bystander, the panel open over TextEdit
        let rig = try await GapRig.make()
        defer { rig.lib.cleanUp() }
        let tag = UUID().uuidString.lowercased()
        let item = try await rig.lib.add(.text, key: "once", text: "once-\(tag)", secondsAgo: 5).itemId
        let other = try await rig.lib.add(.text, key: "bystander", text: "bystander", secondsAgo: 50).itemId
        await rig.reopen()
        #expect(rig.model.selection == [item])
        // when: Return
        await rig.press(.returnKey)
        // then: one post, addressed to TextEdit, made after the panel closed and after the text was written once
        #expect(rig.keys.posts.count == 1)
        let post = try #require(rig.keys.posts.first)
        #expect(post.target.bundleId == "com.apple.TextEdit")
        #expect(post.target.processId == 4242)
        #expect(!post.panelVisible)
        #expect(post.text == "once-\(tag)")
        #expect(post.changeCount == 1)
        // and: the search field never saw a 'v', Times pasted moved for the item only, no error
        #expect(rig.model.searchText == "")
        #expect(try await rig.pasteCount(item) == 1)
        #expect(try await rig.pasteCount(other) == 0)
        #expect(rig.reported.errors.isEmpty)
    }

    // OC-3075 (the pasteboard, no-post and error half; the HUD's top-centre placement and 2.5 s life, and Calculator
    // receiving nothing, are the running app: manual). Mutation: the target check is skipped so ⌘V is posted anyway, the
    // item is taken off the pasteboard, or the failure is silent.
    @Test("OC-3075 when another app takes focus as the panel closes, nothing is posted, the item stays on the clipboard, LIB-OS-001 is reported; a target back within the window pastes")
    func oc3075_focusStolenDuringPaste() async throws {
        // given: a text item 'mis-<uuid>'; Calculator becomes frontmost the moment the panel closes and stays there
        let rig = try await GapRig.make()
        defer { rig.lib.cleanUp() }
        let tag = UUID().uuidString.lowercased()
        let item = try await rig.lib.add(.text, key: "mis", text: "mis-\(tag)", secondsAgo: 5).itemId
        let calculator = FrontmostApp(bundleId: "com.apple.calculator", processId: 777)
        let frontmost = rig.frontmost
        rig.host.onHide = { frontmost.current = calculator }
        await rig.reopen()
        // when: Return
        await rig.press(.returnKey)
        // then: no ⌘V anywhere, the text is on the pasteboard exactly once, LIB-OS-001 with the catalogue text
        #expect(rig.keys.posts.isEmpty)
        #expect(rig.pasteboard.written.count == 1)
        #expect(rig.pasteboard.lastText == "mis-\(tag)")
        #expect(rig.reported.errors.map(\.code) == [.libOs001])
        #expect(FlotsamStrings.message(for: try #require(rig.reported.errors.first)) == Self.libOs001Text)
        #expect(try await rig.pasteCount(item) == 1)
        // and: the same paste succeeds when TextEdit is frontmost again after 5 polls (50 ms, inside the window)
        rig.frontmost.restored = rig.target
        rig.frontmost.restoredAfterReads = rig.frontmost.reads + 5
        await rig.reopen()
        await rig.press(.returnKey)
        #expect(rig.keys.posts.count == 1)
        #expect(rig.keys.posts.first?.target.bundleId == "com.apple.TextEdit")
        #expect(rig.reported.errors.count == 1)
    }

    // OC-3076. Mutation: the sequence writes the pasteboard again after the ⌘V post (or on failure), so changeCount is k + 2.
    @Test("OC-3076 a paste writes the pasteboard exactly once: changeCount is k + 1 at the post and after it", arguments: [
        "return", "option-return", "shift-return", "target never returns",
    ])
    func oc3076_writtenOnce(scenario: String) async throws {
        // given: a rich text item, the panel open, the pasteboard changeCount recorded as k
        let rig = try await GapRig.make()
        defer { rig.lib.cleanUp() }
        try await rig.lib.add(
            .richText, key: "rich", text: "once-more", secondsAgo: 5,
            representations: [PasteboardRepresentation(uti: "public.html", data: Data("<b>once</b>-more".utf8))])
        await rig.reopen()
        let k = rig.pasteboard.changeCount
        #expect(k == 0)
        if scenario == "target never returns" { rig.frontmost.current = FrontmostApp(bundleId: "com.example.other", processId: 999) }
        // when: the paste key is pressed and the sequence finishes
        switch scenario {
        case "option-return": await rig.press(.returnKey, .option)
        case "shift-return": await rig.press(.returnKey, .shift)
        default: await rig.press(.returnKey)
        }
        await Task.yield()
        // then: one write, whatever the outcome
        #expect(rig.pasteboard.changeCount == k + 1)
        #expect(rig.pasteboard.written.count == 1)
        let expectedPosts = (scenario == "return" || scenario == "option-return") ? 1 : 0
        #expect(rig.keys.posts.count == expectedPosts)
        // and: at the moment of the post the count was already k + 1 (no write was still to come)
        #expect(rig.keys.posts.allSatisfy { $0.changeCount == k + 1 })
    }

    // OC-3094 (context-menu path; TextEdit's text is the target app: manual). Mutation: the menu's Paste copies only,
    // pastes the previously selected row, or skips the ⌘V.
    @Test("OC-3094 Paste from a row's context menu pastes that row exactly as Return does")
    func oc3094_contextMenuPaste() async throws {
        // given: 'cm-<uuid>' and a newer item that is the selected row when the menu is opened on 'cm'
        let rig = try await GapRig.make()
        defer { rig.lib.cleanUp() }
        let tag = UUID().uuidString.lowercased()
        let cm = try await rig.lib.add(.text, key: "cm", text: "cm-\(tag)", secondsAgo: 50).itemId
        let newer = try await rig.lib.add(.text, key: "newer", text: "newer-text", secondsAgo: 5).itemId
        await rig.reopen()
        #expect(rig.model.selection == [newer])
        // when: Paste is chosen from the menu of 'cm'
        await rig.contextMenu(on: cm, .paste(.paste))
        // then: 'cm' was pasted (not the selected newer row): text on the pasteboard, one ⌘V to TextEdit after the panel closed
        #expect(rig.pasteboard.lastText == "cm-\(tag)")
        #expect(rig.keys.posts.count == 1)
        let post = try #require(rig.keys.posts.first)
        #expect(post.target.bundleId == "com.apple.TextEdit")
        #expect(!post.panelVisible)
        #expect(post.text == "cm-\(tag)")
        #expect(try await rig.pasteCount(cm) == 1)
        #expect(try await rig.pasteCount(newer) == 0)
        let fromMenu = try #require(rig.pasteboard.written.last).map(\.uti).sorted()
        // and: Return on the same item writes the same types and posts the same way
        await rig.reopen()
        rig.model.select(id: cm)
        await rig.press(.returnKey)
        #expect(try #require(rig.pasteboard.written.last).map(\.uti).sorted() == fromMenu)
        #expect(rig.keys.posts.count == 2)
        #expect(rig.pasteboard.lastText == "cm-\(tag)")
        #expect(rig.reported.errors.isEmpty)
    }

    // MARK: What lands on the pasteboard per kind (OC-3064, OC-3065, OC-3066, OC-3067)

    // OC-3064 (pasteboard half; 'the pasted text in Notes is not bold' is the target app: manual). Mutation: Option-Return
    // leaves public.html or public.rtf on the pasteboard, or writes no plain text.
    @Test("OC-3064 Option-Return on a rich item writes plain text and no html or rtf; Return on the same item keeps them; an image keeps its pixels")
    func oc3064_plainTextOnly() async throws {
        // given: a rich item with a bold word (html and rtf stored) and an image item
        let rig = try await GapRig.make()
        defer { rig.lib.cleanUp() }
        let rich = try await rig.lib.add(
            .richText, key: "bold", text: "a bold word", secondsAgo: 5,
            representations: [
                PasteboardRepresentation(uti: "public.html", data: Data("a <b>bold</b> word".utf8)),
                PasteboardRepresentation(uti: "public.rtf", data: Data("{\\rtf1 a {\\b bold} word}".utf8)),
            ]).itemId
        let image = try await rig.lib.add(
            .image, key: "img", secondsAgo: 50,
            representations: [PasteboardRepresentation(uti: "public.png", data: ContractPNG.make(width: 30, height: 20))]).itemId
        await rig.reopen()
        // when: Option-Return on the rich item
        rig.model.select(id: rich)
        await rig.press(.returnKey, .option)
        // then: only plain text (plus the two own-write markers), the text intact, ⌘V posted
        let written = try #require(rig.pasteboard.written.last)
        #expect(written.map(\.uti).sorted() == ["com.flotsam.own-write", "org.nspasteboard.AutoGeneratedType", "public.utf8-plain-text"])
        #expect(!written.contains { $0.uti == "public.html" || $0.uti == "public.rtf" })
        #expect(rig.pasteboard.lastText == "a bold word")
        #expect(rig.keys.posts.count == 1)
        // and: plain Return on the same item keeps the formatting (so the plain write is not the default)
        await rig.reopen()
        rig.model.select(id: rich)
        await rig.press(.returnKey)
        let formatted = try #require(rig.pasteboard.written.last).map(\.uti)
        #expect(formatted.contains("public.html"))
        #expect(formatted.contains("public.rtf"))
        // and: Option-Return on an image has no plain text to fall back to, so its pixels stay
        await rig.reopen()
        rig.model.select(id: image)
        await rig.press(.returnKey, .option)
        let imageTypes = try #require(rig.pasteboard.written.last).map(\.uti)
        #expect(imageTypes.contains("public.png"))
        #expect(!imageTypes.contains("public.utf8-plain-text"))
    }

    // OC-3065 (pasteboard half; the image appearing in Preview or Notes is the target app: manual). Mutation: Return on an
    // image writes no pixels, a thumbnail, or a file reference.
    @Test("OC-3065 Return on a 300 x 200 image puts an image of 300 x 200 pixels on the pasteboard and posts command-V")
    func oc3065_imageReturn() async throws {
        // given: a 300 x 200 image item and a 120 x 80 one
        let rig = try await GapRig.make()
        defer { rig.lib.cleanUp() }
        let big = try await rig.lib.add(
            .image, key: "big", secondsAgo: 5,
            representations: [PasteboardRepresentation(uti: "public.png", data: ContractPNG.make(width: 300, height: 200))]).itemId
        let small = try await rig.lib.add(
            .image, key: "small", secondsAgo: 50,
            representations: [PasteboardRepresentation(uti: "public.png", data: ContractPNG.make(width: 120, height: 80))]).itemId
        await rig.reopen()
        // when: Return on the 300 x 200 one
        rig.model.select(id: big)
        await rig.press(.returnKey)
        // then: a standard image type decoding to 300 x 200, no file reference, one ⌘V
        let written = try #require(rig.pasteboard.written.last)
        let imageRep = try #require(written.first { ["public.png", "public.tiff"].contains($0.uti) })
        let size = try pixelSize(of: imageRep)
        #expect(size.width == 300)
        #expect(size.height == 200)
        #expect(!written.contains { $0.uti == "public.file-url" })
        #expect(rig.keys.posts.count == 1)
        // and: the other image is a different size (the 300 x 200 is the item's, not a constant)
        await rig.reopen()
        rig.model.select(id: small)
        await rig.press(.returnKey)
        let smallSize = try pixelSize(of: try #require(rig.pasteboard.written.last?.first { $0.uti == "public.png" }))
        #expect(smallSize.width == 120)
        #expect(smallSize.height == 80)
    }

    // OC-3066 (pasteboard half; the files appearing in Finder's folder E is the target app: manual). Mutation: the bundle
    // is written as one file, as text, or reordered.
    @Test("OC-3066 Return on a bundle of 3 existing files puts 3 file references named alpha, beta, gamma on the pasteboard")
    func oc3066_bundleOfThree() async throws {
        // given: three real files and a bundle of them
        let rig = try await GapRig.make()
        defer { rig.lib.cleanUp() }
        let files = try threeFiles()
        defer { try? FileManager.default.removeItem(at: files.folder) }
        let bundle = try await rig.lib.add(
            .bundle, key: "three", secondsAgo: 5,
            members: files.urls.map { IngestMember(path: $0.path, bookmark: nil, isDirectory: false) }).itemId
        await rig.reopen()
        rig.model.select(id: bundle)
        // when: Return
        await rig.press(.returnKey)
        // then: exactly 3 file references, in member order, each pointing at an existing file; ⌘V posted once
        #expect(fileNames(on: rig.pasteboard) == ["alpha.txt", "beta.txt", "gamma.txt"])
        let urls = (rig.pasteboard.written.last ?? []).filter { $0.uti == "public.file-url" }
            .compactMap { URL(string: String(decoding: $0.data, as: UTF8.self)) }
        #expect(urls.count == 3)
        #expect(urls.allSatisfy { FileManager.default.fileExists(atPath: $0.path) })
        #expect(rig.keys.posts.count == 1)
        #expect(rig.reported.errors.isEmpty)
    }

    // OC-3067 (pasteboard half). Mutation: the missing-member filter is dropped, so the deleted file is still referenced,
    // or the whole paste fails because one member is gone.
    @Test("OC-3067 Return on a bundle with one member deleted puts exactly the 2 existing files on the pasteboard")
    func oc3067_bundleWithOneGone() async throws {
        // given: a bundle of three files, 'beta.txt' deleted from disk afterwards
        let rig = try await GapRig.make()
        defer { rig.lib.cleanUp() }
        let files = try threeFiles()
        defer { try? FileManager.default.removeItem(at: files.folder) }
        let bundle = try await rig.lib.add(
            .bundle, key: "three-gone", secondsAgo: 5,
            members: files.urls.map { IngestMember(path: $0.path, bookmark: nil, isDirectory: false) }).itemId
        try FileManager.default.removeItem(at: files.urls[1])
        await rig.reopen()
        rig.model.select(id: bundle)
        // when: Return
        await rig.press(.returnKey)
        // then: alpha and gamma only; no LIB-DAT-001 (some files remain), ⌘V posted, the paste counted
        #expect(fileNames(on: rig.pasteboard) == ["alpha.txt", "gamma.txt"])
        #expect(!fileNames(on: rig.pasteboard).contains("beta.txt"))
        #expect(rig.keys.posts.count == 1)
        #expect(rig.reported.errors.isEmpty)
        #expect(try await rig.pasteCount(bundle) == 1)
    }

    // MARK: Row speech and context menu (OC-3086, OC-3092, OC-3093)

    // OC-3086 (the spoken label; the VoiceOver actions menu is the running app: manual). The catalogue says 'Pinned' where
    // the contract says 'pinned': the check is case-insensitive on that last word, which speech does not distinguish.
    // Mutation: the pinned word is spoken before the age, dropped, or the source is spoken before the text.
    @Test("OC-3086 a pinned 'Hello' from Safari copied yesterday is spoken kind, Hello, from Safari, Yesterday, pinned in that order")
    func oc3086_pinnedRowSpeech() {
        // given: a pinned text row copied exactly one day before 'now'
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let yesterday = now.addingTimeInterval(-86_400)
        let pinned = LibraryRowPresentation(
            row: fullRow(1, primary: "Hello", source: "Safari", pinned: true, copiedAt: yesterday), position: 0, now: now)
        let plain = LibraryRowPresentation(
            row: fullRow(2, primary: "Hello", source: "Safari", pinned: false, copiedAt: yesterday), position: 0, now: now)
        let anonymous = LibraryRowPresentation(
            row: fullRow(3, primary: "Hello", source: nil, pinned: true, copiedAt: yesterday), position: 0, now: now)
        // when: VoiceOver reads each row's label
        let spoken = pinned.accessibilityLabel.components(separatedBy: ", ")
        // then: five parts in the contract's order; the last reads 'pinned'
        #expect(spoken.count == 5)
        #expect(Array(spoken.prefix(4)) == ["Text", "Hello", "from Safari", "Yesterday"])
        #expect(spoken.last?.lowercased() == "pinned")
        // and: an unpinned row has no trailing pinned part, and a row with no source skips 'from'
        #expect(plain.accessibilityLabel.components(separatedBy: ", ") == ["Text", "Hello", "from Safari", "Yesterday"])
        #expect(anonymous.accessibilityLabel.components(separatedBy: ", ").map { $0.lowercased() } == ["text", "hello", "yesterday", "pinned"])
    }

    // OC-3092 (the menu's decision and its two strings; the order of the rows in the SwiftUI menu is manual). Mutation:
    // pinActionUnpins answers false for an unselected pinned row, or the Unpin string reads 'Pin'.
    @Test("OC-3092 right-clicking a pinned row offers Unpin in place of Pin; an unpinned row offers Pin")
    func oc3092_unpinInPlaceOfPin() async throws {
        // given: one pinned item (pinned through the shipping organizer) and one unpinned, the unpinned one selected
        let lib = try await RealLibrary.make()
        defer { lib.cleanUp() }
        let pinnedId = try await lib.add(.text, key: "pinned", text: "pinned item", secondsAgo: 10).itemId
        let plainId = try await lib.add(.text, key: "plain", text: "plain item", secondsAgo: 20).itemId
        await lib.model.open(target: target)
        lib.model.select(id: pinnedId)
        #expect(await lib.model.togglePinSelected() == true)
        lib.model.select(id: plainId)
        let pinnedRow = try #require(lib.model.visibleRows.first { $0.id == pinnedId })
        let plainRow = try #require(lib.model.visibleRows.first { $0.id == plainId })
        #expect(pinnedRow.isPinned)
        #expect(!plainRow.isPinned)
        // when: the menu is opened on each row
        let pinnedOffersUnpin = lib.model.pinActionUnpins(menuRowID: pinnedRow.id, isPinned: pinnedRow.isPinned)
        let plainOffersUnpin = lib.model.pinActionUnpins(menuRowID: plainRow.id, isPinned: plainRow.isPinned)
        // then: Unpin for the pinned row, Pin for the other, with these exact words
        #expect(pinnedOffersUnpin)
        #expect(!plainOffersUnpin)
        #expect(LibraryText.string(LibraryText.menuUnpin) == "Unpin")
        #expect(LibraryText.string(LibraryText.menuPin) == "Pin")
        #expect(lib.reported.errors.isEmpty)
    }

    // OC-3093. Mutation: the menu's Delete removes the previously selected row, removes nothing, or leaves the search entry.
    @Test("OC-3093 Delete from a row's context menu removes that row: absent from search, count n - 1, the selected bystander kept")
    func oc3093_contextMenuDelete() async throws {
        // given: 5 items; the newest is selected, the menu is opened on 'ctx-<uuid>'
        let lib = try await RealLibrary.make()
        defer { lib.cleanUp() }
        let tag = UUID().uuidString.lowercased()
        let newest = try await lib.add(.text, key: "newest", text: "newest item", secondsAgo: 1).itemId
        let doomed = try await lib.add(.text, key: "ctx", text: "ctx-\(tag)", secondsAgo: 10).itemId
        var survivors = [newest]
        for n in 0..<3 { survivors.append(try await lib.add(.text, key: "keep\(n)", text: "keeper \(n)", secondsAgo: 20 + Double(n)).itemId) }
        await lib.model.open(target: target)
        #expect(lib.model.totalCount == 5)
        #expect(lib.model.selection == [newest])
        // when: Delete is chosen from the menu of 'ctx' (the row view selects it, then performs the command)
        lib.model.select(id: doomed)
        lib.model.perform(.external(.delete))
        // then: the command was addressed to 'ctx' alone
        #expect(lib.reported.external.count == 1)
        #expect(lib.reported.external.first?.0 == .delete)
        #expect(lib.reported.external.first?.1 == [doomed])
        let removed = await lib.model.deleteSelected()
        #expect(removed == [doomed])
        // and: it is gone from search, the count is 4, every other item is still listed
        let hits = await search(lib, "ctx-\(tag)")
        #expect(hits.isEmpty)
        _ = await search(lib, "")
        #expect(lib.model.totalCount == 4)
        #expect(Set(lib.model.loadedRows.map(\.id)) == Set(survivors))
        #expect(lib.reported.errors.isEmpty)
    }
}
