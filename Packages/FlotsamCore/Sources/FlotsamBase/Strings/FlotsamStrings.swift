import Foundation

/// The only door to user-facing strings (FR-000-05, ADR-0009). Backed by `Localizable.xcstrings` in this module.
public enum FlotsamStrings {
    /// Returns the catalogue text for `key`, or nil when the key is absent.
    public static func text(forKey key: String) -> String? {
        let missingMarker = "\u{0}missing"
        let value = Bundle.module.localizedString(forKey: key, value: missingMarker, table: nil)
        return value == missingMarker ? nil : value
    }

    /// User-facing message for an error code. A missing key falls back to the SYS-INT-001 text (FRD-000 section 8).
    public static func message(for code: ErrorCode) -> String {
        text(forKey: code.catalogueKey)
            ?? text(forKey: ErrorCode.sysInt001.catalogueKey)
            ?? ""
    }
}
