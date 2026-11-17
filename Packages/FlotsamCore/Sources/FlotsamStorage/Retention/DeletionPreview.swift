/// How much a pending retention or budget change would delete, so the UI can ask "remove {count} ({size})?" before
/// doing it. The core returns numbers only; the wording lives in the UI layer (FRD-008).
public struct DeletionPreview: Sendable, Equatable {
    public let count: Int
    /// Stored bytes of the affected items' representations (not thumbnails).
    public let bytes: Int64

    /// Nothing would be deleted: per FR-007-09 the caller shows no confirmation and applies the setting directly.
    public static let none = DeletionPreview(count: 0, bytes: 0)
}
