import Foundation
import Testing
@testable import FlotsamBase

// FRD-000 FR-000-11 callsite checklist, OC-0038 (screenshot, paste-back, hotkey, Shelf, trigger) and OC-0039 (database,
// retention sweep, permission transitions). The callsite is what the checklist in FRD-000 tracks, so these tests scan the
// shipped sources (the package modules and the App target) for the `LogEvent` call that owns each row, and render the
// event to prove it carries outcome or count only. The scripted-session `log show` half of the oracle needs the running
// app; what a unit test can hold is "the owning module calls it, and the call cannot carry content".
//
// A callsite no module makes yet is a `.disabled("DEFECT ...")` test naming the owning ticket from the checklist, so the
// gap is visible in the test list and the test turns on the moment the call lands.

private enum Callsites {
    /// Every `.swift` file under the package sources and the App target, excluding the `LogEvent` definition itself.
    static func sourceFiles() -> [URL] {
        let roots = [
            Repo.packageRoot().appendingPathComponent("Sources"),
            Repo.root().appendingPathComponent("App"),
        ]
        var files: [URL] = []
        for root in roots {
            guard let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil) else { continue }
            for case let url as URL in walker where url.pathExtension == "swift" && url.lastPathComponent != "LogEvent.swift" {
                files.append(url)
            }
        }
        return files
    }

    /// Repo-relative paths of the files whose source matches `pattern` (a regular expression).
    static func files(matching pattern: String) -> [String] {
        let regex = try! NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators])
        let rootPath = Repo.root().path + "/"
        return sourceFiles().compactMap { url -> String? in
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
            let range = NSRange(text.startIndex..., in: text)
            return regex.firstMatch(in: text, range: range) == nil ? nil : url.path.replacingOccurrences(of: rootPath, with: "")
        }.sorted()
    }

    /// The module directory every match must live in (`Packages/FlotsamCore/Sources/<module>/` or `App/Flotsam/<dir>/`).
    static func allIn(_ files: [String], _ prefix: String) -> Bool { !files.isEmpty && files.allSatisfy { $0.hasPrefix(prefix) } }
}

@Suite("FR-000-11 callsite checklist")
struct Frd000CallsiteChecklistTests {
    private static let sources = "Packages/FlotsamCore/Sources/"

    // MARK: OC-0038, wired callsites

    /// OC-0038 (screenshot import). Red if the `.screenshotImported` call is removed from FlotsamScreenshots (or moved out
    /// of that module): the scan finds no file there.
    @Test("OC-0038 a screenshot import logs its outcome from the Screenshots module")
    func screenshotImportCallsite() {
        // given the shipped sources
        // when the files calling LogEvent.screenshotImported are collected
        let files = Callsites.files(matching: #"\.screenshotImported\("#)
        // then they are exactly the Screenshots module's, and the event renders outcome and size only
        #expect(Callsites.allIn(files, Self.sources + "FlotsamScreenshots/"))
        let line = FlotsamLog.render(LogEvent.screenshotImported(outcome: .stored, byteSize: 2048).fields)
        #expect(line.publicPart == "byteSize=2048B outcome=stored")
        #expect(line.privatePart == "")
    }

    /// OC-0038 (Shelf reveal and drop-in). Red if either call leaves FlotsamShelf or its action tag changes.
    @Test("OC-0038 Shelf reveal and drop-in each log from the Shelf module")
    func shelfRevealAndDropInCallsites() {
        // given the shipped sources
        // when the reveal and drop-in calls are collected separately
        let reveal = Callsites.files(matching: #"\.shelf\(\.reveal"#)
        let dropIn = Callsites.files(matching: #"\.shelf\(\.dropIn"#)
        // then each exists in the Shelf module
        #expect(Callsites.allIn(reveal, Self.sources + "FlotsamShelf/"))
        #expect(Callsites.allIn(dropIn, Self.sources + "FlotsamShelf/"))
        // and the two are different files: one call cannot stand in for both
        #expect(Set(reveal) != Set(dropIn))
    }

    /// OC-0038 (drag-out). The drag source is AppKit and lives in the App target, which no package test can run, so the
    /// callsite is verified by its source. Red if `ShelfDragOut` stops logging `.shelf(.dragOut ...)`.
    @Test("OC-0038 Shelf drag-out logs from the App target")
    func shelfDragOutCallsite() {
        // given the shipped sources
        // when the drag-out calls are collected
        let files = Callsites.files(matching: #"\.shelf\(\.dragOut"#)
        // then exactly the App's Shelf drag source makes it
        #expect(files == ["App/Flotsam/Shelf/ShelfDragOut.swift"])
    }

    /// OC-0038 (trigger match = yes) and "trigger entries contain no typed characters". Red if the matched call leaves
    /// FlotsamTriggers, or if the event grows a field that can hold the typed buffer (its public and private text change).
    @Test("OC-0038 a trigger match logs a bare yes from the Triggers module and nothing typed")
    func triggerMatchYesCallsiteAndShape() {
        // given the shipped sources
        // when the triggerMatched(true) calls are collected
        let files = Callsites.files(matching: #"\.triggerMatched\(true\)"#)
        // then the Triggers module makes it
        #expect(Callsites.allIn(files, Self.sources + "FlotsamTriggers/"))
        // and both outcomes render one outcome word and nothing private
        let yes = FlotsamLog.render(LogEvent.triggerMatched(true).fields)
        let no = FlotsamLog.render(LogEvent.triggerMatched(false).fields)
        #expect(yes.publicPart == "outcome=matched")
        #expect(no.publicPart == "outcome=noMatch")
        #expect(yes.privatePart == "")
        #expect(no.privatePart == "")
    }

    // MARK: OC-0038, callsites no module makes yet

    @Test("OC-0038 trigger match = no is logged by the Triggers module")
    func triggerMatchNoCallsite() {
        // given the shipped sources, when the triggerMatched(false) calls are collected
        let files = Callsites.files(matching: #"\.triggerMatched\(false\)"#)
        // then the Triggers module makes one
        #expect(Callsites.allIn(files, Self.sources + "FlotsamTriggers/"))
    }

    @Test("OC-0038 paste-back start and outcome are logged")
    func pasteBackCallsites() {
        // given the shipped sources, when the paste-back calls are collected
        let started = Callsites.files(matching: #"\.pasteBack\(outcome: \.started"#)
        let any = Callsites.files(matching: #"\.pasteBack\("#)
        // then a start call exists and at least one outcome call beyond it
        #expect(Callsites.allIn(started, Self.sources + "FlotsamPaste/"))
        #expect(!any.isEmpty)
    }

    @Test("OC-0038 a global hotkey registration result is logged")
    func hotkeyRegistrationCallsite() {
        // given the shipped sources, when the hotkeyRegistered calls are collected
        let files = Callsites.files(matching: #"\.hotkeyRegistered\("#)
        // then a module makes one
        #expect(!files.isEmpty)
    }

    // MARK: OC-0039, callsites no module makes yet

    @Test("OC-0039 database open, migrate and integrity-check results are logged")
    func databaseStepCallsites() {
        // given the shipped sources, when each step's call is collected
        let open = Callsites.files(matching: #"\.database\(\.open"#)
        let migrate = Callsites.files(matching: #"\.database\(\.migrate"#)
        let integrity = Callsites.files(matching: #"\.database\(\.integrityCheck"#)
        // then each step is logged from the Storage module
        #expect(Callsites.allIn(open, Self.sources + "FlotsamStorage/"))
        #expect(Callsites.allIn(migrate, Self.sources + "FlotsamStorage/"))
        #expect(Callsites.allIn(integrity, Self.sources + "FlotsamStorage/"))
    }

    @Test("OC-0039 the retention sweep logs rows and bytes removed")
    func retentionSweepCallsite() {
        // given the shipped sources, when the retentionSwept calls are collected
        let files = Callsites.files(matching: #"\.retentionSwept\("#)
        // then the Storage module makes one
        #expect(Callsites.allIn(files, Self.sources + "FlotsamStorage/"))
    }

    @Test("OC-0039 a permission state transition is logged")
    func permissionTransitionCallsite() {
        // given the shipped sources, when the permissionChanged calls are collected
        let files = Callsites.files(matching: #"\.permissionChanged\("#)
        // then a module makes one
        #expect(!files.isEmpty)
    }

    // MARK: OC-0039, shape of the events (these exist today)

    /// OC-0039 (rows removed and bytes figure; permission transition). Red if either event gains a content field or drops
    /// its figure: the rendered public text is a fixed literal and the private text stays empty.
    @Test("OC-0039 the retention-swept and permission-changed events carry counts and an outcome word, no content")
    func retentionAndPermissionEventShape() {
        // given the two events built from literal inputs
        let swept = FlotsamLog.render(LogEvent.retentionSwept(rows: 5, bytes: 4096).fields)
        let granted = FlotsamLog.render(LogEvent.permissionChanged(.accessibility, granted: false).fields)
        // when rendered, then only the figures and the outcome appear, all public
        #expect(swept.publicPart == "byteSize=4096B rows=5")
        #expect(swept.privatePart == "")
        #expect(granted.publicPart == "outcome=denied permission=accessibility")
        #expect(granted.privatePart == "")
    }
}
