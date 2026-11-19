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
}
