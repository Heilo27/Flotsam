import FlotsamBase
import Foundation

/// The one entry behind "Import recent screenshots" (FRD-002 FR-002-12 / FRD-008 FR-008-04), for onboarding and
/// Settings. It owns what the button does before the library exists:
/// - a press before the watcher is wired is held, and runs once when `ready(run:)` arrives;
/// - if the library fails to open instead, the held press and every later one show that failure, never "Imported 0"
///   (the library is not empty, it is unavailable);
/// - a press with the watcher ready shows "Importing…" at once, then whatever `run` reports when it ends.
@MainActor
public final class ImportRecentCoordinator {
    /// One import run; reports its own end result through `hud` (the watcher's `importRecentAnnouncing`).
    public typealias Run = @Sendable (_ hud: @escaping @MainActor @Sendable (String) -> Void) async -> Void

    private enum State {
        case opening(pressed: Bool)
        case ready(Run)
        case unavailable(FlotsamError)
    }

    private var state = State.opening(pressed: false)
    private let hud: @MainActor @Sendable (String) -> Void

    public init(hud: @escaping @MainActor @Sendable (String) -> Void) { self.hud = hud }

    /// The button.
    public func request() {
        switch state {
        case .opening: state = .opening(pressed: true)
        case .ready(let run): start(run)
        case .unavailable(let error): hud(FlotsamStrings.message(for: error))
        }
    }

    /// The watcher is wired; a press held until now runs.
    public func ready(run: @escaping Run) {
        let held: Bool
        if case .opening(let pressed) = state { held = pressed } else { held = false }
        state = .ready(run)
        if held { start(run) }
    }

    /// The library failed to open; a press held until now shows why nothing can be imported.
    public func unavailable(_ error: FlotsamError) {
        let held: Bool
        if case .opening(let pressed) = state { held = pressed } else { held = false }
        state = .unavailable(error)
        if held { hud(FlotsamStrings.message(for: error)) }
    }

    private func start(_ run: @escaping Run) {
        let hud = hud
        hud(ScreenshotImportHUD.importingMessage)
        Task { await run(hud) }
    }
}
