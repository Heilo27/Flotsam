import FlotsamBase
import Foundation

/// `meta.screenshots.lastScanAt` (FRD-002 FR-002-08). Stored in the database, not in settings, so it shares the
/// library's lifetime: a fresh library has no watermark, and Clear History leaves it alone (FR-007-11).
extension FlotsamDatabase {
    /// Nil until the first reconcile scan has run.
    public func screenshotsLastScanAt() async -> FlotsamResult<Date?> {
        do {
            return .success(try await pool.read { db in
                try MetaStore.int64(db, MetaKey.screenshotsLastScanAt).map(Date.init(epochMillis:))
            })
        } catch {
            return .failure(Self.readFailure(error))
        }
    }

    /// Monotone (FR-002-08): the stored watermark becomes the later of itself and `date`, in one SQL statement, so two
    /// writes landing out of submission order cannot move it back and re-open a window already scanned.
    public func setScreenshotsLastScanAt(_ date: Date) async -> FlotsamResult<Void> {
        do {
            try await pool.write { db in try MetaStore.raiseInt64(db, MetaKey.screenshotsLastScanAt, to: date.epochMillis) }
            return .success(())
        } catch {
            return .failure(Self.writeFailure(error))
        }
    }
}
