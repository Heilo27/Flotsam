import Foundation
import Testing

// TASK-524, FR-003-02 / AC-003-01a: opening any Flotsam window hides the Library, whatever opened it. The Library's own
// ⌘, and ⌘K are pinned at package level (Task524WindowOpenHidesLibraryTests). The menu-bar "Settings…" row never passes
// through the Library's `perform`, so the guarantee for it lives in the App's closures. The App has no test target, so
// this is a source-shape scan (Worf107AccessibilityFooterTests does the same): the closures hide the Library, as the
// step before the window is fronted, and no other call site opens either window.

private func appContainerCode() throws -> String {
    try frd008Code("App/Flotsam/AppContainer.swift")
        .components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }.joined(separator: " ")
}

/// The text from `start` up to and including the first `end` after it.
private func slice(_ text: String, from start: String, through end: String) -> String? {
    guard let open = text.range(of: start), let close = text.range(of: end, range: open.upperBound..<text.endIndex) else { return nil }
    return String(text[open.lowerBound..<close.upperBound])
}

@Suite("TASK-524: the App hides the Library before any Flotsam window opens") struct Task524AppWiringTests {
    private let hide = "self?.hideLibraryBeforeWindowOpens()"

    @Test("actions.openSettings hides the Library, then opens Settings (menu-bar row and Library effect both run it)")
    func settingsClosureHidesFirst() throws {
        let code = try appContainerCode()
        let closure = try #require(slice(code, from: "actions.openSettings = {", through: "window?.openSettings()"))
        let hideAt = try #require(closure.range(of: hide))
        let openAt = try #require(closure.range(of: "window?.openSettings()"))
        #expect(hideAt.upperBound <= openAt.lowerBound)
    }

    @Test("actions.editShortcutAndTrigger hides only after the one-item guard, and before the editor opens")
    func editorClosureHidesAfterGuardBeforeOpen() throws {
        let code = try appContainerCode()
        let closure = try #require(slice(code, from: "actions.editShortcutAndTrigger = {", through: "editor?.open(itemId: id)"))
        let guardAt = try #require(closure.range(of: "shortcutEditorTarget(selection: ids) else { return }"))
        let hideAt = try #require(closure.range(of: hide))
        let openAt = try #require(closure.range(of: "editor?.open(itemId: id)"))
        #expect(guardAt.upperBound <= hideAt.lowerBound)
        #expect(hideAt.upperBound <= openAt.lowerBound)
    }

    @Test("the hide is the Library panel's own idempotent hidePanel, and nothing else")
    func helperHidesTheLibrary() throws {
        let code = try appContainerCode()
        #expect(code.contains("private func hideLibraryBeforeWindowOpens() { library?.hidePanel() }"))
    }

    @Test("the menu-bar row runs actions.openSettings, so it cannot skip the hide")
    func menuRowTakesTheClosure() throws {
        let status = try frd008Code("App/Flotsam/StatusItemController.swift")
        #expect(status.contains("run: container.actions.openSettings"))
    }

    // A new opener that called the window controllers directly would skip the hide.
    @Test("only the two closures open Settings or the item editor")
    func noOtherOpener() throws {
        let root = try frd008SourceRoot().appendingPathComponent("App/Flotsam")
        var settingsOpeners: [String] = [], editorOpeners: [String] = []
        let files = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)
        while let url = files?.nextObject() as? URL {
            guard url.pathExtension == "swift" else { continue }
            let relative = "App/Flotsam/" + url.path.replacingOccurrences(of: root.path + "/", with: "")
            let code = try frd008Code(relative)
            let name = url.lastPathComponent
            // `SettingsWindowController.openSettings()` itself is the definition, not a caller.
            if name != "SettingsWindowController.swift", code.contains("window?.openSettings()") || code.contains("settingsWindow?.openSettings()") {
                settingsOpeners.append(name)
            }
            if code.contains(".open(itemId:") { editorOpeners.append(name) }
        }
        #expect(settingsOpeners == ["AppContainer.swift"])
        #expect(editorOpeners == ["AppContainer.swift"])
    }
}
