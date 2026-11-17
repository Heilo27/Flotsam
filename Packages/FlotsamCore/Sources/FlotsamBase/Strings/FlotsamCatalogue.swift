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
    public static func shippedURL(file: String = #filePath) -> URL {
        URL(fileURLWithPath: file)
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
    /// copy that strips a translation shows up as a missing key.
    public static func englishStrings(from data: Data) -> FlotsamResult<[String: String]> {
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
            return (english?["stringUnit"] as? [String: Any])?["value"] as? String
        })
    }
}
