import Foundation

/// The closed set of tag colours (FRD-004 FR-004-02). The values are names only; the actual colours belong to the
/// design system, so Base carries no RGB.
public enum TagColor: String, Sendable, Equatable, CaseIterable {
    case red, orange, yellow, green, blue, purple, pink, gray

    /// A new tag, and a stored tag whose colour is missing or unknown, is gray.
    public static let `default`: TagColor = .gray

    /// Reads a stored colour name; anything else is the default, so an old or damaged row still renders.
    public init(stored: String?) {
        self = stored.flatMap(TagColor.init(rawValue:)) ?? .default
    }
}

extension ItemKind {
    /// FR-004-07: the kinds whose plain text can be edited.
    public var isTextEditable: Bool {
        switch self {
        case .text, .richText, .link, .color, .phone, .email: true
        case .image, .file, .folder, .bundle, .screenshot: false
        }
    }
}

/// The kind and dedupe key of an item whose content Organize produced (an edited text, a member split out of a bundle).
public struct ItemClassification: Sendable, Equatable {
    public let kind: ItemKind
    public let contentKey: String

    public init(kind: ItemKind, contentKey: String) {
        self.kind = kind
        self.contentKey = contentKey
    }
}

/// Re-detection and key building for Organize (FR-004-07, FR-004-11), handed in by the composition root.
///
/// Why closures: kind detection and `ContentKey` live in Payload (FR-001-09, FR-001-15), which Storage and Library may
/// not import (ADR-0001). Injecting them means Organize reuses the capture rules instead of restating them.
public struct ItemClassifiers: Sendable {
    /// Kind and key of text saved from the editor (no rich representations remain).
    public let editedText: @Sendable (String) -> ItemClassification
    /// Kind and key of one bundle member split out by Ungroup: path and whether it is a directory.
    public let fileMember: @Sendable (String, Bool) -> ItemClassification

    public init(
        editedText: @escaping @Sendable (String) -> ItemClassification,
        fileMember: @escaping @Sendable (String, Bool) -> ItemClassification
    ) {
        self.editedText = editedText
        self.fileMember = fileMember
    }
}
