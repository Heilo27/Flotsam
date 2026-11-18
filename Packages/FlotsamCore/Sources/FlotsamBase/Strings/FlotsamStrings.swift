import Foundation

/// The only door to user-facing strings (FR-000-05, ADR-0009). Backed by `Localizable.xcstrings` in this module, so
/// wording, translation and the 140-character budget are checked in one file instead of scattered across views.
public enum FlotsamStrings {
    /// Returns the catalogue template for `key`, or nil when the key is absent. Fill it with `formatted(forKey:_:)`
    /// (or a typed wrapper such as `SettingsString.text(_:)`), never a bare `String(format:)`, so a plural key resolves
    /// to its `one` or `other` form for the count.
    ///
    /// Reads the compiled `.strings`/`.stringsdict` tables first (what Xcode and recent SwiftPM produce). When they have
    /// no such key, reads the English entry from the raw `Localizable.xcstrings` in the same bundle: SwiftPM before 6.4
    /// copies the catalogue into the bundle without compiling it, so `swift test` on those toolchains would
    /// otherwise see every key as absent. Both paths read the one catalogue file, so no string has a second home.
    /// A plural key on the raw path comes back with its `other` form filled in, never the raw `%#@name@` slot.
    public static func text(forKey key: String) -> String? {
        if let compiled = compiledText(forKey: key) { return compiled }
        guard let entry = rawCatalogue[key] else { return nil }
        return resolvingPlurals(in: entry, arguments: [])
    }

    /// The catalogue text for `key` with `arguments` filled in, a plural slot resolved by its count (FR-000-05): "1 item",
    /// "2 items". Nil when the key is absent. The caller passes the arguments the template declares; the typed wrappers
    /// check that (`formatKinds`). The one place a catalogue template reaches `String(format:)` for the Library, the
    /// Settings window and the row text.
    public static func formatted(forKey key: String, _ arguments: [CVarArg]) -> String? {
        if let compiled = compiledText(forKey: key) { return String(format: compiled, arguments: arguments) }
        guard let entry = rawCatalogue[key] else { return nil }
        return String(format: resolvingPlurals(in: entry, arguments: arguments), arguments: arguments)
    }

    private static func compiledText(forKey key: String) -> String? {
        let missingMarker = "\u{0}missing"
        let value = Bundle.module.localizedString(forKey: key, value: missingMarker, table: nil)
        return value == missingMarker ? nil : value
    }

    /// Raw-catalogue entries (base template and plural variations) from the file bundled with this module; empty when
    /// the file is not in the bundle (the compiled tables are then the only source) or cannot be read, so a key then
    /// reads as absent.
    private static let rawCatalogue: [String: FlotsamCatalogue.Entry] = {
        guard let url = Bundle.module.url(forResource: "Localizable", withExtension: "xcstrings") else { return [:] }
        switch FlotsamCatalogue.englishEntries(at: url) {
        case .success(let entries): return entries
        case .failure: return [:]
        }
    }()

    /// The entry's base template with each `%#@name@` slot replaced by the `one` form when its count argument is exactly
    /// 1 and the `other` form otherwise, `%arg` becoming a positional `%N$lld`. A slot whose count argument is missing
    /// or not an integer takes `other`; a slot naming no substitution is dropped. Either way no `%#@` reaches the
    /// reader (the raw-catalogue path has no stringsdict to resolve it).
    static func resolvingPlurals(in entry: FlotsamCatalogue.Entry, arguments: [CVarArg]) -> String {
        var result = ""
        var rest = Substring(entry.base)
        while let start = rest.range(of: "%#@") {
            result += rest[..<start.lowerBound]
            let afterMarker = rest[start.upperBound...]
            guard let close = afterMarker.firstIndex(of: "@") else { return result }
            let name = String(afterMarker[..<close])
            rest = afterMarker[afterMarker.index(after: close)...]
            guard let substitution = entry.substitutions[name] else { continue }
            let index = substitution.argNum - 1
            let count = arguments.indices.contains(index) ? arguments[index] as? Int : nil
            let form = count == 1 ? substitution.one : substitution.other
            result += form.replacingOccurrences(of: "%arg", with: "%\(substitution.argNum)$lld")
        }
        return result + rest
    }

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

    /// User-facing message for a raised error. Placeholder values come from the error's safe context, chosen by what
    /// the code's template declares (`ErrorCode.messageArgumentKinds`, FR-000-06): an integer slot takes `count`, a
    /// text slot takes `limitBytes` (the one context key carrying a ceiling, rendered by `MessageArgument.formatBytes`).
    /// Context a template has no slot for (a `count` on a code whose text states its own number, an `itemId`) is
    /// log-only and never reaches the arity check. A declared slot with no value supplied still falls back to
    /// SYS-INT-001. Callers never pass free text.
    public static func message(for error: FlotsamError) -> String {
        var arguments: [MessageArgument] = []
        for kind in error.code.messageArgumentKinds {
            switch (kind, error.context[.count], error.context[.limitBytes]) {
            case (.integer, .int(let count)?, _): arguments.append(.count(count))
            case (.text, _, .bytes(let limit)?): arguments.append(.byteSize(limit))
            default: break
            }
        }
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

    /// The kinds of the arguments a catalogue template takes, by argument position, for templates that may use plural
    /// slots (`%#@items@` and `%2$#@items@`, each an integer) and positional specifiers (`%2$@`, `%1$lld`) besides
    /// plain `%@` and `%lld`. Nil when any other specifier appears, a position repeats, or a position is skipped.
    /// Error messages keep the stricter `placeholderKinds`; this is what the typed Settings wrappers check an argument
    /// list against before `String(format:)` (a `%@` slot handed an integer would crash).
    static func formatKinds(in template: String) -> [MessageArgumentKind]? {
        var kindAt: [Int: MessageArgumentKind] = [:]
        var nextPlain = 0
        var rest = Substring(template)
        while let percent = rest.firstIndex(of: "%") {
            rest = rest[rest.index(after: percent)...]
            if rest.hasPrefix("%") {
                rest = rest.dropFirst()
                continue
            }
            var position: Int?
            let digits = rest.prefix { $0.isASCII && $0.isNumber }
            if !digits.isEmpty, rest.dropFirst(digits.count).hasPrefix("$") {
                position = Int(digits)
                rest = rest.dropFirst(digits.count + 1)
            }
            let kind: MessageArgumentKind
            if rest.hasPrefix("#@") {
                guard let close = rest.dropFirst(2).firstIndex(of: "@") else { return nil }
                kind = .integer
                rest = rest[rest.index(after: close)...]
            } else if rest.hasPrefix("@") {
                kind = .text
                rest = rest.dropFirst()
            } else if rest.hasPrefix("lld") {
                kind = .integer
                rest = rest.dropFirst(3)
            } else {
                return nil
            }
            let index: Int
            if let position {
                guard position >= 1 else { return nil }
                index = position - 1
            } else {
                index = nextPlain
                nextPlain += 1
            }
            guard kindAt[index] == nil else { return nil }
            kindAt[index] = kind
        }
        let ordered = (0..<kindAt.count).compactMap { kindAt[$0] }
        return ordered.count == kindAt.count ? ordered : nil
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
