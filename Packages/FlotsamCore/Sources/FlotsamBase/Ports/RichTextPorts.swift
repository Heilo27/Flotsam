import Foundation

/// RTF and HTML to and from `AttributedString`. Foundation has no codec for either (the system one lives in AppKit,
/// which package targets may not import, ADR-0001), so the App provides it and the package depends on the shape only.
///
/// Synchronous and thread-safe: expansion calls it off the main thread.
public protocol RichTextCodec: Sendable {
    /// The attributed text of the best rich representation in `representations` (RTF first, then HTML), or nil when
    /// none can be decoded.
    func decode(_ representations: [PasteboardRepresentation]) -> AttributedString?

    /// The rich representations for `text` (`public.rtf`, `public.html`). The plain-text representation is not the
    /// codec's job. Failure when nothing could be encoded.
    func encode(_ text: AttributedString) -> FlotsamResult<[PasteboardRepresentation]>
}

/// Type identifiers of the rich representations the codec reads and writes.
public enum RichTextTypes {
    public static let rtf = "public.rtf"
    public static let html = "public.html"
    public static let all: Set<String> = [rtf, html]
}
