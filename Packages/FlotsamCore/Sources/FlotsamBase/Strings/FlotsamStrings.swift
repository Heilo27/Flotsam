import Foundation

/// The only door to user-facing strings (FR-000-05, ADR-0009). Backed by `Localizable.xcstrings` in this module, so
/// wording, translation and the 140-character budget are checked in one file instead of scattered across views.
public enum FlotsamStrings {
    /// Returns the catalogue text for `key`, or nil when the key is absent.
    ///
    /// Reads the compiled `.strings` table first (what Xcode and recent SwiftPM produce). When that table has no such
    /// key, reads the English value from the raw `Localizable.xcstrings` in the same bundle: SwiftPM before 6.4
    /// copies the catalogue into the bundle without compiling it, so `swift test` on those toolchains would
    /// otherwise see every key as absent. Both paths read the one catalogue file, so no string has a second home.
    public static func text(forKey key: String) -> String? {
        let missingMarker = "\u{0}missing"
        let value = Bundle.module.localizedString(forKey: key, value: missingMarker, table: nil)
        return value == missingMarker ? rawCatalogue[key] : value
    }

    /// English values from the raw catalogue file bundled with this module; empty when the file is not in the bundle
    /// (the compiled table is then the only source) or cannot be read, so a key then reads as absent.
    private static let rawCatalogue: [String: String] = {
        guard let url = Bundle.module.url(forResource: "Localizable", withExtension: "xcstrings") else { return [:] }
        switch FlotsamCatalogue.englishStrings(at: url) {
        case .success(let strings): return strings
        case .failure: return [:]
        }
    }()

    /// User-facing message for an error code, with `arguments` filling the catalogue placeholders in order
    /// (`%lld` for a count, `%@` for a size, duration, permission or app name).
    ///
    /// Falls back to the SYS-INT-001 text (FRD-000 section 8) when the key is missing, when the template has a
    /// specifier other than `%lld`/`%@`, or when the arguments do not match the placeholders in number AND kind.
    /// Why kind matters: `String(format:)` reads a `%@` slot as an object pointer, so an integer there crashes the
    /// process, and a string in a `%lld` slot prints a pointer as a number. A wrong message beats either.
    /// The result is at most 140 characters (FR-000-06): an over-long app name is cut with "…", never the template.
    public static func message(for code: ErrorCode, arguments: [MessageArgument] = []) -> String {
        guard let template = text(forKey: code.catalogueKey),
              let kinds = placeholderKinds(in: template),
              kinds == arguments.map(\.kind)
        else { return fallbackMessage }
        guard !arguments.isEmpty else { return template }

        var nameLimit = arguments.reduce(0) { longest, argument in
            if case .appName(let name) = argument { max(longest, name.count) } else { longest }
        }
        while true {
            let rendered = String(format: template, arguments: arguments.map { $0.formatArgument(appNameLimit: nameLimit) })
            let excess = rendered.count - maxMessageLength
            // Nothing left to cut (no app name, or every name is already just the ellipsis): return as is.
            if excess <= 0 || nameLimit <= 1 { return rendered }
            nameLimit = max(1, nameLimit - excess)
        }
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

    /// The FR-000-06 length budget for one message.
    static let maxMessageLength = 140

    /// The kinds of the format placeholders in a catalogue template, in order; `%%` is a literal percent sign.
    /// Nil when the template uses any specifier other than `%lld` and `%@` (positional, `%d`, `%f`, a trailing `%`),
    /// because none of those can be checked against a `MessageArgument` and so none may reach `String(format:)`.
    static func placeholderKinds(in template: String) -> [MessageArgumentKind]? {
        var kinds: [MessageArgumentKind] = []
        var rest = Substring(template)
        while let percent = rest.firstIndex(of: "%") {
            rest = rest[rest.index(after: percent)...]
            if rest.hasPrefix("%") {
                rest = rest.dropFirst()
            } else if rest.hasPrefix("@") {
                kinds.append(.text)
                rest = rest.dropFirst()
            } else if rest.hasPrefix("lld") {
                kinds.append(.integer)
                rest = rest.dropFirst(3)
            } else {
                return nil
            }
        }
        return kinds
    }

    /// FR-000-05 consistency check, run against any catalogue and code list: for every non-Info code the argument
    /// kinds the code declares (`ErrorCode.messageArgumentKinds`) equal the specifiers of its template, and the
    /// template uses only supported specifiers. Returns one tag per violation (empty means consistent). A code with
    /// no catalogue entry is `CatalogueConsistency`'s concern, not reported here.
    public static func argumentKindViolations(catalogue: [String: String], codes: [ErrorCode]) -> [String] {
        var found: [String] = []
        for code in codes {
            guard let template = catalogue[code.catalogueKey] else { continue }
            if placeholderKinds(in: template) != code.messageArgumentKinds {
                found.append("argumentKinds:\(code.catalogueKey)")
            }
        }
        return found.sorted()
    }
}
