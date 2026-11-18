import FlotsamBase
import FlotsamPaste
import FlotsamShelf
import Foundation

/// Adapts the paste-back sequence (`PasteService`, FR-003-15) to the Shelf's own port. The Shelf cannot import Paste
/// (ADR-0001), so the two enums are mapped here, one case to one case, and the Shelf's panel is handed to the service as
/// a `PasteHost`. The Shelf pastes through the same service as the Library: one sequence, one set of error codes
/// (FR-006-08).
@MainActor
struct ShelfPasteAdapter: ShelfPasting {
    private let service: PasteService

    init(service: PasteService) { self.service = service }

    func paste(
        itemId: UUID, mode: ShelfPasteMode, target: FrontmostApp?, host: any ShelfPasteHost
    ) async -> FlotsamResult<ShelfPasteOutcome> {
        switch await service.paste(itemId: itemId, mode: Self.pasteMode(mode), target: target, host: HostBridge(host: host)) {
        case .success(let outcome): return .success(Self.outcome(outcome))
        case .failure(let error): return .failure(error)
        }
    }

    static func pasteMode(_ mode: ShelfPasteMode) -> PasteMode {
        switch mode {
        case .paste: .paste
        case .plainText: .plainText
        case .copyOnly: .copyOnly
        }
    }

    static func outcome(_ outcome: PasteOutcome) -> ShelfPasteOutcome {
        switch outcome {
        case .pasted: .pasted
        case .copied: .copied
        case .copiedAccessibilityDenied: .copiedAccessibilityDenied
        }
    }

    /// The Shelf's panel as the paste sequence sees it (FR-003-15 steps 5 and 6).
    @MainActor
    private struct HostBridge: PasteHost {
        let host: any ShelfPasteHost
        var isPanelVisible: Bool { host.isPanelVisible }
        func hidePanel() { host.hidePanel() }
    }
}
