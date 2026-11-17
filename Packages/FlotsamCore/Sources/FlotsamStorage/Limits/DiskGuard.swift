import FlotsamBase
import Foundation

/// Disk guard (FR-007-14): the two free-space thresholds and the decision they drive. The one home for both numbers,
/// like `IngestLimits` for the ceilings (ADR-0009).
///
/// Why two tiers: images are the large writes, so they stop first (500 MiB) while text and file references, which
/// are tiny and what a user is least willing to lose, keep saving until the volume is nearly full (50 MiB). Below
/// that even a small write risks failing halfway, so everything is refused up front with a clean code instead of
/// a half-written blob and a database error.
enum DiskGuard {
    static let imageSkipBelowBytes: Int64 = 500 * 1024 * 1024
    static let hardFailBelowBytes: Int64 = 50 * 1024 * 1024

    /// Nil lets the ingest continue. `available` is nil when the volume cannot report it: with no number there is
    /// nothing to guard on, and a genuinely full disk still surfaces as `STO-IO-001` / `STO-DB-001` from the write.
    static func check(kind: ItemKind, available: Int64?) -> FlotsamError? {
        guard let available else { return nil }
        if available < hardFailBelowBytes {
            return FlotsamError(.stoIo001, "Disk space too low to save anything", context: [.byteSize: .bytes(Int(available))])
        }
        if available < imageSkipBelowBytes, kind == .image || kind == .screenshot {
            return FlotsamError(.stoLim002, "Disk space low; image not saved", context: [.byteSize: .bytes(Int(available))])
        }
        return nil
    }
}
