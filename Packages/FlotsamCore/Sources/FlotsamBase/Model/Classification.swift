import Foundation

/// A file or folder held by reference (FR-001-12). Lives in Base so Capture (paste) and Shelf (drop) share one
/// classification result without either importing the other; Storage's `IngestCandidate` maps it (FR-006-12).
public struct ClassifiedMember: Sendable, Equatable {
    public let path: String
    public let bookmark: Data?
    public let isDirectory: Bool

    public init(path: String, bookmark: Data?, isDirectory: Bool) {
        self.path = path
        self.bookmark = bookmark
        self.isDirectory = isDirectory
    }
}

/// What a pasteboard classified as (FR-001-08): everything ingest needs except the source app and the time, which the
/// caller knows and the classifier does not.
public struct Classification: Sendable, Equatable {
    public let kind: ItemKind
    public let contentKey: String
    /// The text of text-like kinds; nil for image, file, folder and bundle.
    public let plainText: String?
    /// Everything that becomes a blob: rich text for text-like kinds, the chosen image for `image`.
    public let representations: [PasteboardRepresentation]
    /// Every member in pasteboard order, never trimmed here: the bundle ceiling and its `CAP-LIM-003` belong to
    /// `IngestLimits` alone (FR-007-06), which is the only layer that sees the true count.
    public let members: [ClassifiedMember]

    public init(
        kind: ItemKind, contentKey: String, plainText: String?,
        representations: [PasteboardRepresentation], members: [ClassifiedMember]
    ) {
        self.kind = kind
        self.contentKey = contentKey
        self.plainText = plainText
        self.representations = representations
        self.members = members
    }
}
