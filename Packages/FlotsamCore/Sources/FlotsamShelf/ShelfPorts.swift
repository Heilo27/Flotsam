import FlotsamBase
import FlotsamStorage
import Foundation

// The Shelf may import only Base, Storage and Payload (ADR-0001), so it cannot name the Library's or Paste's types.
// Everything it needs from outside is a port declared here; the composition root (the app) adapts the real services.

/// What the Shelf reads from and changes in storage. `FlotsamDatabase` conforms below; tests use a fake, so model
/// tests need no database.
public protocol ShelfDataSource: Sendable {
    func items(matching query: LibraryQuery) async -> FlotsamResult<ItemPage>
    /// Sets every listed item to `pinned` (FRD-004 FR-004-01); the model decides the state with `PinRule`.
    @discardableResult
    func setPinned(ids: [UUID], pinned: Bool) async -> FlotsamResult<Bool>
    /// Deletes the items; returns the ids actually removed (FRD-004 FR-004-09).
    func delete(ids: [UUID]) async -> FlotsamResult<[UUID]>
}

extension FlotsamDatabase: ShelfDataSource {}

/// How a drop reaches storage (FR-006-13): the same ingest pipeline clipboard capture uses (FRD-007 FR-007-05).
/// `IngestActor` conforms below; tests use it over a real database, or a fake to inject a failure.
public protocol ShelfIngesting: Sendable {
    func ingest(_ candidate: IngestCandidate) async -> FlotsamResult<IngestResult>
}

extension IngestActor: ShelfIngesting {}

/// What a card needs that `ItemRow` does not carry: the stored text of a text item (the row's primary line is cut to
/// two lines, the card shows three). `FlotsamDatabase` conforms below, through one storage query.
///
/// The Missing state is not here: `ItemRow.isMissing` already carries it, read from the disk by the storage query
/// layer through `Collection<ItemMember>.anyExists(files:)`, the one home of the rule (FRD-003 FR-003-07; S1 ruling
/// 2026-11-17). The Shelf only reads the flag.
public protocol ShelfCardDetails: Sendable {
    /// The stored plain text of each listed item that has some; items without text are left out. A failed read is the
    /// storage error; the model reports it and the cards fall back to their primary line.
    func cardTexts(for ids: [UUID]) async -> FlotsamResult<[UUID: String]>
}

extension FlotsamDatabase: ShelfCardDetails {
    public func cardTexts(for ids: [UUID]) async -> FlotsamResult<[UUID: String]> {
        await plainTexts(of: ids, characterLimit: ShelfLayout.cardTextReadLimit)
    }
}

/// The inert details: no stored texts, so every card shows its row's primary line.
public struct NoShelfCardDetails: ShelfCardDetails {
    public init() {}
    public func cardTexts(for ids: [UUID]) async -> FlotsamResult<[UUID: String]> { .success([:]) }
}

// MARK: Paste

/// How a card is pasted (FRD-003 FR-003-15). The Shelf's own copy of the Paste module's `PasteMode`, because the Shelf
/// cannot import Paste; the app maps one to the other.
public enum ShelfPasteMode: Sendable, Equatable {
    case paste, plainText, copyOnly
}

/// What a paste did, mirroring the Paste module's `PasteOutcome`.
public enum ShelfPasteOutcome: Sendable, Equatable {
    case pasted
    case copied
    /// On the pasteboard, no ⌘V because Accessibility is off; the model reports `SET-PRM-001` (FR-006-08).
    case copiedAccessibilityDenied
}

/// The Shelf panel, as the paste sequence needs it (FRD-003 FR-003-15 steps 5 and 6).
@MainActor
public protocol ShelfPasteHost {
    var isPanelVisible: Bool { get }
    func hidePanel()
}

/// The paste sequence as the Shelf calls it. The app layer adapts `PasteService` to this (`ShelfPasteAdapter`); the
/// Shelf's own tests use fakes.
@MainActor
public protocol ShelfPasting {
    func paste(itemId: UUID, mode: ShelfPasteMode, target: FrontmostApp?, host: any ShelfPasteHost) async -> FlotsamResult<ShelfPasteOutcome>
}

// MARK: Effects

/// Everything the model asks of its surroundings that is not storage or paste. Defaults are inert so a test sets only
/// what it observes.
public struct ShelfEffects {
    public var report: @MainActor (FlotsamError) -> Void
    /// FR-001-02: flush the clipboard capture pipeline so a copy made an instant ago is stored before the list is read.
    public var captureNow: @MainActor () async -> Void
    /// Asks the user to confirm a delete (FR-004-09); the text is the question. Declining is the default, so an unwired
    /// confirmation never deletes.
    public var confirmDelete: @MainActor (String) async -> Bool
    public var now: @MainActor () -> Date

    public init(
        report: @escaping @MainActor (FlotsamError) -> Void = { _ in },
        captureNow: @escaping @MainActor () async -> Void = {},
        confirmDelete: @escaping @MainActor (String) async -> Bool = { _ in false },
        now: @escaping @MainActor () -> Date = { Date() }
    ) {
        self.report = report
        self.captureNow = captureNow
        self.confirmDelete = confirmDelete
        self.now = now
    }
}
