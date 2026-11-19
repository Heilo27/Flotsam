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
        let guardAt = try #require(closure.range(of: "guard let id = ids.first else { return }"))
        let hideAt = try #require(closure.range(of: hide))
        let openAt = try #require(closure.range(of: "editor?.open(itemId: id)"))
        #expect(guardAt.upperBound <= hideAt.lowerBound)
        #expect(hideAt.upperBound <= openAt.lowerBound)
    }

    @Test("the hide is the Library panel's own idempotent hidePanel, and nothing else")
    func helperHidesTheLibrary() throws {
        let code = try appContainerCode()
        #expect(code.contains("func hideLibraryBeforeWindowOpens() { library?.hidePanel() }"))
    }

    @Test("the setup guide (menu-bar row and Settings button share one closure) hides the Library, then shows it")
    func setupGuideClosureHidesFirst() throws {
        let delegate = try frd008Code("App/Flotsam/AppDelegate.swift")
            .components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }.joined(separator: " ")
        let closure = try #require(slice(delegate, from: "let showSetupGuide:", through: "onboarding.show() }"))
        let hideAt = try #require(closure.range(of: "container?.hideLibraryBeforeWindowOpens()"))
        let showAt = try #require(closure.range(of: "onboarding.show()"))
        #expect(hideAt.upperBound <= showAt.lowerBound)
        // Both consumers get that one closure, not a fresh `{ onboarding.show() }`.
        #expect(delegate.contains("container.installSettings(showSetupGuide: showSetupGuide)"))
        #expect(delegate.contains("StatusItemController(container: container, showSetupGuide: showSetupGuide)"))
        #expect(!delegate.contains("{ onboarding.show() }"))
    }

    @Test("the menu-bar row runs actions.openSettings, so it cannot skip the hide")
    func menuRowTakesTheClosure() throws {
        let status = try frd008Code("App/Flotsam/StatusItemController.swift")
        #expect(status.contains("run: container.actions.openSettings"))
    }

    // A new opener that called the window controllers directly would skip the hide. Counted per file, so a second call
    // site inside AppContainer.swift is caught as well as one in another file.
    @Test("exactly one call site opens Settings and exactly one opens the item editor")
    func noOtherOpener() throws {
        let root = try frd008SourceRoot().appendingPathComponent("App/Flotsam")
        func occurrences(of needle: String, in code: String) -> Int { code.components(separatedBy: needle).count - 1 }
        var settingsOpeners: [String: Int] = [:], editorOpeners: [String: Int] = [:]
        let files = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)
        while let url = files?.nextObject() as? URL {
            guard url.pathExtension == "swift" else { continue }
            let relative = "App/Flotsam/" + url.path.replacingOccurrences(of: root.path + "/", with: "")
            let code = try frd008Code(relative)
            let name = url.lastPathComponent
            // `SettingsWindowController.openSettings()` itself is the definition, not a caller.
            if name != "SettingsWindowController.swift" {
                let count = occurrences(of: "window?.openSettings()", in: code) + occurrences(of: "settingsWindow?.openSettings()", in: code)
                if count > 0 { settingsOpeners[name] = count }
            }
            let edits = occurrences(of: ".open(itemId:", in: code)
            if edits > 0 { editorOpeners[name] = edits }
        }
        #expect(settingsOpeners == ["AppContainer.swift": 1])
        #expect(editorOpeners == ["AppContainer.swift": 1])
        // The setup guide: every `onboarding.show(` outside the controller itself is in AppDelegate (the one closure
        // above, plus the launch-time resume, which cannot have the Library open).
        var onboardingOpeners: [String] = []
        let all = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)
        while let url = all?.nextObject() as? URL {
            guard url.pathExtension == "swift" else { continue }
            let relative = "App/Flotsam/" + url.path.replacingOccurrences(of: root.path + "/", with: "")
            if try frd008Code(relative).contains("onboarding.show(") { onboardingOpeners.append(url.lastPathComponent) }
        }
        #expect(onboardingOpeners == ["AppDelegate.swift"])
    }
}
