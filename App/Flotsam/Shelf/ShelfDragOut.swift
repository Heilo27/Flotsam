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
        let report: @MainActor (FlotsamError) -> Void
    }

    var ports: Ports?
    weak var model: ShelfModel?
    /// A drag session began (`true`) or ended (`false`): the reveal machine must not hide a Shelf under its own drag.
    var onSession: (@MainActor (Bool) -> Void)?
    /// A drop target accepted the drag (FR-006-11): a transient Shelf hides.
    var onAccepted: (@MainActor () -> Void)?

    private var prepared: Task<FlotsamResult<ShelfDragPlan>, Never>?
    private var draggedItemIds: [UUID] = []
    /// The session's begin callback ran; without it an ended session was aborted by the system (`ShelfDragEnd`).
    private var sessionBegan = false
    /// `NSPasteboardItem` does not retain its data provider; these live until the session ends.
    private var providers: [Provider] = []

    // MARK: Before the drag

    /// Called on mouse-down on card `id`: reads what the drag will need while the pointer is still travelling the
    /// drag threshold, so the session can start without a visible pause (FR-006-17).
    func prepare(cardId: UUID) {
        guard let ports, let model else { return }
        let rows = model.covered(by: cardId)
        prepared = Task {
            var candidates: [ShelfDragCandidate] = []
            for row in rows {
                switch await ports.content(row.id) {
                case .success(let content): candidates.append(ShelfDragCandidate(itemId: row.id, content: content))
                case .failure(let error): ports.report(error)
                }
            }
            return ShelfDragPlanner.plan(candidates, files: ports.files)
        }
    }

    /// Starts the session from `view` once the pointer has moved past the drag threshold. A plan that cannot be built
    /// is reported (`SHF-OS-001`, `LIB-DAT-001`) and no session starts.
    func begin(from view: NSView, event: NSEvent) async {
        guard let ports, let prepared else { return }
        self.prepared = nil
        switch await prepared.value {
        case .failure(let error):
            ports.report(error)
        case .success(let plan):
            start(plan, from: view, event: event)
        }
    }

    private func start(_ plan: ShelfDragPlan, from view: NSView, event: NSEvent) {
        providers = []
        var writers: [any NSPasteboardWriting] = []
        var written: Set<UUID> = []
        for item in plan.items {
            guard let writer = writer(for: item) else { continue }
            writers.append(writer)
            written.insert(item.itemId)
        }
        guard !writers.isEmpty else {
            ports?.report(FlotsamError(.libDat001, "Nothing left to drag"))
            return
        }
        // A card whose only item had no writer (an image `NSImage` cannot read) is not dragged, so it is neither counted
        // as pasted when the drop is accepted nor on the drag image's badge (FR-006-10, FR-006-11).
        draggedItemIds = plan.draggedItemIds.filter(written.contains)
        let frame = view.bounds
        let image = Self.stackedImage(of: view, count: draggedItemIds.count)
        let dragItems = writers.enumerated().map { index, writer in
            let dragItem = NSDraggingItem(pasteboardWriter: writer)
            dragItem.setDraggingFrame(frame, contents: index == 0 ? image : nil)
            return dragItem
        }
        sessionBegan = false
        let session = view.beginDraggingSession(with: dragItems, event: event, source: self)
        session.animatesToStartingPositionsOnCancelOrFail = true
    }

    /// One pasteboard item per planned item. Text and file URLs are provided lazily; an image goes through `NSImage`,
    /// and one whose bytes `NSImage` cannot read is skipped (FR-006-10).
    private func writer(for item: ShelfDragItem) -> (any NSPasteboardWriting)? {
        switch item.payload {
        case .representations(let representations):
            let pasteboardItem = NSPasteboardItem()
            let provider = Provider(representations)
            providers.append(provider)
            let types = representations.map { NSPasteboard.PasteboardType($0.uti) }
            guard pasteboardItem.setDataProvider(provider, forTypes: types) else { return nil }
            return pasteboardItem
        case .image(let representation):
            return NSImage(data: representation.data)
        }
    }

    private final class Provider: NSObject, NSPasteboardItemDataProvider {
        private let representations: [PasteboardRepresentation]
        init(_ representations: [PasteboardRepresentation]) { self.representations = representations }

        func pasteboard(_ pasteboard: NSPasteboard?, item: NSPasteboardItem, provideDataForType type: NSPasteboard.PasteboardType) {
            if let match = representations.first(where: { $0.uti == type.rawValue }) {
                item.setData(match.data, forType: type)
            }
        }
    }

    // MARK: NSDraggingSource

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        .copy
    }

    /// `.copy` whatever Option or Command is held (FR-006-10).
    func ignoreModifierKeys(for session: NSDraggingSession) -> Bool { true }

    func draggingSession(_ session: NSDraggingSession, willBeginAt screenPoint: NSPoint) {
        sessionBegan = true
        onSession?(true)
    }

    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        onSession?(false)
        providers = []
        let cards = draggedItemIds
        draggedItemIds = []
        let began = sessionBegan
        sessionBegan = false
        guard let ports else { return }
        switch ShelfDragEnd.resolve(accepted: operation != [], sessionBegan: began, cards: cards) {
        case .accepted(let accepted):
            // FR-006-11: one paste per card however many pasteboard items it contributed; FR-006-18: the count only.
            Task { for id in accepted { await ports.recordPaste(id) } }
            FlotsamLog.log(.shelf(.dragOut, outcome: .draggedOut, detail: .count(accepted.count)))
            onAccepted?()
        case .aborted(let error):
            ports.report(error)
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
