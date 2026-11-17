import FlotsamBase
import FlotsamStorage
import Foundation

/// What a variable reads at expansion time (FR-005-17): the clock and the plain text on the pasteboard at step 3.
public struct TemplateContext: Sendable {
    public var now: Date
    /// Carries the time zone; values are evaluated "in the current calendar and time zone".
    public var calendar: Calendar
    public var locale: Locale
    /// Plain text of the pasteboard at expansion step 3. Empty when there is none or the read was blocked.
    public var clipboardText: String

    public init(now: Date, calendar: Calendar, locale: Locale, clipboardText: String) {
        self.now = now
        self.calendar = calendar
        self.locale = locale
        self.clipboardText = clipboardText
    }
}

/// Template variables, FR-005-17: the single definition. Triggers and item hotkeys call this; Library paste, Copy,
/// previews and Shelf drags never do, because they give the stored text literally.
///
/// One left-to-right pass finds every `{name}` / `{name:format}` and substitutes it, so an inserted value (a clipboard
/// that itself holds `{date}`) is never scanned again.
public enum TemplateVariables {
    /// Longest `{...}` body the scanner will look at. A bound for the scan, well above the 32-character format limit.
    private static let maximumBody = 64

    // MARK: Public surface

    /// The text with every known variable substituted and `{{known}}` unescaped, limited to the text ceiling.
    public static func expand(_ text: String, context: TemplateContext) -> String {
        let characters = Array(text)
        var output = ""
        var cursor = 0
        for span in scan(characters) {
            guard let replacement = replacement(for: span.kind, context: context) else { continue }
            output.append(String(characters[cursor..<span.range.lowerBound]))
            output.append(replacement)
            cursor = span.range.upperBound
        }
        output.append(String(characters[cursor...]))
        return limitedToTextCeiling(output)
    }

    /// True when `expand` would change the text. Lets callers skip the work (and, for rich text, the codec round trip).
    public static func hasSubstitutions(in text: String) -> Bool {
        scan(Array(text)).contains { span in
            if case .unknown = span.kind { return false }
            return true
        }
    }

    /// Save-time check: `TRG-VAL-005` when the text holds a name or format that is not a variable. It is a warning;
    /// the caller saves anyway and shows the notice. Only the count goes into the error (never the text itself).
    public static func validate(_ text: String) -> FlotsamResult<Void> {
        let unknown = scan(Array(text)).filter { span in
            if case .unknown = span.kind { return true }
            return false
        }
        guard unknown.isEmpty else {
            return .failure(FlotsamError(
                .trgVal005, "Text holds a variable the expander does not know", context: [.count: .int(unknown.count)]))
        }
        return .success(())
    }

    // MARK: Scanning (shared with the attributed-string path)

    enum Variable: Equatable {
        case date(format: String?)
        case time(format: String?)
        case clipboard
    }

    enum SpanKind: Equatable {
        case variable(Variable)
        /// `{{known}}`: pastes `{known}`.
        case escaped(String)
        /// Looks like a variable but is not one. Left as typed.
        case unknown
    }

    struct Span {
        /// Offsets into the `Character` array that was scanned.
        let range: Range<Int>
        let kind: SpanKind
    }

    /// Candidate `{name}` or `{name:format}` starting at `start`. `end` is the offset after the closing brace.
    private struct Candidate {
        let name: String
        let format: String?
        let body: String
        let end: Int
    }

    static func scan(_ characters: [Character]) -> [Span] {
        var spans: [Span] = []
        var index = 0
        while index < characters.count {
            guard characters[index] == "{" else { index += 1; continue }
            if index + 1 < characters.count, characters[index + 1] == "{" {
                // Doubled brace: `{{known}}` is the escape, any other `{{...}}` is somebody else's template syntax
                // (Go, Jinja) and is left alone without a warning.
                if let inner = candidate(at: index + 1, in: characters), inner.end < characters.count,
                    characters[inner.end] == "}"
                {
                    if variable(for: inner) != nil {
                        spans.append(Span(range: index..<(inner.end + 1), kind: .escaped("{" + inner.body + "}")))
                    }
                    index = inner.end + 1
                } else {
                    // A stray extra "{" ahead of a real variable: it stays literal, the inner brace is read next.
                    index += 1
                }
                continue
            }
            if let found = candidate(at: index, in: characters) {
                let kind = variable(for: found).map(SpanKind.variable) ?? .unknown
                spans.append(Span(range: index..<found.end, kind: kind))
                index = found.end
            } else {
                index += 1
            }
        }
        return spans
    }

    private static func candidate(at start: Int, in characters: [Character]) -> Candidate? {
        var cursor = start + 1
        let nameStart = cursor
        while cursor < characters.count, isNameCharacter(characters[cursor], first: cursor == nameStart) { cursor += 1 }
        guard cursor > nameStart, cursor < characters.count else { return nil }
        let name = String(characters[nameStart..<cursor])
        var format: String?
        if characters[cursor] == ":" {
            let formatStart = cursor + 1
            cursor = formatStart
            while cursor < characters.count, cursor - start <= maximumBody,
                !"{}\n\r".contains(characters[cursor]) { cursor += 1 }
            format = String(characters[formatStart..<cursor])
        }
        guard cursor < characters.count, characters[cursor] == "}" else { return nil }
        return Candidate(name: name, format: format, body: String(characters[(start + 1)..<cursor]), end: cursor + 1)
    }

    private static func isNameCharacter(_ character: Character, first: Bool) -> Bool {
        guard character.isASCII else { return false }
        return character.isLetter || (!first && (character.isNumber || character == "_"))
    }

    private static func variable(for candidate: Candidate) -> Variable? {
        switch candidate.name {
        case "date":
            guard let format = candidate.format else { return .date(format: nil) }
            return isValidFormat(format) ? .date(format: format) : nil
        case "time":
            guard let format = candidate.format else { return .time(format: nil) }
            return isValidFormat(format) ? .time(format: format) : nil
        case "clipboard":
            return candidate.format == nil ? .clipboard : nil
        default:
            return nil
        }
    }

    /// 1 to 32 characters of ASCII letters, digits, space and `- / : , . '` (FR-005-17).
    private static func isValidFormat(_ format: String) -> Bool {
        let bytes = Array(format.utf8)
        guard (1...32).contains(bytes.count) else { return false }
        return bytes.allSatisfy { byte in
            (0x30...0x39).contains(byte) || (0x41...0x5A).contains(byte) || (0x61...0x7A).contains(byte)
                || " -/:,.'".utf8.contains(byte)
        }
    }

    // MARK: Values

    /// The text a span becomes, or nil when the span is left as typed.
    static func replacement(for kind: SpanKind, context: TemplateContext) -> String? {
        switch kind {
        case .unknown: nil
        case .escaped(let literal): literal
        case .variable(.clipboard): context.clipboardText
        case .variable(.date(let format)): formatted(context, format: format, dateStyle: .medium, timeStyle: .none)
        case .variable(.time(let format)): formatted(context, format: format, dateStyle: .none, timeStyle: .short)
        }
    }

    private static func formatted(
        _ context: TemplateContext, format: String?, dateStyle: DateFormatter.Style, timeStyle: DateFormatter.Style
    ) -> String {
        let formatter = DateFormatter()
        formatter.calendar = context.calendar
        formatter.timeZone = context.calendar.timeZone
        formatter.locale = context.locale
        if let format {
            formatter.dateFormat = format
        } else {
            formatter.dateStyle = dateStyle
            formatter.timeStyle = timeStyle
        }
        return formatter.string(from: context.now)
    }

    // MARK: Ceiling

    /// FR-005-17: "limited to the text ceiling (FRD-007 FR-007-06); beyond it the expansion is truncated at the limit".
    /// Cuts on a character boundary so the result is still valid text.
    static func limitedToTextCeiling(_ text: String) -> String {
        guard let count = characterCountWithinTextCeiling(of: text) else { return text }
        return String(text.prefix(count))
    }

    /// Nil when the text already fits; otherwise how many leading characters do.
    static func characterCountWithinTextCeiling(of text: String) -> Int? {
        let limit = IngestLimits.maxTextBytes
        guard text.utf8.count > limit else { return nil }
        var bytes = 0
        var count = 0
        for character in text {
            bytes += character.utf8.count
            if bytes > limit { break }
            count += 1
        }
        return count
    }
}
