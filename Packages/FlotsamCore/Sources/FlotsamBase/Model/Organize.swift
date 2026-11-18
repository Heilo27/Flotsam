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

/// FR-004-01: whether a pin action on items in these states pins them (true) or unpins them (false). With any unpinned
/// item among them the action pins all; only when every one is pinned does it unpin all. The one home of the rule:
/// Storage decides inside its transaction with it, and the Library and the Shelf use it to label and aim the action.
public enum PinRule {
    public static func pinsAll(states: [Bool]) -> Bool { !states.allSatisfy { $0 } }
}

/// FR-004-09, FR-004-10: what Delete asks and where the selection goes afterwards, shared by the Library and the Shelf
/// so the two surfaces cannot disagree.
public enum DeleteConfirmation {
    /// Delete asks first only for more than one item, or any pinned item or one with a trigger or hotkey.
    public static func isRequired(for rows: [ItemRow]) -> Bool {
        rows.count > 1 || rows.contains { $0.isPinned || $0.hasTrigger || $0.hasShortcut }
    }

    /// The confirmation question for `count` items (catalogue keys `ui.organize.confirmDelete*`).
    public static func message(count: Int) -> String {
        if count == 1 { return FlotsamStrings.text(forKey: "ui.organize.confirmDeleteOne") ?? "" }
        return String(format: FlotsamStrings.text(forKey: "ui.organize.confirmDelete") ?? "", count)
    }

    /// The row to select once `ids` are deleted: the first remaining row after the last deleted one in list order, else
    /// the last remaining row before it, else nil (FR-004-09).
    public static func selectionAfter(deleting ids: Set<UUID>, in rows: [ItemRow]) -> UUID? {
        guard let lastDeleted = rows.lastIndex(where: { ids.contains($0.id) }) else { return nil }
        if let after = rows[(lastDeleted + 1)...].first(where: { !ids.contains($0.id) }) { return after.id }
        return rows[..<lastDeleted].last(where: { !ids.contains($0.id) })?.id
    }
}
