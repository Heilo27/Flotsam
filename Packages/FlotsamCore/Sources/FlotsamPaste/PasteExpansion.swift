import FlotsamBase
import FlotsamStorage
import Foundation

/// FR-005-14 steps 3 and 4 (with step 1's variables), the one home shared by typed triggers and item hotkeys
/// (FR-005-05, FR-005-16, FR-005-17, Rule 9): snapshot the user's clipboard, expand the item's variables against that
/// snapshot, and write the result with own-write markers. The caller then pastes and calls `finish`.
///
/// The snapshot is taken before the variables are expanded because `{clipboard}` is defined as the snapshot's plain
/// text (FR-005-17).
@MainActor
public struct PasteExpansion {
    /// What a successful `stage` leaves for the caller's later steps: the held clipboard and the change count after
    /// Flotsam's own write.
    public struct Staged: Sendable {
        let capture: HeldClipboard
        let writeChangeCount: Int
    }

    private let pasteboard: any PasteboardPort
    private let files: any FileSystemPort
    private let codec: any RichTextCodec
    private let preserver: ClipboardPreserver
    private let ownWrites: OwnWriteLedger
    private let clock: any WallClock
    private let calendar: Calendar
    private let locale: Locale

    public init(
        pasteboard: any PasteboardPort, files: any FileSystemPort, codec: any RichTextCodec,
        preserver: ClipboardPreserver, ownWrites: OwnWriteLedger, clock: any WallClock,
        calendar: Calendar = .current, locale: Locale = .current
    ) {
        self.pasteboard = pasteboard
        self.files = files
        self.codec = codec
        self.preserver = preserver
        self.ownWrites = ownWrites
        self.clock = clock
        self.calendar = calendar
        self.locale = locale
    }

    /// Snapshot, expand and write. On failure nothing is held and no restore is owed; the pasteboard is as the failed
    /// step left it.
    public func stage(content: ItemContent, itemId: UUID) -> FlotsamResult<Staged> {
        let capture = preserver.capture()
        let context = TemplateContext(
            now: clock.now(), calendar: calendar, locale: locale, clipboardText: capture.plainText)
        let representations: [PasteboardRepresentation]
        switch TemplatedPayload.representations(
            for: content, itemId: itemId, context: context, codec: codec, files: files)
        {
        case .success(let built): representations = built
        case .failure(let error): return .failure(error)
        }
        // The ledger adds the own-write markers to the same write and records the change count (FR-001-03).
        switch ownWrites.write(representations, to: pasteboard) {
        case .success(let count): return .success(Staged(capture: capture, writeChangeCount: count))
        case .failure(let error): return .failure(error)
        }
    }

    /// Puts the user's previous clipboard back if nobody else changed it meanwhile (FR-005-16).
    @discardableResult
    public func finish(_ staged: Staged) async -> RestoreOutcome {
        await preserver.restore(staged.capture, writeChangeCount: staged.writeChangeCount)
    }
}
