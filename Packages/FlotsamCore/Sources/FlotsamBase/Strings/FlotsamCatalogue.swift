import Foundation

/// Reads the English text out of a `Localizable.xcstrings` file as `key -> value` (FR-000-05, FR-000-07).
///
/// Why this is a seam and not a private detail of the consistency test: the check "every code has a message, every
/// message is at most 140 characters, every `error.` key has a code" is only proven if it can be fed a catalogue with
/// one key removed, one message too long, one orphan key. Test seam for FR-000-07 / OC-0021: the reader takes the
/// file (or its bytes) as a parameter, defaulting to the shipped file. One parser, so the test and any future tool
/// read the format the same way (Rule 9).
public enum FlotsamCatalogue {
    /// The catalogue in the source tree, located relative to this file. `swift test` and a source checkout have it;
    /// a built app does not, because SwiftPM compiles the catalogue into `.strings` files, so the app reads text
    /// through `FlotsamStrings`, never through this reader.
    ///
    /// Why `file` is optional and `#filePath` is spelled inside the body: a `#filePath` default argument is expanded
    /// in the CALLER's file, so any caller outside `Strings/` (tests, other modules, the `englishStrings(at:)`
    /// default) resolved to the wrong directory. Resolving `#filePath` in the body anchors the default to this
    /// production source file for every caller. `file` stays as an override for a caller that must point at a
    /// different anchor file.
    public static func shippedURL(file: String? = nil) -> URL {
        URL(fileURLWithPath: file ?? #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Resources/Localizable.xcstrings")
    }

    /// English values from the file at `url`, which defaults to the shipped catalogue.
    public static func englishStrings(at url: URL = shippedURL()) -> FlotsamResult<[String: String]> {
        do {
            return englishStrings(from: try Data(contentsOf: url))
        } catch {
            return .failure(FlotsamError(.sysInt001, "catalogue file unreadable", underlying: UnderlyingErrorInfo(error)))
        }
    }

    /// English values from catalogue JSON bytes. A key with no English `stringUnit` value is left out, so a mutated
    /// copy that strips a translation shows up as a missing key. A plural key's value is its base template
    /// (`"Delete %#@items@ now"`); `englishEntries` carries the variations that fill the `%#@items@` slot.
    public static func englishStrings(from data: Data) -> FlotsamResult<[String: String]> {
        englishEntries(from: data).map { $0.mapValues(\.base) }
    }

    /// One English entry: the base template and the plural substitutions its `%#@name@` slots refer to.
    public struct Entry: Sendable, Equatable {
        public let base: String
        public let substitutions: [String: PluralSubstitution]
    }

    /// The English plural variations of one `%#@name@` slot (FR-000-05): `one` is used for a count of exactly 1,
    /// `other` for every other count. `argNum` is the 1-based position of the count among the format arguments. Each
    /// form holds `%arg` where the count goes. English has no other plural categories, so no others are read.
    public struct PluralSubstitution: Sendable, Equatable {
        public let argNum: Int
        public let one: String
        public let other: String
    }

    /// Entries (base template plus plural substitutions) from the file at `url`, which defaults to the shipped catalogue.
    public static func englishEntries(at url: URL = shippedURL()) -> FlotsamResult<[String: Entry]> {
        do {
            return englishEntries(from: try Data(contentsOf: url))
        } catch {
            return .failure(FlotsamError(.sysInt001, "catalogue file unreadable", underlying: UnderlyingErrorInfo(error)))
        }
    }

    /// Entries from catalogue JSON bytes: the one parser behind `englishStrings` and the plural-aware readers. A
    /// substitution missing its `one` or `other` form is left out, so the lint over `%#@name@` slots reports it.
    public static func englishEntries(from data: Data) -> FlotsamResult<[String: Entry]> {
        let json: Any
        do {
            json = try JSONSerialization.jsonObject(with: data)
        } catch {
            return .failure(FlotsamError(.sysInt001, "catalogue is not JSON", underlying: UnderlyingErrorInfo(error)))
        }
        guard let root = json as? [String: Any], let entries = root["strings"] as? [String: [String: Any]] else {
            return .failure(FlotsamError(.sysInt001, "catalogue has no strings table"))
        }
        return .success(entries.compactMapValues { entry in
            let english = (entry["localizations"] as? [String: Any])?["en"] as? [String: Any]
            guard let base = (english?["stringUnit"] as? [String: Any])?["value"] as? String else { return nil }
            let raw = english?["substitutions"] as? [String: [String: Any]] ?? [:]
            return Entry(base: base, substitutions: raw.compactMapValues(pluralSubstitution))
        })
    }

    private static func pluralSubstitution(_ raw: [String: Any]) -> PluralSubstitution? {
        let forms = (raw["variations"] as? [String: Any])?["plural"] as? [String: [String: Any]]
        func form(_ name: String) -> String? { (forms?[name]?["stringUnit"] as? [String: Any])?["value"] as? String }
        guard let argNum = raw["argNum"] as? Int, let one = form("one"), let other = form("other") else { return nil }
        return PluralSubstitution(argNum: argNum, one: one, other: other)
    }
}
