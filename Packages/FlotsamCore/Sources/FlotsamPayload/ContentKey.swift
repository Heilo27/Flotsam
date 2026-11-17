import CryptoKit
import Foundation

/// The dedupe key `<class>:<SHA-256 hex>` (FR-001-15). The one place a key is built: capture, screenshot pickup and
/// Shelf drops all call here, so two producers of the same bytes always agree.
///
/// Hashed bytes are exactly what was received: no trimming, case folding or Unicode normalisation of text, and the
/// raw image bytes before any conversion. The hash is the system's CryptoKit SHA-256 (truth S5: no hand-rolled
/// cryptography); the key is a dedupe identity, not a security boundary.
public enum ContentKey {
    /// Kinds text, richText, link, color, phone, email: the UTF-8 bytes of the plain text as copied.
    public static func text(_ utf8: Data) -> String { "text:" + hex(of: utf8) }

    /// Kinds image and screenshot: the raw bytes of the chosen representation.
    public static func image(_ bytes: Data) -> String { "image:" + hex(of: bytes) }

    /// Kinds file, folder, bundle: the standardised paths in pasteboard order joined by U+0000.
    public static func files(paths: [String]) -> String {
        "files:" + hex(of: Data(paths.joined(separator: "\u{0}").utf8))
    }

    private static func hex(of data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
