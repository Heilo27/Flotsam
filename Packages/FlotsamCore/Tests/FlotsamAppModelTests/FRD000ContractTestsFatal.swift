import Foundation
import Testing
import FlotsamBase

// FRD-000 8T contract tests, slice Fatal (oracle .claude/oracle/frd-000-contract.json). Package half of the fatal
// alert: the folder the "Reveal Data Folder" button opens (FatalAlert.nearestExistingFolder, compiled into this target
// through the FatalAlert.swift symlink) and the alert's text and button titles. The modal itself, Finder coming forward
// and the process exit need a window server and a live process and are listed in FRD000ContractTestsGaps.swift.
// Folder checks run in a throwaway directory under the temp folder; the real Flotsam data folder is never read or made.
// Expected values are literals.

/// A scratch directory tree, made writable again before removal (one test removes write permission).
private struct Scratch {
    let root: URL

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("flotsam-frd000-fatal-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    func makeDirectory(_ name: String) throws -> URL {
        let url = root.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    func names(in directory: URL) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted()
    }

    func discard() {
        _ = try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: root.appendingPathComponent("Application Support").path)
        try? FileManager.default.removeItem(at: root)
    }
}

@MainActor
@Suite struct FRD000ContractTestsFatal {

    // OC-0009. Red if nearestExistingFolder returns the missing folder itself (Finder would do nothing) or an unrelated
    // folder, or if it creates the data folder on the way (the listing below would then hold "Flotsam").
    @Test("OC-0009 given a missing data folder under an existing Application Support, then the reveal target is Application Support and nothing is created")
    func missingFolderRevealsParent() throws {
        let scratch = try Scratch()
        defer { scratch.discard() }
        let appSupport = try scratch.makeDirectory("Application Support")
        let dataFolder = appSupport.appendingPathComponent("Flotsam")

        let target = FatalAlert.nearestExistingFolder(from: dataFolder)

        #expect(target.lastPathComponent == "Application Support")
        #expect(target.deletingLastPathComponent().path == scratch.root.path)
        #expect(!FileManager.default.fileExists(atPath: dataFolder.path))
        #expect(try scratch.names(in: appSupport) == [])
    }

    // OC-0009. Red if the walk stops after one level: with two missing levels the target must be the first folder that exists.
    @Test("OC-0009 given the data folder and its parent both missing, then the reveal target is the nearest existing ancestor and 0 folders are created")
    func missingTwoLevelsRevealsNearestAncestor() throws {
        let scratch = try Scratch()
        defer { scratch.discard() }
        let dataFolder = scratch.root.appendingPathComponent("Application Support").appendingPathComponent("Flotsam")

        let target = FatalAlert.nearestExistingFolder(from: dataFolder)

        #expect(target.path == scratch.root.path)
        #expect(try scratch.names(in: scratch.root) == [])
    }

    // OC-0009. Red if the walk has no stop at the filesystem root (it would loop forever, so the test would hang) or returns a relative path.
    @Test("OC-0009 given a path with no existing ancestor but the root, then the reveal target is the filesystem root")
    func nothingExistsRevealsRoot() {
        let dataFolder = URL(fileURLWithPath: "/flotsam-frd000-absent-\(UUID().uuidString)/Application Support/Flotsam")

        let target = FatalAlert.nearestExistingFolder(from: dataFolder)

        #expect(target.path == "/")
    }

    // OC-0069. Red if nearestExistingFolder (or anything it calls) creates the missing folder once creation would
    // succeed: the folder would then exist and the listing would hold "Flotsam".
    @Test("OC-0069 given the parent was unwritable when the alert appeared and is writable at the click, then the data folder still does not exist and the target is the parent")
    func revealNeverCreatesEvenWhenCreationNowSucceeds() throws {
        let scratch = try Scratch()
        defer { scratch.discard() }
        let appSupport = try scratch.makeDirectory("Application Support")
        let dataFolder = appSupport.appendingPathComponent("Flotsam")
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: appSupport.path)
        let targetWhileUnwritable = FatalAlert.nearestExistingFolder(from: dataFolder)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: appSupport.path)

        let targetAtClick = FatalAlert.nearestExistingFolder(from: dataFolder)

        #expect(targetWhileUnwritable.path == appSupport.path)
        #expect(targetAtClick.path == appSupport.path)
        #expect(!FileManager.default.fileExists(atPath: dataFolder.path))
        #expect(try scratch.names(in: appSupport) == [])
    }

    // OC-0070. Red if an existing data folder is replaced by its parent (the user would land next to the damaged
    // database instead of on it) or if the walk touches the files inside it.
    @Test("OC-0070 given an existing data folder holding a database and its journal, then the reveal target is the folder itself and its 2 files are unchanged")
    func existingFolderRevealsItself() throws {
        let scratch = try Scratch()
        defer { scratch.discard() }
        let dataFolder = try scratch.makeDirectory("Flotsam")
        try Data("version-99".utf8).write(to: dataFolder.appendingPathComponent("flotsam.db"))
        try Data("wal".utf8).write(to: dataFolder.appendingPathComponent("flotsam.db-wal"))

        let target = FatalAlert.nearestExistingFolder(from: dataFolder)

        #expect(target.path == dataFolder.path)
        #expect(try scratch.names(in: dataFolder) == ["flotsam.db", "flotsam.db-wal"])
        #expect(try String(contentsOf: dataFolder.appendingPathComponent("flotsam.db"), encoding: .utf8) == "version-99")
    }

    // OC-0008. Red if the STO-IO-002 text or either button title changes, or the code stops being Fatal.
    @Test("OC-0008 given STO-IO-002, then the alert text is the catalogue sentence, the code is Fatal and the buttons read 'Reveal Data Folder' and 'Quit'")
    func ioFatalTextAndButtons() {
        let error = FlotsamError(.stoIo002, "test")

        #expect(error.severity == .fatal)
        #expect(FlotsamStrings.message(for: error) == "Flotsam can't create its data folder, so it can't run.")
        #expect(FlotsamStrings.text(forKey: "ui.fatal.revealDataFolder") == "Reveal Data Folder")
        #expect(FlotsamStrings.text(forKey: "ui.fatal.quit") == "Quit")
    }

    // OC-0010. Red if the STO-DB-003 text changes or the code stops being Fatal.
    @Test("OC-0010 given STO-DB-003, then the alert text is the catalogue sentence and the code is Fatal")
    func databaseFatalText() {
        let error = FlotsamError(.stoDb003, "test")

        #expect(error.severity == .fatal)
        #expect(FlotsamStrings.message(for: error) == "Flotsam can't open its history after an update. Your data is untouched; reinstall the previous version or reveal the data folder.")
    }

    // OC-0008 / OC-0010. Source scan (the alert is built inline and a modal cannot run under swift test). Red if a third
    // button is added, or the two buttons are reordered (the first button is the one that reveals).
    @Test("OC-0008 OC-0010 given the FatalAlert source, then it adds exactly 2 buttons, Reveal Data Folder first and Quit second")
    func exactlyTwoButtonsInOrder() throws {
        let file = URL(fileURLWithPath: #filePath)
        let repo = (0..<5).reduce(file) { url, _ in url.deletingLastPathComponent() }
        let source = try String(contentsOf: repo.appendingPathComponent("App/Flotsam/FatalAlert.swift"), encoding: .utf8)

        let buttonLines = source.split(separator: "\n").filter { $0.contains("addButton(") }.map { $0.trimmingCharacters(in: .whitespaces) }

        #expect(buttonLines.count == 2)
        #expect(buttonLines.first?.contains("ui.fatal.revealDataFolder") == true)
        #expect(buttonLines.last?.contains("ui.fatal.quit") == true)
    }
}
