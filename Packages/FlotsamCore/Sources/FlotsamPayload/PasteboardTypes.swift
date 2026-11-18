import FlotsamBase
import Foundation

/// The pasteboard types capture honours (FR-001-05) and how it picks what to read.
///
/// Everything not listed here is ignored (FR-001-06): file promises, `com.apple.cocoa.pasteboard.color`,
/// `com.adobe.pdf`, `public.url-name`, `com.apple.finder.node`, `com.apple.icns`, `dyn.*` and app-private types.
/// There is deliberately no list of ignored types, so a new unknown type is ignored by default.
public enum PasteboardTypes {
    public static let plainText = PasteboardUTI.plainText
    public static let rtf = PasteboardUTI.rtf
    public static let html = PasteboardUTI.html
    public static let png = "public.png"
    public static let tiff = "public.tiff"
    public static let jpeg = "public.jpeg"
    public static let fileURL = PasteboardUTI.fileURL
    public static let url = "public.url"

    private static let honoured: Set<String> = [plainText, rtf, html, png, tiff, jpeg, fileURL, url]

    /// FR-001-04 gate 5: does the pasteboard offer anything worth reading?
    public static func hasHonoured(in types: [String]) -> Bool {
        types.contains(where: honoured.contains)
    }

    /// The types whose bytes are read once every gate has passed. File URLs win outright (FR-001-08 discards every
    /// other representation of a file copy), and only the best image is read: PNG, then TIFF, then JPEG (FR-001-11).
    public static func typesToRead(from types: [String]) -> [String] {
        let present = Set(types)
        if present.contains(fileURL) { return [fileURL] }
        var wanted = [plainText, rtf, html, url].filter(present.contains)
        if let image = imagePriority.first(where: present.contains) { wanted.append(image) }
        return wanted
    }

    /// Accepted image representations, best first (FR-001-11).
    public static let imagePriority = [png, tiff, jpeg]

    /// The file URL a `public.file-url` representation names: its data is the URL string as UTF-8, `file:///...`.
    /// The one parse, shared by the classifier (clipboard capture) and the Shelf drop's readability check.
    public static func fileURL(from data: Data) -> URL? {
        let string = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: string), url.isFileURL else { return nil }
        return url
    }
}
