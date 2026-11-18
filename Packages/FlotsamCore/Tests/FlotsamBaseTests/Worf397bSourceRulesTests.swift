import Foundation
import Testing
@testable import FlotsamBase

// TASK-397 follow-up (Worf, worf-397b), rulings (c) and (d). Source-shape checks over the repository files, plus the
// literal truth table of ItemKind.referencesFiles.

@Suite struct Worf397bSourceRulesTests {
    private static let repo: URL = {
        var url = URL(fileURLWithPath: #filePath)
        while url.pathComponents.count > 1, !FileManager.default.fileExists(atPath: url.appendingPathComponent("project.yml").path) {
            url.deleteLastPathComponent()
        }
        return url
    }()

    private func read(_ relative: String) throws -> String {
        try String(contentsOf: Self.repo.appendingPathComponent(relative), encoding: .utf8)
    }

    private func swiftFiles(under relative: String) -> [URL] {
        let root = Self.repo.appendingPathComponent(relative)
        let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)
        return (walker?.allObjects as? [URL] ?? []).filter { $0.pathExtension == "swift" }
    }

    // Red if referencesFiles gains or loses a kind (e.g. link or image starts claiming files, or bundle is dropped).
    @Test("OC-397b-R1 referencesFiles is true for exactly file, folder and bundle")
    func truthTable() {
        let referencing = ItemKind.allCases.filter(\.referencesFiles).map(\.rawValue).sorted()

        #expect(referencing == ["bundle", "file", "folder"])
        #expect(ItemKind.allCases.count == 11)
    }

    // Red if the retired name comes back anywhere in the package, app or tests (ruling d: gone, no caller left).
    @Test("OC-397b-R2 isFileBacked is gone from every Swift source, app and package, and the repo root was found")
    func isFileBackedGone() throws {
        let files = swiftFiles(under: "Packages/FlotsamCore/Sources") + swiftFiles(under: "App")
        #expect(files.count > 100)
        let offenders = try files.filter { try String(contentsOf: $0, encoding: .utf8).contains("isFileBacked") }
        #expect(offenders.map(\.lastPathComponent) == [])
    }

    // Red if the Library's row menu regrows its own list of file kinds or stops asking the kind (ruling c). The Reveal in
    // Finder decision moved from LibraryRows to LibraryContextMenu (TASK-433), so the menu model is checked as well.
    @Test("OC-397b-R3 the row menu decides file-ness with kind.referencesFiles and LibraryRows/LibraryContextMenu repeat no kind list")
    func libraryRowsUsesReferencesFiles() throws {
        let menu = try read("Packages/FlotsamCore/Sources/FlotsamLibrary/LibraryContextMenu.swift")
        #expect(menu.contains("kind.referencesFiles"))
        for path in ["App/Flotsam/Library/LibraryRows.swift", "Packages/FlotsamCore/Sources/FlotsamLibrary/LibraryContextMenu.swift"] {
            let source = try read(path)
            #expect(!source.contains("[.file, .folder, .bundle]"), "\(path)")
            #expect(!source.contains(".file, .folder"), "\(path)")
            #expect(!source.contains("case .file, .bundle") && !source.contains("case .file, .folder"), "\(path)")
        }
    }

    // Red if a former caller drops back to its own gate.
    @Test("OC-397b-R4 PastePayload, ShelfDragPlanner and Reconcile each gate on referencesFiles")
    func callersUseReferencesFiles() throws {
        let paths = [
            "Packages/FlotsamCore/Sources/FlotsamPaste/PastePayload.swift",
            "Packages/FlotsamCore/Sources/FlotsamShelf/ShelfDragPlanner.swift",
            "Packages/FlotsamCore/Sources/FlotsamStorage/Reliability/Reconcile.swift",
        ]
        for path in paths { #expect(try read(path).contains("referencesFiles"), "\(path)") }
    }
}
