/// Ingest limits (FRD-007 FR-007-05). The one home; Payload and Capture read these, never restate them (ADR-0009).
public enum IngestLimits {
    public static let maxTextBytes = 10 * 1024 * 1024
    public static let maxRichRepresentationBytes = 5 * 1024 * 1024
    public static let maxImageBytes = 100 * 1024 * 1024
    public static let maxBundleMembers = 500
    public static let maxNoteCharacters = 2000
}
