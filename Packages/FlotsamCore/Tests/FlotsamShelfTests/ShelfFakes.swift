import Foundation
import FlotsamBase

/// A joined row for Shelf tests. Ids are derived from `n`, so a test names a card by its number.
func makeShelfRow(
    _ n: Int = 0, kind: ItemKind = .text, primary: String? = nil, source: String? = "Notes", tags: [String] = [],
    pinned: Bool = false, memberCount: Int = 0, missing: Bool = false, copiedAt: Date = Date(timeIntervalSince1970: 1_000_000)
) -> ItemRow {
    ItemRow(
        id: UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", n)) ?? UUID(), kind: kind,
        lastCopiedAt: copiedAt, pasteCount: 0, primaryLine: primary ?? "item \(n)", sourceName: source, tagNames: tags,
        isPinned: pinned, hasTrigger: false, hasShortcut: false, pixelWidth: nil, pixelHeight: nil,
        memberCount: memberCount, byteSize: 0, isMissing: missing)
}
