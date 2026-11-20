import FlotsamBase
import FlotsamStorage
import Foundation

/// The preview pane's content for one item (FR-003-14): read-only, nothing fetched from the network.
public struct LibraryPreview: Equatable, Sendable {
    /// Text beyond this many characters is behind "Show more" (FR-003-14).
    public static let textLimit = 20_000
    /// File and folder members listed before "and n more".
    public static let memberLimit = 20

    public struct Field: Equatable, Identifiable, Sendable {
        /// Where the view puts the field in the compact metadata block (FR-003-14): `summary` fields (kind, source, copied)
        /// share one or two lines, `tag` fields are chips, every other field is a short label and value line.
        public enum Placement: Sendable, Equatable { case summary, detail, tag }

        public let label: String
        public let value: String
        /// Set on a tag row: the colour of its dot.
        public let tagColor: TagColor?
        public let placement: Placement
        public var id: String { label + "\u{0}" + value }

        init(label: String, value: String, tagColor: TagColor? = nil, placement: Placement = .detail) {
            self.label = label
            self.value = value
            self.tagColor = tagColor
            self.placement = placement
        }
    }

    public let itemId: UUID
    public let kind: ItemKind
    private let fullText: String?
    public let imageData: Data?
    public let memberPaths: [String]
    public let hiddenMemberCount: Int
    public let fields: [Field]
    /// The swatch of a colour item written in a notation `ColorChannels` reads; nil otherwise (then only its text shows).
    public let color: ColorChannels?
    /// The stored RTF of a rich text item, for the view to render with its formatting (FR-003-14); nil for every other
    /// kind, and for a rich text item with no RTF (HTML only: importing it could fetch remote resources, so it shows as
    /// plain text, never over the network).
    public let richTextRTF: Data?

    public var isTruncated: Bool { (fullText?.count ?? 0) > Self.textLimit }

    /// Whether the text reads as code or any other text whose indentation matters: more than one line, and at least one
    /// line indented by a tab or two spaces. Such text is drawn monospaced with its indentation kept and soft-wrapped
    /// under a hanging indent (`CodeWrap`, FR-003-14); prose wraps too, without the indent.
    public var textIsIndented: Bool {
        guard let fullText else { return false }
        let lines = fullText.split(separator: "\n", omittingEmptySubsequences: false)
        return lines.count > 1 && lines.contains { $0.hasPrefix("\t") || $0.hasPrefix("  ") }
    }

    /// The text to show: the first `textLimit` characters, or all of it once the user chose "Show more".
    public func text(showingAll: Bool) -> String? {
        guard let fullText else { return nil }
        return showingAll || !isTruncated ? fullText : String(fullText.prefix(Self.textLimit))
    }

    public init(row: ItemRow, content: ItemContent, imageData: Data?) {
        itemId = row.id
        kind = row.kind
        // A secure item previews as its mask (or "Unavailable"), never its text: that stays behind authentication.
        fullText = row.isSecure ? row.primaryLine : content.plainText
        self.imageData = imageData
        let paths = content.members.map(\.path)
        memberPaths = Array(paths.prefix(Self.memberLimit))
        hiddenMemberCount = max(0, paths.count - Self.memberLimit)
        color = row.kind == .color ? ColorChannels(text: content.plainText) : nil
        richTextRTF = row.kind == .richText ? content.representations.first { $0.uti == PasteboardUTI.rtf && !$0.data.isEmpty }?.data : nil
        fields = Self.fields(for: row, content: content, color: color)
    }

    private static func dateTime(_ date: Date) -> String { date.formatted(date: .abbreviated, time: .shortened) }

    /// The metadata block (FR-003-14), in order: kind, source app, copied, first copied (only when it differs from copied),
    /// times copied (only above one) and times pasted (only above zero), size, pixel size, then each tag, then the note. A colour's hex and rgb follow its kind.
    private static func fields(for row: ItemRow, content: ItemContent, color: ColorChannels?) -> [Field] {
        func field(_ key: String, _ value: String, _ placement: Field.Placement = .detail) -> Field {
            Field(label: LibraryText.string(key), value: value, placement: placement)
        }
        var fields = [field("ui.library.previewKind", KindLabel.text(for: row.kind), .summary)]
        if let color {
            fields.append(field("ui.library.previewHex", color.hex))
            fields.append(field("ui.library.previewRGB", color.channels))
        }
        if let source = row.sourceName, !source.isEmpty { fields.append(field("ui.library.previewSource", source, .summary)) }
        let copied = dateTime(row.lastCopiedAt)
        fields.append(field("ui.library.previewCopied", copied, .summary))
        // First copied and the counters appear only when they add something: the same time as Copied, or a count of
        // zero, is noise (an item pasted never has "Times pasted 0").
        let firstCopied = dateTime(content.firstCopiedAt ?? row.lastCopiedAt)
        if firstCopied != copied { fields.append(field("ui.library.previewFirstCopied", firstCopied)) }
        if content.copyCount > 1 { fields.append(field("ui.library.previewTimesCopied", content.copyCount.formatted())) }
        if row.pasteCount > 0 { fields.append(field("ui.library.previewTimesPasted", row.pasteCount.formatted())) }
        if row.byteSize > 0 {
            fields.append(field("ui.library.previewSize", ByteCountFormatter.string(fromByteCount: row.byteSize, countStyle: .file)))
        }
        if let width = row.pixelWidth, let height = row.pixelHeight {
            fields.append(field("ui.library.previewPixelSize", "\(width) × \(height)"))
        }
        for tag in content.tags {
            fields.append(Field(label: LibraryText.string("ui.library.previewTag"), value: tag.name, tagColor: tag.color, placement: .tag))
        }
        if let note = content.note, !note.isEmpty { fields.append(field("ui.library.previewNote", note)) }
        return fields
    }
}

/// The soft wrap of code in the preview (FR-003-14, hill-climb r6): a line that is wider than the pane wraps, and its
/// continuation lines indent to the line's own leading whitespace plus one step, so the indentation stays readable. The
/// columns are decided here (testable, no AppKit); the view turns them into points with the font's advance.
public enum CodeWrap {
    /// A tab counts as this many columns when measuring a line's leading whitespace.
    public static let tabColumns = 4
    /// The extra indent a continuation line takes beyond its line's own leading whitespace.
    public static let continuationStep = 2

    /// The width of `line`'s leading spaces and tabs, in columns.
    public static func leadingColumns(of line: some StringProtocol) -> Int {
        var columns = 0
        for character in line {
            if character == " " { columns += 1 } else if character == "\t" { columns += tabColumns } else { break }
        }
        return columns
    }

    /// Where the continuation lines of `line` start: its leading whitespace plus one step.
    public static func continuationColumns(of line: some StringProtocol) -> Int {
        leadingColumns(of: line) + continuationStep
    }
}
