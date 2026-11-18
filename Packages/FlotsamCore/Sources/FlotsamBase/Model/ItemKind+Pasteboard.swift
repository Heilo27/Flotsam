extension ItemKind {
    /// Kinds whose content is text: a paste or a drag writes the plain text first, then the stored representations
    /// (FR-003-15, FR-006-10). Same set as `isTextEditable` today but a different rule: if editing ever widens, this
    /// must not follow it, so the two stay apart.
    public var isTextBearing: Bool {
        switch self {
        case .text, .richText, .link, .color, .phone, .email: true
        case .image, .file, .folder, .bundle, .screenshot: false
        }
    }

    /// Kinds that refer to files on disk: a paste or a drag writes one file URL per member that still exists.
    public var isFileBacked: Bool {
        switch self {
        case .file, .folder, .bundle: true
        case .text, .richText, .link, .color, .phone, .email, .image, .screenshot: false
        }
    }

    /// Kinds that are a picture: a paste writes the stored image data, a drag offers the image itself (FR-006-10).
    public var isImage: Bool {
        switch self {
        case .image, .screenshot: true
        case .text, .richText, .link, .color, .phone, .email, .file, .folder, .bundle: false
        }
    }
}
