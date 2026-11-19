// Shared by symlink with FlotsamLibraryTests (SwiftPM test targets cannot depend on each other), the way
// `LoadNormalized.swift` is. Edit only this file.

/// Wall-clock figures in a debug build share the machine with the rest of the suite, so one scheduler stall can push a
/// single run over a bound the code meets. The metric is the best of up to three independent runs, stopping at the
/// first that is inside the bound: noise passes on a retry, while code that is genuinely over the bound is over it on
/// every run (each kill-check below makes the work slower than the bound on every run).
///
/// Runs on the caller's actor (`isolation`), so a `@MainActor` test can keep its rig and `#expect`s inside `run`.
func bestOfThree(
    under bound: Double, isolation: isolated (any Actor)? = #isolation, _ run: () async throws -> Double
) async rethrows -> Double {
    var best = Double.infinity
    for _ in 1...3 {
        best = min(best, try await run())
        if best < bound { break }
    }
    return best
}
