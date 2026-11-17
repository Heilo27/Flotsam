import os

/// Performance signposts (FR-000-12, FR-007-16). One shared signposter under the `perf` category.
/// Names are fixed literals and carry no content, so a signpost can never leak clip data (anti-truth A4).
/// Lives in Base so feature modules that may not import `os` can still measure.
public enum FlotsamSignpost {
    public static let captureCategory = "perf"
    private static let signposter = OSSignposter(subsystem: FlotsamLog.fallbackSubsystem, category: captureCategory)

    /// Runs `work` inside a named interval. `name` must be a literal at the call site.
    public static func measure<T>(_ name: StaticString, _ work: () throws -> T) rethrows -> T {
        let state = signposter.beginInterval(name)
        defer { signposter.endInterval(name, state) }
        return try work()
    }

    /// Async form for the actor-hosted paths (ingest, sweep).
    public static func measure<T: Sendable>(_ name: StaticString, _ work: () async throws -> T) async rethrows -> T {
        let state = signposter.beginInterval(name)
        defer { signposter.endInterval(name, state) }
        return try await work()
    }

    /// A point-in-time event inside an open interval (for example one batch inside `retention.sweep`).
    public static func event(_ name: StaticString) {
        signposter.emitEvent(name)
    }
}
