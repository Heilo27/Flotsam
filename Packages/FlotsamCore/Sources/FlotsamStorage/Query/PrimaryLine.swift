import FlotsamBase
import Foundation

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
        kind: ItemKind, plainText: String?, pixelWidth: Int?, pixelHeight: Int?, memberCount: Int, memberNames: [String]
    ) -> String {
        // Leading and trailing blank space is dropped first so a copy that starts with a newline does not yield an
        // empty first line.
        let trimmed = (plainText ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        switch kind {
        case .text, .richText:
            let lines = trimmed.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
            return String(lines.prefix(textLineLimit).joined(separator: "\n").prefix(textCharacterLimit))
        case .link, .color, .phone, .email:
            return trimmed
        case .image, .screenshot:
            let label = KindLabel.text(for: kind)
            guard let width = pixelWidth, let height = pixelHeight else { return label }
            return "\(label) \(width) × \(height)"
        case .file, .folder:
            return memberNames.first ?? trimmed
        case .bundle:
            let count = String(format: FlotsamStrings.text(forKey: "ui.row.bundleCount") ?? "%lld items", memberCount)
            let names = memberNames.prefix(bundleNameLimit).joined(separator: ", ")
            return names.isEmpty ? count : "\(count) · \(names)"
        }
    }
}
