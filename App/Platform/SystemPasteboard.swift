import AppKit
import FlotsamBase

/// The general pasteboard behind `PasteboardPort`. Only `write` is needed so far (the diagnostics copy); the reads
/// belong to FRD-001's capture path and are left as explicit failures rather than guesses.
@MainActor
struct SystemPasteboard: PasteboardPort {
    var changeCount: Int { NSPasteboard.general.changeCount }

    func currentTypeIdentifiers() -> [String] { NSPasteboard.general.types?.map(\.rawValue) ?? [] }

    func readSnapshot(types: [String]) -> FlotsamResult<PasteboardSnapshot> {
        .failure(FlotsamError(.sysInt001, "Pasteboard reads are not wired yet (FRD-001)"))
    }

    func write(_ representations: [PasteboardRepresentation]) -> FlotsamResult<Int> {
        let board = NSPasteboard.general
        board.clearContents()
        let types = representations.map { NSPasteboard.PasteboardType($0.uti) }
        board.declareTypes(types, owner: nil)
        for representation in representations where !board.setData(representation.data, forType: .init(representation.uti)) {
            return .failure(FlotsamError(.sysInt001, "Pasteboard write failed for \(representation.uti)"))
        }
        return .success(board.changeCount)
    }
}
