import Dispatch
import Foundation
import Testing

// Shared pieces of the S2 perf harnesses. These are measurements for the S1 spike, not pass/fail gates: nothing here
// asserts a speed. Each harness gates itself on `FLOTSAM_PERF=1` (see bin/perf.sh), so a plain `swift test` skips them.

/// True only when the run was started with `FLOTSAM_PERF=1`.
let perfEnabled = ProcessInfo.processInfo.environment["FLOTSAM_PERF"] == "1"

/// Monotonic nanoseconds.
func nowNs() -> UInt64 { DispatchTime.now().uptimeNanoseconds }

func milliseconds(from start: UInt64, to end: UInt64) -> Double { Double(end &- start) / 1_000_000 }

/// Nearest-rank percentile (the same definition Unmapped007TimingTests uses for its p95). `fraction` is 0.5 or 0.95.
func percentile(_ samples: [Double], _ fraction: Double) -> Double {
    precondition(!samples.isEmpty, "no samples")
    let sorted = samples.sorted()
    return sorted[max(1, Int((Double(sorted.count) * fraction).rounded(.up))) - 1]
}

func mean(_ samples: [Double]) -> Double { samples.reduce(0, +) / Double(samples.count) }

func fixed(_ value: Double) -> String { String(format: "%.2f", value) }

/// The one parseable result line a harness prints: `PERF <name> key=value ...`. `build` records the configuration
/// the numbers came from, so a debug figure is never read as a release one.
func printPerfLine(_ name: String, _ fields: [(String, String)]) {
    #if DEBUG
    let build = "debug"
    #else
    let build = "release"
    #endif
    let body = (fields + [("build", build)]).map { "\($0.0)=\($0.1)" }.joined(separator: " ")
    print("PERF \(name) \(body)")
}

/// A small deterministic generator, so two runs measure the same data and the same copy spacing.
struct SplitMix64: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
