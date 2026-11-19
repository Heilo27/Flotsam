import AppKit
import FlotsamBase
import FlotsamShelf
import FlotsamStorage

/// Drag-out from the Shelf (FR-006-10, FR-006-11): turns the dragged cards into a drag session whose pasteboard items
/// are provided lazily, and does the accounting when a drop target accepts them. What a card provides is decided by
/// `ShelfDragPlanner`; which cards are dragged by `ShelfModel.covered(by:)`; this is the AppKit session between them.
///
/// The drag pasteboard is the only one written: the general pasteboard is never touched, so nothing here is an own
/// write for clipboard capture to skip. The operation is `.copy` whatever modifier keys are held.
@MainActor
final class ShelfDragOut: NSObject, NSDraggingSource {
    /// What the app supplies once the database is open. Until then a drag does nothing.
    struct Ports {
        let content: @Sendable (UUID) async -> FlotsamResult<ItemContent>
        /// One paste counted for a card whose drag was accepted (FR-006-11).
        let recordPaste: @Sendable (UUID) async -> Void
        let files: any FileSystemPort
        /// Authenticates, then decrypts a secure card (FR-006-21). Nil when no secure storage is wired.
        let secureAccess: SecureClipAccess?
        let report: @MainActor (FlotsamError) -> Void
    }

    var ports: Ports?
    weak var model: ShelfModel?
    /// A drag session began (`true`) or ended (`false`): the reveal machine must not hide a Shelf under its own drag.
    var onSession: (@MainActor (Bool) -> Void)?
    /// A drop target accepted the drag (FR-006-11): a transient Shelf hides.
    var onAccepted: (@MainActor () -> Void)?

    private var prepared: Task<FlotsamResult<ShelfDragPlan>, Never>?
    /// The owner authenticated for this drag, which may have taken longer than the pointer held the button.
    private var authenticated = false
    private var draggedItemIds: [UUID] = []
    /// `NSPasteboardItem` does not retain its data provider; these live until the session ends.
    private var providers: [Provider] = []

    // MARK: Before the drag

    /// Called on mouse-down on card `id`: reads what the drag will need while the pointer is still travelling the
    /// drag threshold, so the session can start without a visible pause (FR-006-17). A secure card asks the owner to
    /// authenticate here, every time (FR-006-21): its text exists only after that, and a card whose check fails
    /// provides nothing.
    func prepare(cardId: UUID) {
        guard let ports, let model else { return }
        let rows = model.covered(by: cardId)
        authenticated = false
        prepared = Task {
            var candidates: [ShelfDragCandidate] = []
            var declined: FlotsamError?
            for row in rows {
                switch await ports.content(row.id) {
                case .failure(let error):
                    ports.report(error)
                case .success(let content):
                    var revealed: String?
                    if let ciphertext = content.secureCiphertext {
                        switch await ports.secureAccess.reveal(ciphertext: ciphertext) {
                        case .success(let text): revealed = text
                        case .failure(let error): declined = declined ?? error; continue
                        }
                        authenticated = true
                    }
                    candidates.append(ShelfDragCandidate(itemId: row.id, content: content, revealedSecureText: revealed))
                }
            }
            // A declined check is the one thing reported about a drag that has nothing else to give, so the cancel
            // is a single quiet HUD, not that plus "nothing to drag".
            if let declined {
                if candidates.isEmpty { return .failure(declined) }
                ports.report(declined)
            }
            return ShelfDragPlanner.plan(candidates, files: ports.files)
        }
    }

    /// Starts the session from `view` once the pointer has moved past the drag threshold. A drag that cannot start is
    /// reported (`SHF-OS-001`, `LIB-DAT-001`) and no session starts. AppKit shows a failure only before the session
    /// begins or while it asks for data, so those are the places that report (`ShelfDragStart`).
    func begin(from view: NSView, event: NSEvent?) async {
        guard let ports, let prepared else { return }
        self.prepared = nil
        let plan = await prepared.value
        // The authentication prompt can outlast the press: a session begun after the button is up would never end.
        if authenticated, NSEvent.pressedMouseButtons & 1 == 0 { return }
        switch plan {
        case .failure(let error):
            ports.report(error)
        case .success(let plan):
            start(plan, from: view, event: event, ports: ports)
        }
    }

    private func start(_ plan: ShelfDragPlan, from view: NSView, event: NSEvent?, ports: Ports) {
        let checked = ShelfDragStart.preflight(plan, hasWindow: view.window != nil, hasEvent: event != nil, files: ports.files)
        let ready: ShelfDragPlan
        switch checked {
        case .failure(let error):
            ports.report(error)
            return
        case .success(let plan):
            ready = plan
        }
        guard let event else { return }
        providers = []
        let report: @Sendable (FlotsamError) -> Void = { error in Task { @MainActor in ports.report(error) } }
        var writers: [(item: ShelfDragItem, writer: any NSPasteboardWriting)] = []
        var outcomes: [ShelfDragStart.WriterOutcome] = []
        for item in ready.items {
            let made = writer(for: item, report: report)
            if let writer = made.writer { writers.append((item, writer)) }
            outcomes.append(made.outcome)
        }
        switch ShelfDragStart.launch(ready, outcomes: outcomes) {
        case .fail(let error):
            providers = []
            ports.report(error)
        case .start(let dragged, let error):
            // A card none of whose items got a writer is not dragged, so it is neither counted as pasted when the drop
            // is accepted nor on the drag image's badge (FR-006-10, FR-006-11).
            if let error { ports.report(error) }
            draggedItemIds = dragged
            let frame = view.bounds
            let image = Self.stackedImage(of: view, count: dragged.count)
            let dragItems = writers.enumerated().map { index, entry in
                let dragItem = NSDraggingItem(pasteboardWriter: entry.writer)
                dragItem.setDraggingFrame(frame, contents: index == 0 ? image : nil)
                return dragItem
            }
            let session = view.beginDraggingSession(with: dragItems, event: event, source: self)
            session.animatesToStartingPositionsOnCancelOrFail = true
        }
    }

    /// One pasteboard item per planned item. Text and file URLs are provided lazily; an image goes through `NSImage`,
    /// and one whose bytes `NSImage` cannot read is skipped (FR-006-10).
    private func writer(for item: ShelfDragItem, report: @escaping @Sendable (FlotsamError) -> Void)
        -> (writer: (any NSPasteboardWriting)?, outcome: ShelfDragStart.WriterOutcome)
    {
        switch item.payload {
        case .representations(let representations):
            let pasteboardItem = NSPasteboardItem()
            let provider = Provider(representations, report: report)
            providers.append(provider)
            let types = representations.map { NSPasteboard.PasteboardType($0.uti) }
            guard pasteboardItem.setDataProvider(provider, forTypes: types) else { return (nil, .providerRejected) }
            return (pasteboardItem, .written)
        case .image(let representation):
            guard let image = NSImage(data: representation.data) else { return (nil, .imageUnreadable) }
            return (image, .written)
        }
    }

    private final class Provider: NSObject, NSPasteboardItemDataProvider {
        private let representations: [PasteboardRepresentation]
        private let report: @Sendable (FlotsamError) -> Void
        init(_ representations: [PasteboardRepresentation], report: @escaping @Sendable (FlotsamError) -> Void) {
            self.representations = representations
            self.report = report
        }

        func pasteboard(_ pasteboard: NSPasteboard?, item: NSPasteboardItem, provideDataForType type: NSPasteboard.PasteboardType) {
            guard let match = representations.first(where: { $0.uti == type.rawValue }) else {
                report(ShelfDragStart.osError(.noRepresentation))
                return
            }
            item.setData(match.data, forType: type)
        }
    }

    // MARK: NSDraggingSource

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        .copy
    }

    /// `.copy` whatever Option or Command is held (FR-006-10).
    func ignoreModifierKeys(for session: NSDraggingSession) -> Bool { true }

    func draggingSession(_ session: NSDraggingSession, willBeginAt screenPoint: NSPoint) {
        onSession?(true)
    }

    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        onSession?(false)
        providers = []
        let cards = draggedItemIds
        draggedItemIds = []
        guard let ports else { return }
        switch ShelfDragEnd.resolve(accepted: operation != [], cards: cards) {
        case .accepted(let accepted):
            // FR-006-11: one paste per card however many pasteboard items it contributed; FR-006-18: the count only.
            Task { for id in accepted { await ports.recordPaste(id) } }
            FlotsamLog.log(.shelf(.dragOut, outcome: .draggedOut, detail: .count(accepted.count)))
            onAccepted?()
        case .userCancelled, .none:
            break
        }
    }

    // MARK: Drag image

    /// The card as it looks, stacked with up to two shadows behind it and a count badge when several cards go
    /// (FR-006-10). Falls back to a plain rectangle when the card cannot be snapshotted.
    private static func stackedImage(of view: NSView, count: Int) -> NSImage {
        let size = view.bounds.size
        let card = NSImage(size: size)
        if let rep = view.window?.contentView?.bitmapImageRepForCachingDisplay(in: view.convert(view.bounds, to: nil)),
           let content = view.window?.contentView {
            content.cacheDisplay(in: view.convert(view.bounds, to: nil), to: rep)
            card.addRepresentation(rep)
        } else {
            card.lockFocus()
            NSColor.controlBackgroundColor.setFill()
            NSBezierPath(roundedRect: NSRect(origin: .zero, size: size), xRadius: 8, yRadius: 8).fill()
            card.unlockFocus()
        }
        let layers = min(count, 3)
        let step: CGFloat = 4
        let total = NSSize(width: size.width + step * CGFloat(layers - 1), height: size.height + step * CGFloat(layers - 1))
        return NSImage(size: total, flipped: false) { _ in
            for layer in stride(from: layers - 1, through: 0, by: -1) {
                card.draw(in: NSRect(x: step * CGFloat(layer), y: step * CGFloat(layers - 1 - layer), width: size.width, height: size.height),
                    from: .zero, operation: .sourceOver, fraction: layer == 0 ? 0.95 : 0.5)
            }
            if count > 1 { drawBadge(count, in: total) }
            return true
        }
    }

    private static func drawBadge(_ count: Int, in bounds: NSSize) {
        let text = NSAttributedString(
            string: String(count),
            attributes: [.font: NSFont.boldSystemFont(ofSize: 11), .foregroundColor: NSColor.white])
        let diameter = max(18, text.size().width + 8)
        let badge = NSRect(x: bounds.width - diameter, y: bounds.height - diameter, width: diameter, height: diameter)
        NSColor.controlAccentColor.setFill()
        NSBezierPath(ovalIn: badge).fill()
        text.draw(at: NSPoint(x: badge.midX - text.size().width / 2, y: badge.midY - text.size().height / 2))
    }
}
