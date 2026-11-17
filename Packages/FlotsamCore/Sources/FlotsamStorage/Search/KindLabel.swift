import FlotsamBase

/// The user-facing name of an item kind. One home: the search index (FR-003-09 searches "kind label") and the
/// Library sidebar and rows read it here, so typing "image" finds exactly the items the UI calls images.
public enum KindLabel {
    public static func text(for kind: ItemKind) -> String {
        FlotsamStrings.text(forKey: "ui.kind.\(kind.rawValue)") ?? kind.rawValue
    }
}
