import FlotsamBase
import FlotsamStorage
import Foundation

/// The paste-back sequence (FR-003-15, ADR-0005): pasteboard write, own-write marking, `pasteCount`, hide, then ⌘V into
/// the app that was frontmost when the Library opened.
@MainActor
public final class PasteService {
    private let store: any PasteItemStore
    private let pasteboard: any PasteboardPort
    private let files: any FileSystemPort
    private let frontmost: any FrontmostAppProvider
    private let accessibility: any PermissionProbe
    private let keys: any KeyEventPoster
    private let clock: any WallClock
    private let ownWrites: OwnWriteLedger

    public init(
        store: any PasteItemStore, pasteboard: any PasteboardPort, files: any FileSystemPort,
        frontmost: any FrontmostAppProvider, accessibility: any PermissionProbe, keys: any KeyEventPoster,
        clock: any WallClock, ownWrites: OwnWriteLedger
    ) {
        self.store = store
        self.pasteboard = pasteboard
        self.files = files
        self.frontmost = frontmost
        self.accessibility = accessibility
        self.keys = keys
        self.clock = clock
        self.ownWrites = ownWrites
    }

    /// Runs the sequence for one item. Failure codes: `LIB-IO-001` (data missing; the item is deleted), `LIB-DAT-001`
    /// (all files gone; panel stays open), `LIB-OS-001` (target changed or ⌘V not posted; item stays on the pasteboard).
    public func paste(itemId: UUID, mode: PasteMode, target: FrontmostApp?, host: any PasteHost) async -> FlotsamResult<PasteOutcome> {
        let span = Signposts.begin(.pasteBack)
        defer { span.end() }

        // Steps 1 and 2: read, resolve, write.
        let content: ItemContent
        switch await store.content(of: itemId) {
        case .success(let loaded): content = loaded
        case .failure(let error):
            if error.code == .libIo001 { _ = await store.delete(ids: [itemId]) }
            return .failure(error)
        }
        let representations: [PasteboardRepresentation]
        switch PastePayload.representations(for: content, mode: mode, itemId: itemId, files: files) {
        case .success(let built): representations = built
        case .failure(let error): return .failure(error)
        }
        // Step 3: the ledger adds the own-write markers to the same write and records its `changeCount` (FR-001-03).
        if case .failure(let error) = ownWrites.write(representations, to: pasteboard) { return .failure(error) }
        // Step 4. The item is on the pasteboard already, so a bookkeeping failure is logged, not shown.
        if case .failure(let error) = await store.recordPaste(of: itemId) { FlotsamLog.log(error, category: .library) }
        // Step 5.
        host.hidePanel()

        guard mode != .copyOnly else { return .success(.copied) }
        guard accessibility.isAccessibilityTrusted else { return .success(.copiedAccessibilityDenied) }

        // Step 6.
        await waitUntilHidden(host)
        await clock.sleep(for: PasteTiming.settle)
        switch await postPaste(target: target) {
        case .success: return .success(.pasted)
        case .failure(let error): return .failure(error)
        }
    }

    /// Confirms `target` is frontmost (within 250 ms), then posts ⌘V. Shared with trigger expansion (FR-005-14).
    /// `LIB-OS-001` when the target never comes back or the event cannot be posted; nothing is re-written either way.
    public func postPaste(target: FrontmostApp?) async -> FlotsamResult<Void> {
        let failure = FlotsamError(.libOs001, "Paste target changed or key event not posted")
        guard let target else { return .failure(failure) }
        var waited: Duration = .zero
        while frontmost.frontmost() != target {
            guard waited < PasteTiming.targetWindow else { return .failure(failure) }
            await clock.sleep(for: PasteTiming.pollInterval)
            waited += PasteTiming.pollInterval
        }
        return keys.postPaste() ? .success(()) : .failure(failure)
    }

    private func waitUntilHidden(_ host: any PasteHost) async {
        var waited: Duration = .zero
        while host.isPanelVisible, waited < PasteTiming.targetWindow {
            await clock.sleep(for: PasteTiming.pollInterval)
            waited += PasteTiming.pollInterval
        }
    }
}
