import Foundation
import Testing
import FlotsamBase
import FlotsamStorage
@testable import FlotsamPaste

/// A codec that keeps the attributed string in a side table keyed by the bytes it hands out, so a test can see what the
/// expander decoded and what it asked to encode.
final class FakeRichTextCodec: RichTextCodec, @unchecked Sendable {
    private let lock = NSLock()
    private var _encoded: [AttributedString] = []
    var decoded: AttributedString?
    var encodeFailure: FlotsamError?

    var encoded: [AttributedString] { lock.withLock { _encoded } }

    func decode(_ representations: [PasteboardRepresentation]) -> AttributedString? { decoded }
    func encode(_ text: AttributedString) -> FlotsamResult<[PasteboardRepresentation]> {
        if let encodeFailure { return .failure(encodeFailure) }
        lock.withLock { _encoded.append(text) }
        let bytes = Data(String(text.characters).utf8)
        return .success([
            PasteboardRepresentation(uti: RichTextTypes.rtf, data: bytes),
            PasteboardRepresentation(uti: RichTextTypes.html, data: bytes),
        ])
    }
}

/// FR-005-18 / AC-005-17, and the item-level half of FR-005-17.
@Suite struct TemplatedPayloadTests {
    private let itemId = UUID()
    private var context: TemplateContext {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? .gmt
        let now = calendar.date(from: DateComponents(year: 2026, month: 11, day: 16, hour: 14, minute: 5)) ?? .now
        return TemplateContext(now: now, calendar: calendar, locale: Locale(identifier: "en_US"), clipboardText: "CLIP")
    }

    private func content(_ kind: ItemKind, _ text: String?, representations: [PasteboardRepresentation] = []) -> ItemContent {
        ItemContent(kind: kind, plainText: text, representations: representations, members: [])
    }

    private func build(_ content: ItemContent, codec: FakeRichTextCodec = FakeRichTextCodec()) -> FlotsamResult<[PasteboardRepresentation]> {
        TemplatedPayload.representations(
            for: content, itemId: itemId, context: context, codec: codec, files: FakeFiles(existing: []))
    }

    private func text(_ reps: [PasteboardRepresentation], _ uti: String) -> String? {
        reps.first { $0.uti == uti }.flatMap { String(data: $0.data, encoding: .utf8) }
    }

    @Test func plainTextItemWritesExpandedPlainTextOnly() throws {
        let reps = try build(content(.text, "Hi {clipboard} on {date:yyyy}", representations: [
            PasteboardRepresentation(uti: "public.url", data: Data("x".utf8))])).get()
        #expect(reps.map(\.uti) == [PastePayload.plainTextType])
        #expect(text(reps, PastePayload.plainTextType) == "Hi CLIP on 2026")
    }

    @Test func itemsWithoutVariablesKeepEveryStoredRepresentation() throws {
        let stored = [PasteboardRepresentation(uti: "public.url", data: Data("https://a.test".utf8))]
        let reps = try build(content(.link, "https://a.test {foo}", representations: stored)).get()
        #expect(reps.map(\.uti) == [PastePayload.plainTextType, "public.url"])
        #expect(text(reps, PastePayload.plainTextType) == "https://a.test {foo}")
    }

    @Test func nonTextKindsAreNeverExpanded() throws {
        let image = [PasteboardRepresentation(uti: "public.png", data: Data("{date}".utf8))]
        let reps = try build(content(.image, "{date}", representations: image)).get()
        #expect(reps == image)
    }

    @Test func richTextIsExpandedInPlaceAndReencodedAlongsidePlainText() throws {
        var attributed = AttributedString("See ")
        var link = AttributedString("docs {date:yyyy}")
        link.link = URL(string: "https://example.com")
        attributed.append(link)
        attributed.append(AttributedString(" now"))
        var bold = AttributedString("!")
        bold.inlinePresentationIntent = .stronglyEmphasized
        attributed.append(bold)

        let codec = FakeRichTextCodec()
        codec.decoded = attributed
        let stored = [PasteboardRepresentation(uti: RichTextTypes.rtf, data: Data("old".utf8))]
        let reps = try build(content(.richText, "See docs {date:yyyy} now!", representations: stored), codec: codec).get()

        #expect(reps.map(\.uti) == [PastePayload.plainTextType, RichTextTypes.rtf, RichTextTypes.html])
        #expect(text(reps, PastePayload.plainTextType) == "See docs 2026 now!")
        #expect(text(reps, RichTextTypes.rtf) == "See docs 2026 now!")

        let result = try #require(codec.encoded.first)
        let linked = result.runs.filter { $0.link != nil }
        #expect(linked.count == 1)
        #expect(linked.first.map { String(result[$0.range].characters) } == "docs 2026")
        #expect(result.runs.contains { $0.inlinePresentationIntent == .stronglyEmphasized })
    }

    @Test func aVariableThatFillsAWholeLinkStaysInsideTheLink() {
        var link = AttributedString("{clipboard}")
        link.link = URL(string: "https://example.com")
        let result = TemplateVariables.expand(AttributedString("a ") + link + AttributedString(" z"), context: context)
        #expect(String(result.characters) == "a CLIP z")
        #expect(result.runs.filter { $0.link != nil }.map { String(result[$0.range].characters) } == ["CLIP"])
    }

    @Test func anEmptyValueRemovesTheVariableAndNothingElse() {
        var empty = context
        empty.clipboardText = ""
        let result = TemplateVariables.expand(AttributedString("a{clipboard}b"), context: empty)
        #expect(String(result.characters) == "ab")
    }

    @Test func richTextThatCannotBeDecodedFailsBeforeAnythingIsWritten() {
        let stored = [PasteboardRepresentation(uti: RichTextTypes.rtf, data: Data("old".utf8))]
        let result = build(content(.richText, "{date}", representations: stored))
        guard case .failure(let error) = result else { Issue.record("expected failure"); return }
        #expect(error.code == .trgOs002)
    }

    @Test func anEncodeFailureIsReturned() {
        let codec = FakeRichTextCodec()
        codec.decoded = AttributedString("{date}")
        codec.encodeFailure = FlotsamError(.trgOs002, "encode")
        let stored = [PasteboardRepresentation(uti: RichTextTypes.rtf, data: Data("old".utf8))]
        guard case .failure(let error) = build(content(.richText, "{date}", representations: stored), codec: codec)
        else { Issue.record("expected failure"); return }
        #expect(error.code == .trgOs002)
    }

    @Test func richTextWithOnlyPlainTextExpandsThePlainText() throws {
        let reps = try build(content(.richText, "{clipboard}")).get()
        #expect(reps.map(\.uti) == [PastePayload.plainTextType])
    }
}
