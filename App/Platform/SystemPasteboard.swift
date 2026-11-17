import AppKit
import FlotsamBase

/// `PasteboardPort` over `NSPasteboard.general`. The only file that touches the pasteboard (ADR-0001).
///
/// Multi-item pasteboards (FR-001-07): Finder puts one item per file. Type identifiers are the union across items;
/// `public.file-url` is returned once per item, in item order, so the classifier sees every file; every other type
/// is read from the first item that carries it.
@MainActor
struct SystemPasteboard: PasteboardPort {
    private let pasteboard: NSPasteboard

    init(pasteboard: NSPasteboard = .general) { self.pasteboard = pasteboard }

    var changeCount: Int { pasteboard.changeCount }

    func currentTypeIdentifiers() -> [String] {
        var seen = Set<String>()
        return (pasteboard.pasteboardItems ?? []).flatMap(\.types).map(\.rawValue).filter { seen.insert($0).inserted }
    }

    func readSnapshot(types: [String]) -> FlotsamResult<PasteboardSnapshot> {
        let before = pasteboard.changeCount
        let items = pasteboard.pasteboardItems ?? []
        var representations: [PasteboardRepresentation] = []
        for uti in types {
            let type = NSPasteboard.PasteboardType(uti)
            if type == .fileURL {
                for item in items {
                    if let data = item.data(forType: type) { representations.append(.init(uti: uti, data: data)) }
                }
            } else if let data = items.lazy.compactMap({ $0.data(forType: type) }).first {
                representations.append(.init(uti: uti, data: data))
            }
        }
        // The owner may have rewritten the board while it was being read; the bytes would then mix two copies (FR-001-22).
        guard pasteboard.changeCount == before else {
            return .failure(FlotsamError(.capOs001, "Pasteboard changed while it was being read"))
        }
        return .success(PasteboardSnapshot(
            changeCount: before, typeIdentifiers: currentTypeIdentifiers(), representations: representations))
    }

    /// Several `public.file-url` representations (a bundle) cannot share one `NSPasteboardItem`: a second `setData`
    /// for the same type replaces the first. So each file URL gets its own item, and every other representation
    /// (text, markers) rides on the first item.
    func write(_ representations: [PasteboardRepresentation]) -> FlotsamResult<Int> {
        let fileURLType = NSPasteboard.PasteboardType.fileURL.rawValue
        var items: [NSPasteboardItem] = []
        for file in representations where file.uti == fileURLType {
            let item = NSPasteboardItem()
            guard item.setData(file.data, forType: .fileURL) else { return .failure(Self.writeFailure) }
            items.append(item)
        }
        if items.isEmpty { items.append(NSPasteboardItem()) }
        for representation in representations where representation.uti != fileURLType {
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
