import Foundation

/// Times are INTEGER UTC milliseconds in the database (FR-007-03). These two are the only conversions, so a rounding
/// rule cannot differ between the writer, the sweep and the query layer.
extension Date {
    var epochMillis: Int64 { Int64((timeIntervalSince1970 * 1000).rounded()) }

    init(epochMillis: Int64) { self.init(timeIntervalSince1970: Double(epochMillis) / 1000) }
}
