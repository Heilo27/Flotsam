extension ItemKind {
    /// Kinds whose content is text (FR-005-09, FR-003-15). "Plain text only" paste, trigger eligibility and template
    /// variables (FR-005-17) all ask this one question; none of them restates the list.
    public var isTextBearing: Bool {
        switch self {
        case .text, .richText, .link, .color, .phone, .email: true
        case .image, .file, .folder, .bundle, .screenshot: false
        }
    }
}
