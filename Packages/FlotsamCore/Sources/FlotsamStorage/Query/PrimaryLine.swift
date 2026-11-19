import FlotsamBase
import Foundation

/// "The first N lines, at most M characters" of a text (FR-003-07 for Library rows with 2 and 140, FR-006-07 for Shelf
/// cards with 3 and 120). One home for the cut so the two surfaces cannot disagree about where a line or a character
/// budget ends. The caller trims surrounding whitespace first.
public enum TextExcerpt {
    public static func make(_ text: String, lineLimit: Int, characterLimit: Int) -> String {
        let lines = text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
        return String(lines.prefix(lineLimit).joined(separator: "\n").prefix(characterLimit))
    }
}

/// The primary line of a Library row (FRD-003 FR-003-07), as plain text. One home: rows display it and the
/// alphabetical sort orders by it (FRD-004 FR-004-12 says "the primary line text defined in FR-003-07"), so the sort
/// can never disagree with what the user reads.
enum PrimaryLine {
    /// "first 2 lines, at most 140 characters" (FR-003-07).
    static let textCharacterLimit = 140
    static let textLineLimit = 2
    /// Members named in a bundle's primary line ("the first two names").
    static let bundleNameLimit = 2

    static func text(
        kind: ItemKind, plainText: String?, pixelWidth: Int?, pixelHeight: Int?, memberCount: Int, memberNames: [String],
        bundleName: String? = nil
    ) -> String {
        // Leading and trailing blank space is dropped first so a copy that starts with a newline does not yield an
        // empty first line.
        let trimmed = (plainText ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        switch kind {
        case .text, .richText:
            return TextExcerpt.make(trimmed, lineLimit: textLineLimit, characterLimit: textCharacterLimit)
        case .link, .color, .phone, .email:
            return trimmed
        case .image, .screenshot:
            let label = KindLabel.text(for: kind)
            guard let width = pixelWidth, let height = pixelHeight else { return label }
            return "\(label) \(width) × \(height)"
        case .file, .folder:
            return memberNames.first ?? trimmed
        case .bundle:
            let count = FlotsamStrings.formatted(forKey: "ui.row.bundleCount", [memberCount]) ?? String(memberCount)
            // A bundle the user named shows that name in place of its first member names (FR-004-15).
            let names = bundleName ?? memberNames.prefix(bundleNameLimit).joined(separator: ", ")
            return names.isEmpty ? count : "\(count) · \(names)"
        }
    }
}
