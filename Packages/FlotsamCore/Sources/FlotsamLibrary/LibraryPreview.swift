import FlotsamBase
import FlotsamStorage
import Foundation

/// The preview pane's content for one item (FR-003-14): read-only, nothing fetched from the network.
public struct LibraryPreview: Equatable {
    /// Text beyond this many characters is behind "Show more" (FR-003-14).
    public static let textLimit = 20_000
    /// File and folder members listed before "and n more".
    public static let memberLimit = 10

    public struct Field: Equatable {
        public let label: String
        public let value: String
    }

    public let itemId: UUID
    public let kind: ItemKind
    private let fullText: String?
    public let imageData: Data?
    public let memberPaths: [String]
    public let hiddenMemberCount: Int
    public let fields: [Field]

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
        fields = Self.fields(for: row)
    }

    private static func fields(for row: ItemRow) -> [Field] {
        func field(_ key: String, _ value: String) -> Field { Field(label: LibraryText.string(key), value: value) }
        var fields = [field("ui.library.previewKind", KindLabel.text(for: row.kind))]
        if let source = row.sourceName, !source.isEmpty { fields.append(field("ui.library.previewSource", source)) }
        fields.append(field("ui.library.previewCopied", row.lastCopiedAt.formatted(date: .abbreviated, time: .shortened)))
        fields.append(field("ui.library.previewTimesPasted", row.pasteCount.formatted()))
        if row.byteSize > 0 {
            fields.append(field("ui.library.previewSize", ByteCountFormatter.string(fromByteCount: row.byteSize, countStyle: .file)))
        }
        if let width = row.pixelWidth, let height = row.pixelHeight {
            fields.append(field("ui.library.previewPixelSize", "\(width) × \(height)"))
        }
        return fields
    }
}
