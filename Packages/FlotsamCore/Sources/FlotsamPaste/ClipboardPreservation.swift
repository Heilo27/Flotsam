import FlotsamBase
import Foundation

/// What `ClipboardPreserver.capture()` found on the pasteboard at expansion step 3 (FR-005-14, FR-005-16).
///
/// Holds the user's previous clipboard in memory only. It is `Sendable` so it can ride an async sequence, and it has no
/// `Codable`, no description and no logging: the bytes must never reach disk or a log (FR-005-16, FR-005-20).
public struct HeldClipboard: Sendable {
    public enum Disposition: Sendable, Equatable {
        /// A copy is held and will be put back.
        case held
        /// The pasteboard was empty: there is nothing to put back.
        case empty
        /// The pasteboard carries the Concealed or Transient marker (a copied password, a one-time code). Flotsam does
        /// not read it, hold it or restore it.
        case concealed
        /// Over `ClipboardPreserver.snapshotCap`: not held, so not restored.
        case tooLarge
        /// The read was refused (pasteboard privacy) or failed.
        case unreadable
    }

    public let disposition: Disposition
    /// The `{clipboard}` value (FR-005-17): plain text of the pasteboard, empty when there is none or it was blocked.
    public let plainText: String
    /// Deduplicated, marker-free copy to write back. Empty unless `disposition == .held`.
    let representations: [PasteboardRepresentation]
}

public enum RestoreOutcome: Sendable, Equatable {
    case restored
    /// Something else changed the pasteboard in the window: the clipboard is left as that app set it.
    case changedByAnotherApp
    /// There was no held copy.
    case nothingHeld
    /// The write-back itself failed.
    case writeFailed
}

/// FR-005-16: put the user's clipboard back after a trigger expansion or item-hotkey paste. The one home, so both
/// callers restore identically.
///
/// Known limitation: `PasteboardSnapshot` is flat (type identifier to bytes), so a pasteboard that held several items
/// comes back as one item with the first representation of each type. Single-item content (text, rich text, one image,
/// one file URL) round-trips; a multi-file copy keeps its first file only.
@MainActor
public final class ClipboardPreserver {
    /// 32 MiB (FR-005-16).
    public static let snapshotCap = 32 * 1024 * 1024
    /// Time after ⌘V is posted before the restore (FR-005-16).
    public static let restoreDelay: Duration = .milliseconds(300)

    private let pasteboard: any PasteboardPort
    private let ownWrites: OwnWriteLedger
    private let clock: any WallClock

    public init(pasteboard: any PasteboardPort, ownWrites: OwnWriteLedger, clock: any WallClock) {
        self.pasteboard = pasteboard
        self.ownWrites = ownWrites
        self.clock = clock
    }

    /// Reads the pasteboard. Type identifiers come first, with no bytes, so a Concealed or Transient pasteboard is
    /// recognised before any of its content is read.
    public func capture() -> HeldClipboard {
        let types = pasteboard.currentTypeIdentifiers()
        if types.contains(PasteboardMarkers.concealed) || types.contains(PasteboardMarkers.transient) {
            return HeldClipboard(disposition: .concealed, plainText: "", representations: [])
        }
        guard !types.isEmpty else { return HeldClipboard(disposition: .empty, plainText: "", representations: []) }
        guard case .success(let snapshot) = pasteboard.readSnapshot(types: types) else {
            return HeldClipboard(disposition: .unreadable, plainText: "", representations: [])
        }
        let text = snapshot.representations.first { $0.uti == PasteboardUTI.plainText }
            .flatMap { String(data: $0.data, encoding: .utf8) } ?? ""
        // The port has no size query, so the cap is applied after the read; the oversized copy is dropped here.
        let bytes = snapshot.representations.reduce(0) { $0 + $1.data.count }
        guard bytes <= Self.snapshotCap else {
            return HeldClipboard(disposition: .tooLarge, plainText: text, representations: [])
        }
        return HeldClipboard(disposition: .held, plainText: text, representations: Self.restorable(snapshot.representations))
    }

    /// Waits `restoreDelay`, then writes the held copy back with own-write markers, but only if `changeCount` still
    /// equals `writeChangeCount`, the value Flotsam's own write produced. Any other value means another app copied.
    public func restore(_ capture: HeldClipboard, writeChangeCount: Int) async -> RestoreOutcome {
        guard capture.disposition == .held else { return .nothingHeld }
        await clock.sleep(for: Self.restoreDelay)
        guard pasteboard.changeCount == writeChangeCount else { return .changedByAnotherApp }
        switch ownWrites.write(capture.representations, to: pasteboard) {
        case .success: return .restored
        case .failure: return .writeFailed
        }
    }

    /// One representation per type (the first wins) and none of Flotsam's own markers, which the ledger re-adds.
    private static func restorable(_ representations: [PasteboardRepresentation]) -> [PasteboardRepresentation] {
        var seen: Set<String> = [PasteboardMarkers.ownWrite, PasteboardMarkers.autoGenerated]
        return representations.filter { seen.insert($0.uti).inserted }
    }
}
