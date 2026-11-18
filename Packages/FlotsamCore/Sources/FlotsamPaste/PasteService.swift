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
    /// Set at the first paste attempt made without Accessibility, so the system prompt shows once, not on every choice.
    private var accessibilityPrompted = false

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
        switch await loadContent(itemId) {
        case .success(let loaded): content = loaded
        case .failure(let error): return .failure(error)
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
        guard accessibilityAllowsPaste() else { return .success(.copiedAccessibilityDenied) }

        // Step 6.
        await waitUntilHidden(host)
        await clock.sleep(for: PasteTiming.settle)
        switch await postPaste(target: target) {
        case .success: return .success(.pasted)
        case .failure(let error): return .failure(error)
        }
    }

    /// The item-hotkey sequence (FR-005-05): FR-003-15 without the panel, with variables expanded (FR-005-17) and the
    /// user's previous clipboard put back after ⌘V (FR-005-16). The clipboard is not restored when the item was only
    /// copied or ⌘V failed: the item is then the thing the user must paste, so it stays on the pasteboard.
    public func pasteExpanded(itemId: UUID, target: FrontmostApp?, expansion: PasteExpansion) async -> FlotsamResult<PasteOutcome> {
        let span = Signposts.begin(.pasteBack)
        defer { span.end() }

        let content: ItemContent
        switch await loadContent(itemId) {
        case .success(let loaded): content = loaded
        case .failure(let error): return .failure(error)
        }
        let staged: PasteExpansion.Staged
        switch expansion.stage(content: content, itemId: itemId) {
        case .success(let value): staged = value
        case .failure(let error): return .failure(error)
        }
        if case .failure(let error) = await store.recordPaste(of: itemId) { FlotsamLog.log(error, category: .library) }

        guard accessibilityAllowsPaste() else { return .success(.copiedAccessibilityDenied) }
        await clock.sleep(for: PasteTiming.settle)
        if case .failure(let error) = await postPaste(target: target) { return .failure(error) }
        await expansion.finish(staged)
        return .success(.pasted)
    }

    /// Whether ⌘V can be posted. The first attempt without Accessibility also asks macOS for it (FR-008-13: "first paste
    /// attempt"); the item is copied either way, so the user is never left without it. Later attempts do not prompt.
    private func accessibilityAllowsPaste() -> Bool {
        if accessibility.isAccessibilityTrusted { return true }
        if !accessibilityPrompted {
            accessibilityPrompted = true
            accessibility.request(.accessibility)
        }
        return false
    }

    /// Step 1 of both sequences. Data missing (`LIB-IO-001`) deletes the item.
    private func loadContent(_ itemId: UUID) async -> FlotsamResult<ItemContent> {
        let loaded = await store.content(of: itemId)
        if case .failure(let error) = loaded, error.code == .libIo001 { _ = await store.delete(ids: [itemId]) }
        return loaded
    }

    /// Confirms `target` is frontmost (within 250 ms), then posts ⌘V to it. Shared with trigger expansion (FR-005-14).
    /// `LIB-OS-001` when the target never comes back, stops being frontmost at the post, or the event cannot be posted;
    /// nothing is re-written either way.
    public func postPaste(target: FrontmostApp?) async -> FlotsamResult<Void> {
        let failure = FlotsamError(.libOs001, "Paste target changed or key event not posted")
        guard let target else { return .failure(failure) }
        var waited: Duration = .zero
        while frontmost.frontmost() != target {
            guard waited < PasteTiming.targetWindow else { return .failure(failure) }
            await clock.sleep(for: PasteTiming.pollInterval)
            waited += PasteTiming.pollInterval
        }
        // `target` stays frontmost from the read above to the post: nothing suspends between them. The event is still
        // addressed to the target's process, because the session tap would deliver it to whichever app has focus when
        // the window server routes it, which can differ from what `NSWorkspace` last reported (FR-003-16).
        return keys.postPaste(to: target) ? .success(()) : .failure(failure)
    }

    private func waitUntilHidden(_ host: any PasteHost) async {
        var waited: Duration = .zero
        while host.isPanelVisible, waited < PasteTiming.targetWindow {
            await clock.sleep(for: PasteTiming.pollInterval)
            waited += PasteTiming.pollInterval
        }
    }
}
