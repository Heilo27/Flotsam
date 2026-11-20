import FlotsamBase
import FlotsamStorage
import Foundation

/// What a card does for VoiceOver (FR-006-19): Paste, Copy and Pin or Unpin. A drag has no equivalent action, so there
/// is no Drag case: a card's drag-out is reached by Paste instead.
public enum ShelfCardAction: Sendable, Equatable, CaseIterable {
    case paste, copy, togglePin
}

/// A Shelf card, already decided (FR-006-07, FR-006-19). Pure: the same row, text and clock give the same card, so it
/// is tested without a view.
public struct ShelfCardPresentation: Equatable, Identifiable, Sendable {
    /// The main picture of the card. The view maps each case to a thumbnail, a system file icon, a swatch or the kind
    /// icon; none of the cases carries a note or tag (FR-006-07).
    public enum Visual: Sendable, Equatable {
        case thumbnail
        case fileIcon
        /// Several files: the stacked icon with the member count.
        case stackedIcon(memberCount: Int)
        case swatch
        case kindIcon(ItemKind)
        /// A secure clip (FR-006-21): the lock, with the mask as its text.
        case secure
    }

    public let id: UUID
    public let kind: ItemKind
    public let visual: Visual
    /// The text on the card: the first three lines (at most 120 characters) of a text-bearing item, the colour value
    /// of a colour, the file name of a file or folder; nil for pictures and bundles.
    public let text: String?
    public let isPinned: Bool
    /// "Missing" badge for a file, folder or bundle item none of whose members exist (FR-006-07, FR-003-07).
    public let isMissing: Bool
    /// A secure clip: `text` is the fixed mask, never the stored text, which a card cannot read anyway.
    public let isSecure: Bool
    /// "Unavailable" badge for a secure card whose Keychain key cannot be read (FR-006-07); nil otherwise.
    public let unavailableBadge: String?
    /// The source app's name; the view draws its small icon. Nil when the source is unknown.
    public let sourceName: String?
    /// The source app's bundle identifier, from which the view looks up the icon; nil when unknown.
    public let sourceBundleId: String?
    /// The card's age for the header ("2 min ago", "Yesterday", a date after 7 days): the Library's wording, from the
    /// one helper that also words the VoiceOver label, so the two read alike and age together (FR-006-48).
    public let age: String
    public let accessibilityLabel: String
    public let accessibilityActions: [ShelfCardAction]

    /// - Parameters:
    ///   - text: the item's stored plain text, for the kinds that show text. Nil falls back to the row's primary line
    ///     (already cut to two lines), so a card never renders empty when the text could not be read.
    ///   - isMissing: whether none of the item's file members exist, decided by the model from the members port.
    public init(row: ItemRow, text: String? = nil, isMissing: Bool = false, now: Date) {
        id = row.id
        kind = row.kind
        isPinned = row.isPinned
        self.isMissing = isMissing
        isSecure = row.isSecure
        unavailableBadge = row.isSecure && row.isUnavailable ? ShelfText.string(ShelfText.secureUnavailable) : nil
        sourceName = row.sourceName
        sourceBundleId = row.sourceBundleId
        age = ItemSpeech.relativeTime(row.lastCopiedAt, now: now)
        accessibilityLabel = ItemSpeech.label(for: row, now: now)
        accessibilityActions = ShelfCardAction.allCases

        if row.isSecure {
            visual = .secure
            self.text = SecureClip.mask
            return
        }
        switch row.kind {
        case .image, .screenshot:
            visual = .thumbnail
            self.text = nil
        case .file, .folder:
            visual = .fileIcon
            self.text = row.primaryLine
        case .bundle:
            visual = .stackedIcon(memberCount: row.memberCount)
            self.text = nil
        case .color:
            visual = .swatch
            self.text = row.primaryLine
        case .text, .richText, .link, .phone, .email:
            visual = .kindIcon(row.kind)
            let source = (text ?? row.primaryLine).trimmingCharacters(in: .whitespacesAndNewlines)
            self.text = TextExcerpt.make(
                source, lineLimit: ShelfLayout.cardTextLineLimit, characterLimit: ShelfLayout.cardTextCharacterLimit)
        }
    }

    /// The VoiceOver action's name, in the card's current state: "Pin" on an unpinned card, "Unpin" on a pinned one.
    public func title(of action: ShelfCardAction) -> String {
        switch action {
        case .paste: ShelfText.string(ShelfText.menuPaste)
        case .copy: ShelfText.string(ShelfText.menuCopy)
        case .togglePin: ShelfText.string(isPinned ? ShelfText.menuUnpin : ShelfText.menuPin)
        }
    }
}
