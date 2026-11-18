import FlotsamBase
import FlotsamStorage
import Foundation

/// The preview pane's content for one item (FR-003-14): read-only, nothing fetched from the network.
public struct LibraryPreview: Equatable {
    /// Text beyond this many characters is behind "Show more" (FR-003-14).
    public static let textLimit = 20_000
    /// File and folder members listed before "and n more".
    public static let memberLimit = 20

    public struct Field: Equatable, Identifiable {
        public let label: String
        public let value: String
        /// Set on a tag row: the colour of its dot.
        public let tagColor: TagColor?
        public var id: String { label + "\u{0}" + value }

        init(label: String, value: String, tagColor: TagColor? = nil) {
            self.label = label
            self.value = value
            self.tagColor = tagColor
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

    /// The text to show: the first `textLimit` characters, or all of it once the user chose "Show more".
    public func text(showingAll: Bool) -> String? {
        guard let fullText else { return nil }
        return showingAll || !isTruncated ? fullText : String(fullText.prefix(Self.textLimit))
    }

    public init(row: ItemRow, content: ItemContent, imageData: Data?) {
        itemId = row.id
        kind = row.kind
        fullText = content.plainText
        self.imageData = imageData
        let paths = content.members.map(\.path)
        memberPaths = Array(paths.prefix(Self.memberLimit))
        hiddenMemberCount = max(0, paths.count - Self.memberLimit)
        color = row.kind == .color ? ColorChannels(text: content.plainText) : nil
        richTextRTF = row.kind == .richText ? content.representations.first { $0.uti == PasteboardUTI.rtf && !$0.data.isEmpty }?.data : nil
        fields = Self.fields(for: row, content: content, color: color)
    }

    private static func dateTime(_ date: Date) -> String { date.formatted(date: .abbreviated, time: .shortened) }

    /// The metadata block (FR-003-14), in order: kind, source app, copied, first copied, times copied, times pasted, size,
    /// pixel size, then each tag, then the note. A colour's hex and rgb follow its kind.
    private static func fields(for row: ItemRow, content: ItemContent, color: ColorChannels?) -> [Field] {
        func field(_ key: String, _ value: String) -> Field { Field(label: LibraryText.string(key), value: value) }
        var fields = [field("ui.library.previewKind", KindLabel.text(for: row.kind))]
        if let color {
            fields.append(field("ui.library.previewHex", color.hex))
            fields.append(field("ui.library.previewRGB", color.channels))
        }
        if let source = row.sourceName, !source.isEmpty { fields.append(field("ui.library.previewSource", source)) }
        fields.append(field("ui.library.previewCopied", dateTime(row.lastCopiedAt)))
        fields.append(field("ui.library.previewFirstCopied", dateTime(content.firstCopiedAt ?? row.lastCopiedAt)))
        fields.append(field("ui.library.previewTimesCopied", content.copyCount.formatted()))
        fields.append(field("ui.library.previewTimesPasted", row.pasteCount.formatted()))
        if row.byteSize > 0 {
            fields.append(field("ui.library.previewSize", ByteCountFormatter.string(fromByteCount: row.byteSize, countStyle: .file)))
        }
        if let width = row.pixelWidth, let height = row.pixelHeight {
            fields.append(field("ui.library.previewPixelSize", "\(width) × \(height)"))
        }
        for tag in content.tags {
            fields.append(Field(label: LibraryText.string("ui.library.previewTag"), value: tag.name, tagColor: tag.color))
        }
        if let note = content.note, !note.isEmpty { fields.append(field("ui.library.previewNote", note)) }
        return fields
    }
}
