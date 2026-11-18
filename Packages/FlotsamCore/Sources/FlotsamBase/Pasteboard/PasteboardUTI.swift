/// The two pasteboard type identifiers that more than one module writes or reads. One home, so a type rename is one edit
/// (Payload's capture list, Paste's write, the Shelf's drag and the diagnostics copy all point here).
public enum PasteboardUTI {
    public static let plainText = "public.utf8-plain-text"
    public static let fileURL = "public.file-url"
}
