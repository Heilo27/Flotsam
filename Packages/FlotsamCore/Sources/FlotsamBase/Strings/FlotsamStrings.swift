import Foundation

/// The only door to user-facing strings (FR-000-05, ADR-0009). Backed by `Localizable.xcstrings` in this module, so
/// wording, translation and the 140-character budget are checked in one file instead of scattered across views.
public enum FlotsamStrings {
    /// Returns the catalogue text for `key`, or nil when the key is absent.
    public static func text(forKey key: String) -> String? {
        let missingMarker = "\u{0}missing"
        let value = Bundle.module.localizedString(forKey: key, value: missingMarker, table: nil)
        return value == missingMarker ? nil : value
    }

    /// User-facing message for an error code, with `arguments` filling the catalogue placeholders in order
    /// (`%lld` for a count, `%@` for a size, duration, permission or app name).
    ///
    /// Falls back to the SYS-INT-001 text (FRD-000 section 8) when the key is missing or when the number of
    /// arguments does not match the placeholders. The mismatch case matters: `String(format:)` with too few
    /// arguments reads garbage, and a wrong message is better than a crash or a corrupted one.
    public static func message(for code: ErrorCode, arguments: [MessageArgument] = []) -> String {
        guard let template = text(forKey: code.catalogueKey),
              placeholderCount(in: template) == arguments.count
        else { return fallbackMessage }
        guard !arguments.isEmpty else { return template }
        return String(format: template, arguments: arguments.map(\.formatArgument))
    }

    /// User-facing message for a raised error. Placeholder values come from the error's safe context: `count`
    /// then `limitBytes`, in that order, when present (FR-000-06). Callers never pass free text.
    public static func message(for error: FlotsamError) -> String {
        var arguments: [MessageArgument] = []
        if case .int(let count)? = error.context[.count] { arguments.append(.count(count)) }
        if case .bytes(let limit)? = error.context[.limitBytes] { arguments.append(.byteSize(limit)) }
        return message(for: error.code, arguments: arguments)
    }

    private static var fallbackMessage: String {
        text(forKey: ErrorCode.sysInt001.catalogueKey) ?? ""
    }

    /// Number of format placeholders in a catalogue template; `%%` is a literal percent sign, not a placeholder.
    static func placeholderCount(in template: String) -> Int {
        var count = 0
        var iterator = template.makeIterator()
        while let character = iterator.next() {
            guard character == "%" else { continue }
            if iterator.next() != "%" { count += 1 }
        }
        return count
    }
}
