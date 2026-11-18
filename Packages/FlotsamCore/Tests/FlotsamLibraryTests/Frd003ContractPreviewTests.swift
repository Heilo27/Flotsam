import FlotsamBase
import FlotsamPaste
import FlotsamStorage
import Foundation
import Testing
@testable import FlotsamLibrary

// FRD-003 8T, contract OC-3057, OC-3058, OC-3060, OC-3061, OC-3062, OC-3105 (FR-003-14, the preview pane). Items go
// through the shipping ingest and query layer; the preview is the one the model builds when the user presses Space.
// The expected side is a literal from .claude/oracle/frd-003-contract.json (blind). The view-level halves (280 pt
// width, a rendered swatch or bold run, image fit) need a running app and are not covered here.

@MainActor
@Suite struct Frd003ContractPreviewTests {
    private let target = FrontmostApp(bundleId: "com.apple.TextEdit", processId: 4242)

    private func key(_ input: LibraryKeyInput, _ modifiers: ChordModifiers = []) -> LibraryKeyStroke {
        LibraryKeyStroke(input, modifiers)
    }

    /// Opens the Library, selects `id` and presses Space; returns the preview the model built.
    private func preview(of id: UUID, in lib: RealLibrary) async -> LibraryPreview? {
        await lib.model.open(target: target)
        lib.model.select(id: id)
        lib.model.handle(key(.space))
        await lib.model.awaitPreview()
        return lib.model.preview
    }

    private func labels(_ preview: LibraryPreview?) -> [String] { preview?.fields.map(\.label) ?? [] }
    private func value(_ preview: LibraryPreview?, _ label: String) -> String? { preview?.fields.first { $0.label == label }?.value }

    // OC-3057. Mutation: the limit moves to 19,000 or 30,000, or "Show more" never reveals the rest.
    @Test("OC-3057 a 25,000-character text is cut with Show more; 19,000 characters show in full")
    func oc3057_textLimit() async throws {
        // given: a 25,000-character text and a 19,000-character text
        let lib = try await RealLibrary.make()
        defer { lib.cleanUp() }
        let long = try await lib.add(.text, key: "long", text: String(repeating: "L", count: 25_000), secondsAgo: 10).itemId
        let medium = try await lib.add(.text, key: "medium", text: String(repeating: "M", count: 19_000), secondsAgo: 20).itemId
        // when: preview is opened on each
        let first = await preview(of: long, in: lib)
        let second = await preview(of: medium, in: lib)
        // then: the first is cut and can be expanded, the second is whole with no Show more
        #expect(first?.itemId == long)
        #expect(first?.isTruncated == true)
        #expect(first?.text(showingAll: false)?.count == 20_000)
        #expect(first?.text(showingAll: true)?.count == 25_000)
        #expect(second?.itemId == medium)
        #expect(second?.isTruncated == false)
        #expect(second?.text(showingAll: false)?.count == 19_000)
    }

    // OC-3058 (colour half). Mutation: the colour preview shows only the text, with no hex and no rgb values.
    // The bold-word half is not testable below the view: LibraryPreview carries no rich representation, and
    // App/Flotsam/Library/LibraryPreviewView.swift renders every text as plain monospaced Text.
    @Test("OC-3058 a colour preview shows its hex and the rgb values 26, 43, 60")
    func oc3058_colourPreview() async throws {
        // given: a colour item #1A2B3C
        let lib = try await RealLibrary.make()
        defer { lib.cleanUp() }
        let color = try await lib.add(.color, key: "color", text: "#1A2B3C", secondsAgo: 10).itemId
        // when: preview is opened
        let shown = await preview(of: color, in: lib)
        // then: the pane carries the hex and the three channel values, as text or as fields
        let everything = ([shown?.text(showingAll: true) ?? ""] + (shown?.fields.map(\.value) ?? [])).joined(separator: " | ")
        #expect(everything.contains("#1A2B3C"))
        #expect(everything.contains("26") && everything.contains("43") && everything.contains("60"))
        #expect(shown?.fields.contains { $0.value.contains("26, 43, 60") } == true)
    }

    // OC-3060. Defect D6: the product lists 10 members. Mutation: any limit other than 20.
    @Test("OC-3060 a 25-file bundle previews 20 members then 'and 5 more'")
    func oc3060_bundleMembers() async throws {
        // given: a bundle of 25 files
        let lib = try await RealLibrary.make()
        defer { lib.cleanUp() }
        let members = (1...25).map { IngestMember(path: "/tmp/oc3060/f\($0).txt", bookmark: nil, isDirectory: false) }
        let bundle = try await lib.add(.bundle, key: "bundle25", secondsAgo: 10, members: members).itemId
        // when: preview is opened
        let shown = await preview(of: bundle, in: lib)
        // then: 20 names are listed, and the other 5 are counted
        #expect(shown?.memberPaths.count == 20)
        #expect(shown?.hiddenMemberCount == 5)
        #expect(LibraryText.previewMore(5) == "and 5 more")
    }

    // OC-3061. Mutation: the metadata block drops First copied or Times copied, reorders, or shows Pixel size on text.
    @Test("OC-3061 an image's metadata block lists the eight fields in order; a text item has no Pixel size")
    func oc3061_metadataBlock() async throws {
        // given: an image copied twice (first 1,000 s ago, then again now) from Safari, and a text item
        let lib = try await RealLibrary.make()
        defer { lib.cleanUp() }
        let png = [PasteboardRepresentation(uti: "public.png", data: ContractPNG.make(width: 120, height: 80))]
        let image = try await lib.add(.image, key: "img", source: "Safari", secondsAgo: 1_000, representations: png).itemId
        try await lib.add(.image, key: "img", source: "Safari", secondsAgo: 0, representations: png)
        let text = try await lib.add(.text, key: "txt", text: "plain", source: "Notes", secondsAgo: 5).itemId
        // when: preview is opened on the image, then on the text item
        let imagePreview = await preview(of: image, in: lib)
        let textPreview = await preview(of: text, in: lib)
        // then: the image block names all eight fields in order with values matching the item
        #expect(labels(imagePreview) == ["Kind", "Source", "Copied", "First copied", "Times copied", "Times pasted", "Size", "Pixel size"])
        #expect(value(imagePreview, "Kind") == "Image")
        #expect(value(imagePreview, "Source") == "Safari")
        #expect(value(imagePreview, "Times copied") == "2")
        #expect(value(imagePreview, "Times pasted") == "0")
        #expect(value(imagePreview, "Pixel size")?.replacingOccurrences(of: "×", with: "x") == "120 x 80")
        #expect(value(imagePreview, "First copied") != nil && value(imagePreview, "First copied") != value(imagePreview, "Copied"))
        // and: the text item's block has no Pixel size
        #expect(textPreview?.itemId == text)
        #expect(!labels(textPreview).contains("Pixel size"))
        #expect(labels(textPreview).contains("Kind"))
    }

    // OC-3062 (model half). Mutation: an unmapped character is swallowed by the preview, or opening it moves the selection.
    @Test("OC-3062 with the preview open, 'q' is not taken by the Library and the selection and preview stay put")
    func oc3062_typingGoesToSearch() async throws {
        // given: five items, row 3 selected, preview opened on it
        let lib = try await RealLibrary.make()
        defer { lib.cleanUp() }
        var ids: [UUID] = []
        for n in 1...5 { ids.append(try await lib.add(.text, key: "r\(n)", text: "row \(n) body", secondsAgo: Double(n)).itemId) }
        await lib.model.open(target: target)
        lib.model.select(id: ids[2])
        #expect(lib.model.preview == nil)
        lib.model.handle(key(.space))
        await lib.model.awaitPreview()
        let before = lib.model.preview
        #expect(before?.itemId == ids[2])
        // when: 'q' is typed
        let consumed = lib.model.handle(key(.character("q")))
        await lib.model.awaitPreview()
        // then: the Library did not consume it (the search field gets it), row 3 is still the only selection, the preview is unchanged
        #expect(consumed == false)
        #expect(lib.model.selection == [ids[2]])
        #expect(lib.model.preview == before)
        #expect(lib.model.isPreviewOpen)
    }

    // OC-3105. Mutation: the tag and note rows are missing, or a text item with neither shows empty ones.
    @Test("OC-3105 an image's metadata shows its pixel size, then its tag, then its note; a bare text item shows neither")
    func oc3105_tagAndNoteRows() async throws {
        // given: an image tagged 'work' (blue) with the note 'hero shot', and a text item with no tags and no note
        let lib = try await RealLibrary.make()
        defer { lib.cleanUp() }
        let png = [PasteboardRepresentation(uti: "public.png", data: ContractPNG.make(width: 120, height: 80))]
        let image = try await lib.add(.image, key: "img", source: "Safari", secondsAgo: 10, representations: png).itemId
        let text = try await lib.add(.text, key: "txt", text: "bare", secondsAgo: 20).itemId
        _ = await lib.database.createTagAndApply(name: "work", color: .blue, to: [image])
        _ = await lib.database.setNote("hero shot", for: image)
        // when: preview is opened on each
        let imagePreview = await preview(of: image, in: lib)
        let textPreview = await preview(of: text, in: lib)
        // then: after Pixel size come the tag name, then the note
        let values = imagePreview?.fields.map(\.value) ?? []
        let pixel = imagePreview?.fields.firstIndex { $0.label == "Pixel size" }
        let tag = values.firstIndex { $0.contains("work") }
        let note = values.firstIndex { $0.contains("hero shot") }
        #expect(pixel != nil && tag != nil && note != nil)
        if let pixel, let tag, let note { #expect(pixel < tag && tag < note) }
        // and: the bare text item has no row mentioning a tag or note
        #expect(textPreview?.itemId == text)
        #expect(textPreview?.fields.map(\.label).allSatisfy { !$0.localizedCaseInsensitiveContains("tag") && !$0.localizedCaseInsensitiveContains("note") } == true)
    }
}
