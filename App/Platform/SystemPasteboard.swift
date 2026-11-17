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
        return .success(PasteboardSnapshot(
            changeCount: before, typeIdentifiers: currentTypeIdentifiers(), representations: representations))
    }

    func write(_ representations: [PasteboardRepresentation]) -> FlotsamResult<Int> {
        let item = NSPasteboardItem()
        for representation in representations {
            item.setData(representation.data, forType: NSPasteboard.PasteboardType(representation.uti))
        }
        pasteboard.clearContents()
        guard pasteboard.writeObjects([item]) else {
            return .failure(FlotsamError(.capOs001, "pasteboard write failed"))
        }
        return .success(pasteboard.changeCount)
    }
}
