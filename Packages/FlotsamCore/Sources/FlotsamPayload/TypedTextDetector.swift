import FlotsamBase
import Foundation

/// Typed-text detection (FR-001-09): is this plain text a link, email, colour or phone number?
///
/// Content only, never the network or the source app's claim (FRD-001 §5). The whole trimmed string must match;
/// partial matches never count.
public enum TypedTextDetector {
    /// `urlText` is the string form of `public.url` when the pasteboard carries one.
    /// Returns nil for ordinary text.
    public static func detect(_ plain: String, urlText: String? = nil) -> ItemKind? {
        let trimmed = plain.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.contains(where: \.isNewline) else { return nil }
        if isLink(trimmed, urlText: urlText) { return .link }
        if isEmail(trimmed) { return .email }
        if isColor(trimmed) { return .color }
        if isPhone(trimmed) { return .phone }
        return nil
    }

    private static func isLink(_ text: String, urlText: String?) -> Bool {
        if let urlText, urlText == text { return true }
        guard !text.contains(where: \.isWhitespace), let url = URL(string: text),
              let scheme = url.scheme?.lowercased(), ["http", "https", "ftp", "ftps"].contains(scheme),
              let host = url.host(percentEncoded: false), !host.isEmpty
        else { return false }
        return true
    }

    private static func isEmail(_ text: String) -> Bool {
        text.count <= 254 && text.wholeMatch(of: /[^\s@]+@[^\s@]+\.[^\s@]{2,}/) != nil
    }

    /// The notation rule lives in one place, `ColorChannels` (FR-003-14); this only classifies by it.
    private static func isColor(_ text: String) -> Bool {
        ColorChannels.isNotation(text)
    }

    private static func isPhone(_ text: String) -> Bool {
        let separators: Set<Character> = ["(", ")", "-", ".", " "]
        var digits = 0
        var hasSeparator = false
        for (index, character) in text.enumerated() {
            if character.isASCII, character.isNumber {
                digits += 1
            } else if character == "+" {
                guard index == 0 else { return false }
            } else if separators.contains(character) {
                hasSeparator = true
            } else {
                return false
            }
        }
        guard (7...15).contains(digits) else { return false }
        return hasSeparator || text.hasPrefix("+") || digits >= 10
    }
}
