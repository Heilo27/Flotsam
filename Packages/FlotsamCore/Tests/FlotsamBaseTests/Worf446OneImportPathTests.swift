import Foundation
import Testing

@testable import FlotsamBase

// TASK-446 blind QA, FRD-002 FR-002-12 + FRD-008 FR-008-04 (OC-2062, OC-8022). The Settings button and the onboarding
// checkbox must be one import path, the button must never be disabled, and the only "import" string in Settings is the
// screenshot backfill. These are wiring facts the App target holds, so they are read from source the way the other
// Frd008 scans do (frd008Code).

private func codeFiles(under directory: String) throws -> [(path: String, code: String)] {
    let root = try frd008SourceRoot().appendingPathComponent(directory)
    let walker = try #require(FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil))
    var files: [(String, String)] = []
    for case let url as URL in walker where url.pathExtension == "swift" {
        let relative = url.path.replacingOccurrences(of: try frd008SourceRoot().path + "/", with: "")
        files.append((relative, try frd008Code(relative)))
    }
    return files
}

private func lines(matching needle: String, in files: [(path: String, code: String)]) -> [String] {
    files.flatMap { file in
        file.code.split(separator: "\n", omittingEmptySubsequences: false).enumerated()
            .filter { $0.element.contains(needle) }.map { "\(file.path):\($0.offset + 1)" }
    }
}

@Suite("TASK-446 Worf: one import path")
struct Worf446OneImportPathTests {
    private func production() throws -> [(path: String, code: String)] {
        try codeFiles(under: "App") + codeFiles(under: "Packages/FlotsamCore/Sources")
    }

    // Red if anything but importRecentAnnouncing calls importRecent() (a second import path with no HUD).
    @Test("OC-2062: importRecent() has one caller, the announcing action")
    func oneCaller() throws {
        let calls = lines(matching: "importRecent()", in: try production())
        let declared = calls.filter { $0.hasPrefix("Packages/FlotsamCore/Sources/FlotsamScreenshots/ScreenshotWatcher.swift") }
        #expect(calls.count == 2, "declaration plus one call, got \(calls)")
        #expect(declared.count == 2, "both are in ScreenshotWatcher.swift, got \(calls)")
    }

    // Red if a second place invokes the announcing action or builds its own HUD wiring.
    @Test("OC-2062: the app calls importRecentAnnouncing once and assigns the action once")
    func oneWiring() throws {
        let files = try production()
        let app = files.filter { $0.path.hasPrefix("App/") }
        #expect(lines(matching: "importRecentAnnouncing", in: app).count == 1)
        #expect(lines(matching: "actions.importRecentScreenshots =", in: app).count == 1)
        #expect(lines(matching: "ScreenshotSelection.backfill(", in: files).count == 1, "one backfill selection")
    }

    // Red if either entry point is rewired to anything but the shared action.
    @Test("FR-008-04: Settings button and onboarding both reach the one action, read at click time")
    func bothEntryPoints() throws {
        let pane = try frd008Code("App/Flotsam/Settings/GeneralPane.swift")
        #expect(pane.contains("Button { model.env.importRecentScreenshots() } label: { Text(.importRecentScreenshots) }"))
        let container = try frd008Code("App/Flotsam/AppContainer.swift")
        #expect(container.contains("importRecentScreenshots: { [weak self] in self?.actions.importRecentScreenshots?() }"))
        let onboarding = try frd008Code("App/Flotsam/OnboardingModel.swift")
        #expect(onboarding.contains("container.actions.importRecentScreenshots?()"))
    }

    // Red if a .disabled(...) is chained onto the import button, or it moves out of its FR-008-04 slot.
    @Test("OC-2062: the Settings button is never disabled and sits between the folder row and the Shelf")
    func neverDisabledAndInOrder() throws {
        let rows = try frd008Code("App/Flotsam/Settings/GeneralPane.swift").split(separator: "\n").map { String($0) }
        let at = try #require(rows.firstIndex { $0.contains("Text(.importRecentScreenshots)") })
        #expect(!rows[at].contains(".disabled"))
        #expect(!rows[at + 1].trimmingCharacters(in: .whitespaces).hasPrefix("."), "no modifier chained onto the button")
        let useDefault = try #require(rows.firstIndex { $0.contains("Text(.useSystemDefault)") })
        let shelf = try #require(rows.firstIndex { $0.contains("Text(.shelf)") })
        #expect(useDefault < at && at < shelf)
        #expect(rows.filter { $0.contains("importRecentScreenshots") }.count == 1, "one button")
    }

    // OC-8022 ruling: the exemption is exactly one string. Red if another Settings string starts mentioning
    // import, or if any export/sync/iCloud wording appears (no exemption for those).
    @Test("OC-8022: the only Settings string that says import is the screenshot backfill button")
    func exemptionIsNarrow() {
        let importing = SettingsString.allCases.filter { $0.text.lowercased().contains("import") }
        #expect(importing == [.importRecentScreenshots])
        #expect(SettingsString.importRecentScreenshots.text == "Import Recent Screenshots")
        for word in ["export", "sync", "icloud"] {
            #expect(!SettingsString.allCases.contains { $0.text.lowercased().contains(word) && $0 != .clearDone },
                    "a Settings string mentions \(word)")
        }
    }

    // Red if a second source of the HUD wording appears outside the catalogue.
    @Test("Rule 9: the HUD wording lives in the catalogue only; counts 1 and 10000 format")
    func oneHome() throws {
        #expect(lines(matching: "\"Imported", in: try production()).isEmpty)
        #expect(ScreenshotImportHUD.message(count: 1) == "Imported 1")
        #expect(ScreenshotImportHUD.message(count: 10_000) == "Imported 10000")
    }
}
