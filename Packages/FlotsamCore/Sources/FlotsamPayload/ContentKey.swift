import Foundation

/// The dedupe key `<class>:<SHA-256 hex>` (FR-001-15). The one place a key is built: capture, screenshot pickup and
/// Shelf drops all call here, so two producers of the same bytes always agree.
///
/// Hashed bytes are exactly what was received: no trimming, case folding or Unicode normalisation of text, and the
/// raw image bytes before any conversion.
public enum ContentKey {
    /// Kinds text, richText, link, color, phone, email: the UTF-8 bytes of the plain text as copied.
    public static func text(_ utf8: Data) -> String { "text:" + SHA256.hex(of: utf8) }

    /// Kinds image and screenshot: the raw bytes of the chosen representation.
    public static func image(_ bytes: Data) -> String { "image:" + SHA256.hex(of: bytes) }

    /// Kinds file, folder, bundle: the standardised paths in pasteboard order joined by U+0000.
    public static func files(paths: [String]) -> String {
        "files:" + SHA256.hex(of: Data(paths.joined(separator: "\u{0}").utf8))
    }
}
