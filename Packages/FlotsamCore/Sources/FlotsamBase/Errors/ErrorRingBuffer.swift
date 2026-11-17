import Foundation

/// One raised error as the diagnostics report sees it: code, severity, time and nothing else (FR-000-13). No
/// context and no underlying cause, so the buffer cannot hold anything FR-000-10 forbids.
public struct RaisedError: Sendable, Equatable {
    public let code: ErrorCode
    public let severity: ErrorSeverity
    public let timestamp: Date

    public init(code: ErrorCode, severity: ErrorSeverity, timestamp: Date) {
        self.code = code
        self.severity = severity
        self.timestamp = timestamp
    }
}

/// The last 100 raised errors, in memory only (FR-000-13).
///
/// Why a value type with no persistence API: the FRD says the buffer is never written to disk and is cleared on
/// quit. A struct owned by `ErrorReporter` has no file handle, no `Codable` conformance and dies with the process,
/// so those two properties hold by construction rather than by discipline.
public struct ErrorRingBuffer: Sendable, Equatable {
    public static let capacity = 100

    private var storage: [RaisedError] = []

    public init() {}

    /// Appends, dropping the oldest entry once `capacity` is reached.
    public mutating func record(_ entry: RaisedError) {
        storage.append(entry)
        if storage.count > Self.capacity { storage.removeFirst(storage.count - Self.capacity) }
    }

    /// Oldest first, so a report reads in the order things happened.
    public var entries: [RaisedError] { storage }
}
