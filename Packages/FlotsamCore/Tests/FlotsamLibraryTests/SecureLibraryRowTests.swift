import FlotsamBase
import FlotsamStorage
import Foundation
import Testing
@testable import FlotsamLibrary

/// FR-003-23: a secure row shows the mask, and a lock plus the Unavailable badge when its key is gone.
@Suite struct SecureLibraryRowTests {
    private func row(unavailable: Bool) -> ItemRow {
        ItemRow(
            id: UUID(), kind: .text, lastCopiedAt: Date(timeIntervalSince1970: 1_000_000), pasteCount: 0,
            primaryLine: unavailable ? "Unavailable" : SecureClip.mask, sourceName: "1Password", tagNames: [],
            isPinned: false, hasTrigger: false, hasShortcut: false, pixelWidth: nil, pixelHeight: nil, memberCount: 0,
            byteSize: 0, isSecure: true, isUnavailable: unavailable)
    }

    @Test func aSecureRowShowsTheMask() {
        let presented = LibraryRowPresentation(row: row(unavailable: false), position: 1, now: Date(timeIntervalSince1970: 1_000_100))
        #expect(presented.isSecure)
        #expect(presented.primaryText == SecureClip.mask)
        #expect(presented.unavailableBadge == nil)
    }

    @Test func anUnavailableSecureRowKeepsTheMaskAndAddsTheBadge() {
        let presented = LibraryRowPresentation(row: row(unavailable: true), position: 1, now: Date(timeIntervalSince1970: 1_000_100))
        #expect(presented.primaryText == SecureClip.mask)
        #expect(presented.unavailableBadge == LibraryText.string("ui.library.secureUnavailable"))
        #expect(presented.unavailableBadge?.isEmpty == false)
    }

    /// FR-003-21 / FR-003-23: VoiceOver never reads the mask (eight "bullet"s) or the kind word for a secure row. It
    /// says "Secure item", then the source app and the age.
    @Test func aSecureRowIsSpokenAsSecureItemNotAsItsMask() {
        let now = Date(timeIntervalSince1970: 1_000_100)
        let label = ItemSpeech.label(for: row(unavailable: false), now: now)
        let secure = FlotsamStrings.text(forKey: "ui.library.spokenSecure") ?? ""
        #expect(!secure.isEmpty)
        #expect(label.hasPrefix(secure + ", "))
        #expect(!label.contains(SecureClip.mask))
        #expect(!label.contains("\u{2022}"))
        #expect(!label.contains(KindLabel.text(for: .text)))
        #expect(label.contains("1Password"))
    }

    @Test func anUnavailableSecureRowIsSpokenWithItsUnavailableWord() {
        let label = ItemSpeech.label(for: row(unavailable: true), now: Date(timeIntervalSince1970: 1_000_100))
        let secure = FlotsamStrings.text(forKey: "ui.library.spokenSecure") ?? ""
        #expect(label.hasPrefix(secure + ", Unavailable, "))
        #expect(!label.contains(SecureClip.mask))
    }
}
