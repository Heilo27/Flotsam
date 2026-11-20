import Foundation

/// The one home of "free what only a visible panel needs once the last panel is gone" (S5 truth, FR-003-13, FR-006-07).
///
/// The Library and the Shelf share one thumbnail cache, so neither may empty it while the other is still showing. Each
/// panel reports `opened` when it starts to show and `closed` when it is really gone (hidden and no longer drawing);
/// when `closed` leaves no panel open, `release` runs once. Event-driven only: no timer, nothing runs while idle.
@MainActor
public final class PanelResidency {
    public enum Panel: Sendable, Hashable {
        case library, shelf
    }

    private var open: Set<Panel> = []
    private let release: @MainActor () async -> Void

    /// `release` frees the shared memory (the app passes `FlotsamDatabase.releaseMemory`).
    public init(release: @escaping @MainActor () async -> Void) {
        self.release = release
    }

    /// True while at least one panel is open.
    public var isAnyOpen: Bool { !open.isEmpty }

    /// A panel starts to show. Idempotent.
    public func opened(_ panel: Panel) {
        open.insert(panel)
    }

    /// A panel is gone. Idempotent: a panel that was not open does nothing, so a second hide report never releases twice.
    /// The release is re-checked when it runs, so a panel that opened in between keeps what it just loaded.
    public func closed(_ panel: Panel) {
        guard open.remove(panel) != nil, open.isEmpty else { return }
        Task { [weak self] in
            guard let self, !isAnyOpen else { return }
            await release()
        }
    }
}
