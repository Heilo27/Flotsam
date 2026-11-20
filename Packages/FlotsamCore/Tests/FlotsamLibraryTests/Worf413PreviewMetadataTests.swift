import FlotsamBase
import FlotsamPaste
import FlotsamStorage
import Foundation
import Testing
@testable import FlotsamLibrary

// TASK-413 blind QA (Worf), branch worf-413. FRD-003 FR-003-14 metadata block, OC-3058 / OC-3061 / OC-3105.
// Order per spec: kind, [hex, rgb for a swatched colour], source app, copied, first copied, times copied, times pasted,
// size, pixel size, one row per tag (colour dot, name), the note. Tag and note rows only when present.
// Expected side is literals (label strings come from the English catalogue). Each test names its red-making change.

@MainActor
@Suite struct Worf413PreviewMetadataTests {
    private let copied = Date(timeIntervalSince1970: 1_700_000_000)

    private func row(
        kind: ItemKind = .text, source: String? = "Safari", pasteCount: Int = 0, byteSize: Int64 = 0, width: Int? = nil, height: Int? = nil
    ) -> ItemRow {
        ItemRow(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000413")!, kind: kind, lastCopiedAt: copied, pasteCount: pasteCount,
            primaryLine: "p", sourceName: source, tagNames: [], isPinned: false, hasTrigger: false, hasShortcut: false,
            pixelWidth: width, pixelHeight: height, memberCount: 0, byteSize: byteSize)
    }

    private func content(
        kind: ItemKind = .text, text: String? = "t", reps: [PasteboardRepresentation] = [], firstCopiedAt: Date? = nil,
        copyCount: Int = 1, note: String? = nil, tags: [ItemTag] = []
    ) -> ItemContent {
        ItemContent(
            kind: kind, plainText: text, representations: reps, members: [], firstCopiedAt: firstCopiedAt, copyCount: copyCount,
            note: note, tags: tags)
    }

    private func labels(_ preview: LibraryPreview) -> [String] { preview.fields.map(\.label) }
    private func value(_ preview: LibraryPreview, _ label: String) -> String? { preview.fields.first { $0.label == label }?.value }

    // Red if the colour rows are placed after Source/Copied, dropped, or the source row is displaced.
    @Test("OC-3058 W413-P1 a #1A2B3C colour lists Kind, Hex, RGB first, then the rest; values 26, 43, 60")
    func w413_colourRows() {
        // given a colour item with a source
        let preview = LibraryPreview(row: row(kind: .color), content: content(kind: .color, text: "#1A2B3C"), imageData: nil)
        // then hex and rgb directly follow kind
        #expect(labels(preview) == ["Kind", "Hex", "RGB", "Source", "Copied", "Times copied"])
        #expect(value(preview, "Hex") == "#1A2B3C")
        #expect(value(preview, "RGB") == "26, 43, 60")
        let swatch = preview.color
        #expect(swatch?.red == 26 && swatch?.green == 43 && swatch?.blue == 60)
    }

    // Red if rgb() text is not normalised to hex, or the rgb row echoes the raw text.
    @Test("W413-P2 an rgb(26, 43, 60) colour shows hex #1A2B3C and rgb 26, 43, 60")
    func w413_rgbNotation() {
        let preview = LibraryPreview(row: row(kind: .color), content: content(kind: .color, text: "rgb(26, 43, 60)"), imageData: nil)
        #expect(value(preview, "Hex") == "#1A2B3C")
        #expect(value(preview, "RGB") == "26, 43, 60")
        #expect(preview.text(showingAll: true) == "rgb(26, 43, 60)")
    }

    // Red if hsl() (or any unreadable notation) gets a swatch or hex/rgb rows. FR-003-14: "shows its text and no swatch".
    @Test("W413-P3 hsl(), a named colour and garbage colour text: no swatch, no Hex or RGB row, text kept")
    func w413_otherNotationNoSwatch() {
        for text in ["hsl(210, 50%, 40%)", "red", "#12", "rgb(1, 2)"] {
            let preview = LibraryPreview(row: row(kind: .color), content: content(kind: .color, text: text), imageData: nil)
            #expect(preview.color == nil, "\(text)")
            #expect(labels(preview) == ["Kind", "Source", "Copied", "Times copied"], "\(text)")
            #expect(preview.text(showingAll: true) == text)
        }
        // and: a colour item with no text at all
        let empty = LibraryPreview(row: row(kind: .color), content: content(kind: .color, text: nil), imageData: nil)
        #expect(empty.color == nil)
        #expect(!labels(empty).contains("Hex"))
    }

    // Red if the swatch is derived from the text regardless of kind (the kind gate is removed).
    @Test("W413-P4 a text item whose text is a hex code gets no swatch and no Hex row")
    func w413_kindGate() {
        let preview = LibraryPreview(row: row(kind: .text), content: content(kind: .text, text: "#1A2B3C"), imageData: nil)
        #expect(preview.color == nil)
        #expect(!labels(preview).contains("Hex") && !labels(preview).contains("RGB"))
    }

    // OC-3061 + OC-3105 at the model layer. Red if any metadata row is reordered, or tag/note placed before Pixel size.
    @Test("OC-3061 OC-3105 W413-P5 full block order: Kind, Source, Copied, First copied, Times copied, Times pasted, Size, Pixel size, Tag, Tag, Note")
    func w413_fullOrder() {
        // given an image with everything
        let tags = [ItemTag(name: "alpha", color: .red), ItemTag(name: "work", color: .blue)]
        let preview = LibraryPreview(
            row: row(kind: .image, pasteCount: 3, byteSize: 2_048, width: 120, height: 80),
            content: content(kind: .image, text: nil, firstCopiedAt: copied.addingTimeInterval(-86_400), copyCount: 7, note: "hero shot", tags: tags),
            imageData: nil)
        // then
        #expect(labels(preview) == [
            "Kind", "Source", "Copied", "First copied", "Times copied", "Times pasted", "Size", "Pixel size", "Tag", "Tag", "Note",
        ])
        #expect(value(preview, "Kind") == "Image")
        #expect(value(preview, "Times copied") == "7")
        #expect(value(preview, "Times pasted") == "3")
        #expect(value(preview, "Pixel size") == "120 × 80")
        #expect(preview.fields.suffix(3).map(\.value) == ["alpha", "work", "hero shot"])
        // and the first-copied row differs from the copied row (one day apart)
        #expect(value(preview, "First copied") != value(preview, "Copied"))
    }

    // Red if tag rows lose their colour (the dot) or a non-tag row gains one.
    @Test("OC-3105 W413-P6 tag rows carry their colour; no other row does")
    func w413_tagColours() {
        let tags = [ItemTag(name: "work", color: .blue), ItemTag(name: "home", color: .green)]
        let preview = LibraryPreview(row: row(), content: content(note: "n", tags: tags), imageData: nil)
        let tagRows = preview.fields.filter { $0.label == "Tag" }
        #expect(tagRows.map(\.value) == ["work", "home"])
        #expect(tagRows.map(\.tagColor) == [.blue, .green])
        #expect(preview.fields.filter { $0.label != "Tag" }.allSatisfy { $0.tagColor == nil })
        #expect(preview.fields.count == 4 + 2 + 1)
    }

    // Red if an empty tag list or a nil / empty note still produces a row (B6: empty case).
    @Test("OC-3105 W413-P7 no tags and a nil or empty note: no Tag or Note row")
    func w413_noTagNoNote() {
        for note in [nil, ""] as [String?] {
            let preview = LibraryPreview(row: row(), content: content(note: note, tags: []), imageData: nil)
            #expect(labels(preview) == ["Kind", "Source", "Copied", "Times copied"], "note \(String(describing: note))")
        }
    }

    // Red if the note row is tied to the tags (shown only with a tag) or the tag rows to the note.
    @Test("OC-3105 W413-P8 a note alone and a tag alone each show only their own row")
    func w413_independentRows() {
        let noteOnly = LibraryPreview(row: row(), content: content(note: "solo"), imageData: nil)
        #expect(labels(noteOnly).suffix(1) == ["Note"])
        #expect(!labels(noteOnly).contains("Tag"))
        let tagOnly = LibraryPreview(row: row(), content: content(tags: [ItemTag(name: "solo", color: .gray)]), imageData: nil)
        #expect(labels(tagOnly).suffix(1) == ["Tag"])
        #expect(!labels(tagOnly).contains("Note"))
    }

    // Red if a text item gains a Pixel size row, or Size shows for a zero-byte item (boundary 0 vs 1).
    @Test("OC-3061 W413-P9 Size is omitted at 0 bytes and shown at 1 byte; Pixel size only with both dimensions")
    func w413_sizeAndPixelBoundaries() {
        #expect(!labels(LibraryPreview(row: row(byteSize: 0), content: content(), imageData: nil)).contains("Size"))
        #expect(labels(LibraryPreview(row: row(byteSize: 1), content: content(), imageData: nil)).contains("Size"))
        #expect(!labels(LibraryPreview(row: row(width: 10, height: nil), content: content(), imageData: nil)).contains("Pixel size"))
        #expect(!labels(LibraryPreview(row: row(width: nil, height: 10), content: content(), imageData: nil)).contains("Pixel size"))
        #expect(labels(LibraryPreview(row: row(width: 10, height: 10), content: content(), imageData: nil)).contains("Pixel size"))
    }

    // Red if a missing first-copied date blanks the row or drops it. The fallback is the copied time.
    @Test("OC-3061 W413-P10 First copied shows only when it differs from Copied; without a stored date it falls back to Copied and is hidden")
    func w413_firstCopiedFallback() {
        let fallback = LibraryPreview(row: row(), content: content(firstCopiedAt: nil), imageData: nil)
        #expect(value(fallback, "First copied") == nil)
        let same = LibraryPreview(row: row(), content: content(firstCopiedAt: copied), imageData: nil)
        #expect(value(same, "First copied") == nil)
        let earlier = LibraryPreview(row: row(), content: content(firstCopiedAt: copied.addingTimeInterval(-86_400)), imageData: nil)
        #expect(value(earlier, "First copied") != nil)
    }

    // Red if Times copied shows the paste count (or the two are swapped), including at the 0 boundary.
    @Test("OC-3061 W413-P11 Times copied and Times pasted are independent numbers")
    func w413_timesCopiedVsPasted() {
        let preview = LibraryPreview(row: row(pasteCount: 0), content: content(copyCount: 5), imageData: nil)
        #expect(value(preview, "Times copied") == "5")
        #expect(value(preview, "Times pasted") == nil)
        let zeroCopies = LibraryPreview(row: row(pasteCount: 2), content: content(copyCount: 0), imageData: nil)
        #expect(value(zeroCopies, "Times copied") == nil)
        let swapped = LibraryPreview(row: row(pasteCount: 9), content: content(copyCount: 1), imageData: nil)
        #expect(value(swapped, "Times copied") == "1")
        #expect(value(swapped, "Times pasted") == "9")
    }

    // MARK: Rich text (FR-003-14: rendered from stored RTF; HTML-only shows plain text)

    private let rtfBytes = Data(#"{\rtf1\ansi {\b bold} word}"#.utf8)

    // Red if rich text ignores the RTF, picks HTML, or the RTF is exposed on a non-rich kind.
    @Test("OC-3058 W413-P12 a rich text item exposes its stored RTF bytes; plain text and other kinds expose none")
    func w413_rtfExposed() {
        let reps = [PasteboardRepresentation(uti: "public.html", data: Data("<b>x</b>".utf8)), PasteboardRepresentation(uti: "public.rtf", data: rtfBytes)]
        let rich = LibraryPreview(row: row(kind: .richText), content: content(kind: .richText, reps: reps), imageData: nil)
        #expect(rich.richTextRTF == rtfBytes)
        // a text item that happens to carry an RTF rep does not render it
        let text = LibraryPreview(row: row(kind: .text), content: content(kind: .text, reps: reps), imageData: nil)
        #expect(text.richTextRTF == nil)
    }

    // Red if HTML is offered for rendering (remote-resource fetch risk) or an empty RTF replaces plain text.
    @Test("OC-3058 W413-P13 rich text with only HTML, or an empty RTF, has no RTF: it shows plain text")
    func w413_htmlOnlyIsPlain() {
        let htmlOnly = [PasteboardRepresentation(uti: "public.html", data: Data("<img src='http://x/y'>".utf8))]
        let preview = LibraryPreview(row: row(kind: .richText), content: content(kind: .richText, text: "plain", reps: htmlOnly), imageData: nil)
        #expect(preview.richTextRTF == nil)
        #expect(preview.text(showingAll: true) == "plain")
        let emptyRTF = [PasteboardRepresentation(uti: "public.rtf", data: Data())]
        let empty = LibraryPreview(row: row(kind: .richText), content: content(kind: .richText, text: "plain", reps: emptyRTF), imageData: nil)
        #expect(empty.richTextRTF == nil)
        let none = LibraryPreview(row: row(kind: .richText), content: content(kind: .richText, text: "plain", reps: []), imageData: nil)
        #expect(none.richTextRTF == nil)
    }

    // MARK: Real database through the model

    private let target = FrontmostApp(bundleId: "com.apple.TextEdit", processId: 4242)

    private func preview(of id: UUID, in lib: RealLibrary) async -> LibraryPreview? {
        await lib.model.open(target: target)
        lib.model.select(id: id)
        lib.model.handle(LibraryKeyStroke(.space, []))
        await lib.model.awaitPreview()
        return lib.model.preview
    }

    // Red if the model builds the preview with a content that lacks tags, count, note or RTF (the ItemContent -> preview wiring).
    @Test("OC-3105 W413-P14 real DB: tags sorted by name with colour, note, copy count and RTF reach the preview; a sibling item stays bare")
    func w413_realDatabase() async throws {
        // given: a rich item copied twice with two tags (created out of order) and a note, and a bare sibling
        let lib = try await RealLibrary.make()
        defer { lib.cleanUp() }
        let reps = [PasteboardRepresentation(uti: "public.rtf", data: rtfBytes)]
        let rich = try await lib.add(.richText, key: "rich", text: "bold word", secondsAgo: 100, representations: reps).itemId
        try await lib.add(.richText, key: "rich", text: "bold word", secondsAgo: 0, representations: reps)
        let sibling = try await lib.add(.text, key: "sib", text: "bare", secondsAgo: 50).itemId
        _ = await lib.database.createTagAndApply(name: "work", color: .blue, to: [rich])
        _ = await lib.database.createTagAndApply(name: "Archive", color: .purple, to: [rich])
        _ = await lib.database.setNote("hero shot", for: rich)
        // when
        let shown = await preview(of: rich, in: lib)
        let bare = await preview(of: sibling, in: lib)
        // then
        let tagRows = shown?.fields.filter { $0.label == "Tag" } ?? []
        #expect(tagRows.map(\.value) == ["Archive", "work"])
        #expect(tagRows.map(\.tagColor) == [.purple, .blue])
        #expect(shown?.fields.last?.label == "Note")
        #expect(shown?.fields.last?.value == "hero shot")
        #expect(shown?.fields.first { $0.label == "Times copied" }?.value == "2")
        #expect(shown?.richTextRTF == rtfBytes)
        // and: the sibling has no tag, no note, no RTF
        #expect(bare?.itemId == sibling)
        #expect(bare?.fields.map(\.label) == ["Kind", "Copied", "Times copied"])
        #expect(bare?.richTextRTF == nil)
    }

    // Red if a colour item's real stored text is not what the swatch reads (e.g. the swatch uses the primary line).
    @Test("OC-3058 W413-P15 real DB: a stored colour #1A2B3C previews with Hex #1A2B3C and RGB 26, 43, 60")
    func w413_realColour() async throws {
        let lib = try await RealLibrary.make()
        defer { lib.cleanUp() }
        let color = try await lib.add(.color, key: "c", text: "#1a2b3c", secondsAgo: 5).itemId
        let shown = await preview(of: color, in: lib)
        #expect(shown?.fields.prefix(3).map(\.label) == ["Kind", "Hex", "RGB"])
        #expect(shown?.fields.dropFirst().first?.value == "#1A2B3C")
        #expect(shown?.fields.dropFirst(2).first?.value == "26, 43, 60")
    }
}
