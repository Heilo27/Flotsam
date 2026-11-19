/// The bundle member ceiling (FRD-001 FR-001-12, FRD-007 FR-007-06). The one home for the number: Storage re-exposes it
/// as `IngestLimits.maxBundleMembers` and Payload reads it to bound bookmark work, so neither restates it (ADR-0009).
/// It lives in Base because Payload cannot import Storage (ADR-0001).
public enum BundleLimits {
    public static let maxMembers = 500
}
