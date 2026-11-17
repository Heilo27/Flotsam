import AppKit
import FlotsamBase

/// The general pasteboard (FR-003-15 step 2, FR-001-04). Main-actor: `NSPasteboard` thread safety is unverified
/// (ADR-0004).
@MainActor
final class NSPasteboardAdapter: PasteboardPort {
    private static let fileURLType = NSPasteboard.PasteboardType.fileURL.rawValue
    private let pasteboard: NSPasteboard

    init(pasteboard: NSPasteboard = .general) {
        self.pasteboard = pasteboard
    }

    var changeCount: Int { pasteboard.changeCount }

    func currentTypeIdentifiers() -> [String] {
        (pasteboard.types ?? []).map(\.rawValue)
    }

    func readSnapshot(types: [String]) -> FlotsamResult<PasteboardSnapshot> {
        let before = pasteboard.changeCount
        let present = currentTypeIdentifiers()
        var representations: [PasteboardRepresentation] = []
        for uti in types where present.contains(uti) {
            guard let data = pasteboard.data(forType: NSPasteboard.PasteboardType(uti)) else { continue }
            representations.append(PasteboardRepresentation(uti: uti, data: data))
        }
        // The owner may have rewritten the board while it was being read; the bytes would then mix two copies (FR-001-22).
        guard pasteboard.changeCount == before else {
            return .failure(FlotsamError(.capOs001, "Pasteboard changed while it was being read"))
        }
        return .success(PasteboardSnapshot(changeCount: before, typeIdentifiers: present, representations: representations))
    }

    /// Several `public.file-url` representations (a bundle) cannot share one `NSPasteboardItem`: a second `setData`
    /// for the same type replaces the first. So each file URL gets its own item, and every other representation
    /// (text, markers) rides on the first item.
    func write(_ representations: [PasteboardRepresentation]) -> FlotsamResult<Int> {
        let fileURLs = representations.filter { $0.uti == Self.fileURLType }
        let others = representations.filter { $0.uti != Self.fileURLType }

        var items: [NSPasteboardItem] = []
        for file in fileURLs {
            let item = NSPasteboardItem()
            guard item.setData(file.data, forType: .fileURL) else { return .failure(Self.writeFailure) }
            items.append(item)
        }
        if items.isEmpty { items.append(NSPasteboardItem()) }
        for representation in others {
            guard items[0].setData(representation.data, forType: NSPasteboard.PasteboardType(representation.uti)) else {
                return .failure(Self.writeFailure)
            }
        }

        pasteboard.clearContents()
        guard pasteboard.writeObjects(items) else { return .failure(Self.writeFailure) }
        // Read after the write: this is the count the own-write ledger records (FR-001-03).
        return .success(pasteboard.changeCount)
    }

    private static let writeFailure = FlotsamError(.libOs001, "The pasteboard refused the write")
}
